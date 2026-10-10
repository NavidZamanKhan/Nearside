package com.nearside.app.transfer

import com.nearside.app.crypto.DeviceIdentity
import com.nearside.app.crypto.Hkdf
import com.nearside.app.crypto.PinnedTrustStore
import com.nearside.app.crypto.TrustResult
import com.nearside.app.diagnostics.NearsideError
import com.nearside.app.diagnostics.NearsideErrorCode
import org.json.JSONObject
import java.io.*
import java.nio.ByteBuffer
import java.security.*
import java.security.interfaces.ECPublicKey
import java.security.spec.*
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Version 2 transfers never send manifests or file bytes before mutual key authentication. */
internal data class SecureTransferHello(
    val role: String, val identity: String, val target: String, val spki: String,
    val ephemeral: String, val nonce: String, val binding: String, val signature: String,
    val version: Int = 2
) {
    fun canonical(): ByteArray {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).use { output ->
            listOf("nearside-transfer-v2", "$version", role, identity, target, spki, ephemeral, nonce, binding).forEach {
                val value = it.toByteArray(Charsets.UTF_8)
                output.writeInt(value.size); output.write(value)
            }
        }
        return bytes.toByteArray()
    }

    fun encode(): ByteArray = JSONObject().apply {
        put("version", version); put("role", role); put("identity", identity); put("target", target)
        put("spki", spki); put("ephemeral", ephemeral); put("nonce", nonce); put("binding", binding); put("signature", signature)
    }.toString().toByteArray(Charsets.UTF_8)

    companion object {
        fun decode(data: ByteArray): SecureTransferHello {
            if (data.size !in 1..16384) throw secureFailure("Invalid secure handshake size")
            val json = JSONObject(String(data, Charsets.UTF_8))
            return SecureTransferHello(json.getString("role"), json.getString("identity"), json.getString("target"),
                json.getString("spki"), json.getString("ephemeral"), json.getString("nonce"), json.getString("binding"),
                json.getString("signature"), json.getInt("version"))
        }
    }
}

internal fun secureFailure(message: String, cause: Throwable? = null): NearsideError = NearsideError(
    NearsideErrorCode.TRUST_KEY_MISMATCH, "authenticateTransfer", message, underlyingError = cause)

internal class SecureTransferHandshake(private val identity: DeviceIdentity, private val target: String) {
    private val ephemeral = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private val nonce = ByteArray(32).also { SecureRandom().nextBytes(it) }

    fun hello(role: String, binding: ByteArray = ByteArray(0)): SecureTransferHello {
        val encode = Base64.getEncoder()
        val point = ephemeral.public as ECPublicKey
        fun coordinate(value: java.math.BigInteger): ByteArray = value.toByteArray().takeLast(32).toByteArray().let {
            ByteArray(32 - it.size) + it
        }
        val rawPoint = byteArrayOf(4) + coordinate(point.w.affineX) + coordinate(point.w.affineY)
        val unsigned = SecureTransferHello(role, identity.publicIdentity, target, encode.encodeToString(identity.spkiDer),
            encode.encodeToString(rawPoint), encode.encodeToString(nonce), encode.encodeToString(binding), "")
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(identity.privateKey); signer.update(unsigned.canonical())
        return unsigned.copy(signature = encode.encodeToString(signer.sign()))
    }

    fun validate(peer: SecureTransferHello, role: String, binding: ByteArray, trustStore: PinnedTrustStore) {
        try {
            val decode = Base64.getDecoder()
            if (peer.version != 2 || peer.role != role || peer.identity != target || peer.target != identity.publicIdentity ||
                !decode.decode(peer.binding).contentEquals(binding)) throw secureFailure("Secure handshake identity or transcript mismatch")
            val spki = decode.decode(peer.spki)
            val nonce = decode.decode(peer.nonce)
            val point = decode.decode(peer.ephemeral)
            val signature = decode.decode(peer.signature)
            if (spki.size !in 64..1024 || nonce.size != 32 || point.size != 65 || point[0] != 4.toByte() || signature.size !in 8..80 ||
                DeviceIdentity.computeIdentity(spki) != peer.identity) throw secureFailure("Malformed secure handshake key")
            when (val trust = trustStore.validatePeer(spki)) {
                is TrustResult.Success -> if (trust.identity != target) throw secureFailure("Unexpected recipient identity")
                is TrustResult.PeerBlocked -> throw NearsideError(NearsideErrorCode.TRUST_PEER_BLOCKED, "authenticateTransfer", "Peer is blocked")
                is TrustResult.UntrustedPeer -> throw NearsideError(NearsideErrorCode.TRUST_UNTRUSTED_PEER, "authenticateTransfer", "Peer is not paired")
                else -> throw secureFailure("Peer key does not match enrollment")
            }
            val verifier = Signature.getInstance("SHA256withECDSA")
            verifier.initVerify(DeviceIdentity.decodePublicKey(spki)); verifier.update(peer.canonical())
            if (!verifier.verify(signature)) throw secureFailure("Secure handshake signature failed")
        } catch (error: NearsideError) { throw error }
        catch (error: Exception) { throw secureFailure("Invalid secure handshake", error) }
    }

    fun records(client: SecureTransferHello, server: SecureTransferHello, isClient: Boolean): SecureTransferRecords {
        val peer = if (isClient) server else client
        val raw = Base64.getDecoder().decode(peer.ephemeral)
        val parameters = (ephemeral.public as ECPublicKey).params
        val point = ECPoint(java.math.BigInteger(1, raw.copyOfRange(1, 33)), java.math.BigInteger(1, raw.copyOfRange(33, 65)))
        val key = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, parameters))
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(ephemeral.private); agreement.doPhase(key, true)
        val transcript = MessageDigest.getInstance("SHA-256").digest(client.canonical() + server.canonical())
        val keys = Hkdf.deriveKey(agreement.generateSecret(), transcript, "nearside-transfer-v2-keys".toByteArray(), 64)
        return SecureTransferRecords(keys.copyOfRange(0, 32), keys.copyOfRange(32, 64), transcript, isClient)
    }
}

