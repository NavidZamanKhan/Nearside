package com.nearside.app.crypto

import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.UUID
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.math.max

data class PakeSessionConfig(
    val shortCode: String,
    val serverIdentity: String,
    val clientIdentity: String,
    val sessionId: String = UUID.randomUUID().toString(),
    val createdAtSeconds: Double = System.currentTimeMillis() / 1000.0,
    val maxAttempts: Int = 5,
    val expirySeconds: Double = 120.0
) {
    val isExpired: Boolean
        get() = ((System.currentTimeMillis() / 1000.0) - createdAtSeconds) > expirySeconds
}

sealed class PakeResult {
    object Success : PakeResult()
    object SessionExpired : PakeResult()
    object MaxAttemptsExceeded : PakeResult()
    data class TagMismatch(val attemptsRemaining: Int) : PakeResult()
}

class ShortCodePakeParticipant(
    val role: Role,
    val config: PakeSessionConfig
) {
    enum class Role {
        SERVER,
        CLIENT
    }

    val ephemeralKeyPair: KeyPair = run {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("secp256r1"))
        kpg.generateKeyPair()
    }

    val localNonce: ByteArray = ByteArray(32).also {
        SecureRandom().nextBytes(it)
    }

    var failedAttempts: Int = 0
        private set

    var isLockedOut: Boolean = false
        private set

    companion object {
        fun encodeRawPoint(publicKey: PublicKey): ByteArray {
            if (publicKey is ECPublicKey) {
                val x = publicKey.w.affineX.toByteArray()
                val y = publicKey.w.affineY.toByteArray()
                val raw = ByteArray(64)
                val xTrim = ByteArray(32)
                val yTrim = ByteArray(32)
                System.arraycopy(x, max(0, x.size - 32), xTrim, max(0, 32 - x.size), minOf(32, x.size))
                System.arraycopy(y, max(0, y.size - 32), yTrim, max(0, 32 - y.size), minOf(32, y.size))
                System.arraycopy(xTrim, 0, raw, 0, 32)
                System.arraycopy(yTrim, 0, raw, 32, 32)
                return raw
            }
            return publicKey.encoded
        }

        fun decodeRawPoint(raw: ByteArray): PublicKey {
            val xTrim = ByteArray(32)
            val yTrim = ByteArray(32)
            System.arraycopy(raw, 0, xTrim, 0, 32)
            System.arraycopy(raw, 32, yTrim, 0, 32)
            val x = BigInteger(1, xTrim)
            val y = BigInteger(1, yTrim)
            val point = ECPoint(x, y)

            val kpg = KeyPairGenerator.getInstance("EC")
            kpg.initialize(ECGenParameterSpec("secp256r1"))
            val temp = kpg.generateKeyPair().public as ECPublicKey
            val spec = ECPublicKeySpec(point, temp.params)
            return KeyFactory.getInstance("EC").generatePublic(spec)
        }
    }

    fun buildTranscript(remoteEphemeralKey: PublicKey, remoteNonce: ByteArray): ByteArray {
        val out = mutableListOf<Byte>()
        out.addAll("nearside-pake-v1".toByteArray(Charsets.UTF_8).toList())
        out.addAll(config.sessionId.toByteArray(Charsets.UTF_8).toList())
        out.addAll(config.serverIdentity.toByteArray(Charsets.UTF_8).toList())
        out.addAll(config.clientIdentity.toByteArray(Charsets.UTF_8).toList())

        val (serverKey, clientKey) = if (role == Role.SERVER) {
            Pair(encodeRawPoint(ephemeralKeyPair.public), encodeRawPoint(remoteEphemeralKey))
        } else {
            Pair(encodeRawPoint(remoteEphemeralKey), encodeRawPoint(ephemeralKeyPair.public))
        }
        out.addAll(serverKey.toList())
        out.addAll(clientKey.toList())

        val (serverNonce, clientNonce) = if (role == Role.SERVER) {
            Pair(localNonce, remoteNonce)
        } else {
            Pair(remoteNonce, localNonce)
        }
        out.addAll(serverNonce.toList())
        out.addAll(clientNonce.toList())

        return out.toByteArray()
    }

    fun computeConfirmationKeys(
        peerEphemeralKey: PublicKey,
        peerNonce: ByteArray,
        enteredCode: String
    ): Pair<ByteArray, ByteArray> {
        if (config.isExpired) {
            throw IllegalStateException("Session expired")
        }
        if (isLockedOut) {
            throw IllegalStateException("Max attempts exceeded")
        }

        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(ephemeralKeyPair.private)
        ka.doPhase(peerEphemeralKey, true)
        val sharedSecret = ka.generateSecret()

        val transcript = buildTranscript(peerEphemeralKey, peerNonce)

        val md = MessageDigest.getInstance("SHA-256")
        val codeSalt = md.digest("$enteredCode:${config.sessionId}".toByteArray(Charsets.UTF_8))

        val clientInfo = "nearside-pake-client-confirm".toByteArray(Charsets.UTF_8) + transcript
        val clientKey = Hkdf.deriveKey(sharedSecret, codeSalt, clientInfo, 32)

        val serverInfo = "nearside-pake-server-confirm".toByteArray(Charsets.UTF_8) + transcript
        val serverKey = Hkdf.deriveKey(sharedSecret, codeSalt, serverInfo, 32)

        return Pair(clientKey, serverKey)
    }

    fun generateConfirmationTag(keys: Pair<ByteArray, ByteArray>, transcript: ByteArray): ByteArray {
        val key = if (role == Role.CLIENT) keys.first else keys.second
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(transcript)
    }

    fun verifyConfirmationTag(
        peerTag: ByteArray,
        expectedKey: ByteArray,
        transcript: ByteArray
    ): PakeResult {
        if (isLockedOut) {
            return PakeResult.MaxAttemptsExceeded
        }
        if (config.isExpired) {
            return PakeResult.SessionExpired
        }

        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(expectedKey, "HmacSHA256"))
        val expectedTag = mac.doFinal(transcript)

        var diff = 0
        if (peerTag.size == expectedTag.size) {
            for (i in peerTag.indices) {
                diff = diff or (peerTag[i].toInt() xor expectedTag[i].toInt())
            }
        } else {
            diff = 1
        }

        return if (diff == 0) {
            PakeResult.Success
        } else {
            failedAttempts++
            if (failedAttempts >= config.maxAttempts) {
                isLockedOut = true
            }
            PakeResult.TagMismatch(max(0, config.maxAttempts - failedAttempts))
        }
    }
}