internal class SecureTransferRecords(clientKey: ByteArray, serverKey: ByteArray, private val transcript: ByteArray, private val isClient: Boolean) {
    private val sendKey = if (isClient) clientKey else serverKey
    private val receiveKey = if (isClient) serverKey else clientKey
    private var sendSequence = 0L
    private var receiveSequence = 0L
    companion object { const val MAX_RECORD = 1024 * 1024 }

    private fun crypt(mode: Int, value: ByteArray, key: ByteArray, sequence: Long, direction: Byte): ByteArray {
        if (sequence < 0 || sequence == Long.MAX_VALUE) throw secureFailure("Secure record sequence exhausted")
        val sequenceBytes = ByteBuffer.allocate(8).putLong(sequence).array()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(128, ByteArray(4) + sequenceBytes))
        cipher.updateAAD(transcript + byteArrayOf(direction) + sequenceBytes)
        return cipher.doFinal(value)
    }

    fun seal(data: ByteArray): ByteArray {
        if (data.size !in 1..MAX_RECORD) throw secureFailure("Invalid encrypted record size")
        return crypt(Cipher.ENCRYPT_MODE, data, sendKey, sendSequence++, if (isClient) 0 else 1)
    }

    fun open(data: ByteArray): ByteArray {
        if (data.size !in 17..MAX_RECORD + 16) throw secureFailure("Invalid encrypted record size")
        try { return crypt(Cipher.DECRYPT_MODE, data, receiveKey, receiveSequence++, if (isClient) 1 else 0) }
        catch (error: Exception) { throw secureFailure("Encrypted record authentication failed", error) }
    }
}

internal class SecureTransferChannel private constructor(val peerIdentity: String, private val rawInput: DataInputStream,
    private val rawOutput: DataOutputStream, private val records: SecureTransferRecords) {
    val input = DataInputStream(object : InputStream() {
        private var current = ByteArray(0)
        private var offset = 0
        override fun read(): Int { val value = ByteArray(1); return if (read(value, 0, 1) < 0) -1 else value[0].toInt() and 255 }
        override fun read(bytes: ByteArray, start: Int, length: Int): Int {
            if (length == 0) return 0
            if (offset == current.size) {
                val size = rawInput.readInt()
                if (size !in 17..SecureTransferRecords.MAX_RECORD + 16) throw secureFailure("Invalid encrypted record size")
                val sealed = ByteArray(size); rawInput.readFully(sealed)
                current = records.open(sealed); offset = 0
            }
            val count = minOf(length, current.size - offset)
            current.copyInto(bytes, start, offset, offset + count); offset += count
            return count
        }
    })
    val output = DataOutputStream(object : OutputStream() {
        override fun write(value: Int) { write(byteArrayOf(value.toByte())) }
        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            var start = offset
            while (start < offset + length) {
                val end = minOf(offset + length, start + SecureTransferRecords.MAX_RECORD)
                val sealed = records.seal(bytes.copyOfRange(start, end))
                rawOutput.writeInt(sealed.size); rawOutput.write(sealed); start = end
            }
        }
        override fun flush() { rawOutput.flush() }
    })

    companion object {
        const val CLIENT_HELLO: Byte = 0x20
        const val SERVER_HELLO: Byte = 0x21
        private fun writeHello(output: DataOutputStream, type: Byte, hello: SecureTransferHello) {
            val bytes = hello.encode()
            output.writeInt(TransferChunk.MAGIC); output.writeByte(type.toInt()); output.writeInt(bytes.size); output.write(bytes); output.flush()
        }
        private fun readHello(input: DataInputStream, type: Byte): SecureTransferHello {
            if (input.readInt() != TransferChunk.MAGIC || input.readByte() != type) throw secureFailure("Secure transfer handshake required")
            val length = input.readInt()
            if (length !in 1..16384) throw secureFailure("Invalid secure handshake size")
            val data = ByteArray(length); input.readFully(data); return SecureTransferHello.decode(data)
        }
        fun client(input: DataInputStream, output: DataOutputStream, identity: DeviceIdentity, target: String, trustStore: PinnedTrustStore): SecureTransferChannel {
            val handshake = SecureTransferHandshake(identity, target)
            val client = handshake.hello("client")
            writeHello(output, CLIENT_HELLO, client)
            val server = readHello(input, SERVER_HELLO)
            val binding = MessageDigest.getInstance("SHA-256").digest(client.canonical())
            handshake.validate(server, "server", binding, trustStore)
            return SecureTransferChannel(target, input, output, handshake.records(client, server, true))
        }
        fun server(input: DataInputStream, output: DataOutputStream, identity: DeviceIdentity, trustStore: PinnedTrustStore): SecureTransferChannel {
            val length = input.readInt()
            if (length !in 1..16384) throw secureFailure("Invalid secure handshake size")
            val bytes = ByteArray(length); input.readFully(bytes)
            val client = SecureTransferHello.decode(bytes)
            val handshake = SecureTransferHandshake(identity, client.identity)
            handshake.validate(client, "client", ByteArray(0), trustStore)
            val server = handshake.hello("server", MessageDigest.getInstance("SHA-256").digest(client.canonical()))
            writeHello(output, SERVER_HELLO, server)
            return SecureTransferChannel(client.identity, input, output, handshake.records(client, server, false))
        }
    }
}
