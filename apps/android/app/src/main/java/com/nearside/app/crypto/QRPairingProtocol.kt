package com.nearside.app.crypto

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

data class QRPairingPayload(
    val version: Int = 1,
    val sessionId: String,
    val hostIdentity: String,
    val hostName: String,
    val sharedSecretBase64: String,
    val createdAtSeconds: Double = System.currentTimeMillis() / 1000.0,
    val expirySeconds: Double = 180.0
) {
    val isExpired: Boolean
        get() = ((System.currentTimeMillis() / 1000.0) - createdAtSeconds) > expirySeconds

    fun toUri(): String {
        val encodedName = URLEncoder.encode(hostName, "UTF-8")
        val encodedSec = URLEncoder.encode(sharedSecretBase64, "UTF-8")
        return "nearside://pair?v=$version&sid=$sessionId&id=$hostIdentity&name=$encodedName&sec=$encodedSec"
    }

    companion object {
        fun createNew(hostIdentity: String, hostName: String): QRPairingPayload {
            val random = SecureRandom()
            val secretBytes = ByteArray(32)
            random.nextBytes(secretBytes)
            val secretBase64 = Base64.getEncoder().encodeToString(secretBytes)

            return QRPairingPayload(
                sessionId = UUID.randomUUID().toString(),
                hostIdentity = hostIdentity,
                hostName = hostName,
                sharedSecretBase64 = secretBase64
            )
        }

        fun fromUri(uriString: String): QRPairingPayload? {
            return try {
                val uri = URI(uriString)
                if (uri.scheme != "nearside" || uri.host != "pair") return null

                val query = uri.rawQuery ?: return null
                val params = query.split("&").mapNotNull { part ->
                    val pair = part.split("=", limit = 2)
                    if (pair.size == 2) {
                        URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair[1], "UTF-8")
                    } else null
                }.toMap()

                val sid = params["sid"] ?: return null
                val id = params["id"] ?: return null
                val sec = params["sec"] ?: return null
                val name = params["name"] ?: "Nearby Peer"
                val version = params["v"]?.toIntOrNull() ?: 1

                QRPairingPayload(
                    version = version,
                    sessionId = sid,
                    hostIdentity = id,
                    hostName = name,
                    sharedSecretBase64 = sec
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

class QRPairingSession(
    val role: Role,
    val localIdentity: DeviceIdentity,
    val payload: QRPairingPayload
) {
    enum class Role {
        HOST,
        CLIENT
    }

    val localNonce: ByteArray = ByteArray(32).also {
        SecureRandom().nextBytes(it)
    }

    fun buildTranscript(
        remoteNonce: ByteArray,
        clientIdentity: String,
        serverIdentity: String
    ): ByteArray {
        val out = mutableListOf<Byte>()
        out.addAll("nearside-qr-v1".toByteArray(Charsets.UTF_8).toList())
        out.addAll(payload.sessionId.toByteArray(Charsets.UTF_8).toList())
        out.addAll(clientIdentity.toByteArray(Charsets.UTF_8).toList())
        out.addAll(serverIdentity.toByteArray(Charsets.UTF_8).toList())

        if (role == Role.CLIENT) {
            out.addAll(localNonce.toList())
            out.addAll(remoteNonce.toList())
        } else {
            out.addAll(remoteNonce.toList())
            out.addAll(localNonce.toList())
        }

        return out.toByteArray()
    }

    fun deriveConfirmationKeys(transcript: ByteArray): Pair<ByteArray, ByteArray> {
        if (payload.isExpired) {
            throw IllegalStateException("Pairing session expired")
        }

        val secretBytes = Base64.getDecoder().decode(payload.sharedSecretBase64)
        if (secretBytes.size != 32) {
            throw IllegalArgumentException("Invalid shared secret length")
        }

        val md = MessageDigest.getInstance("SHA-256")
        val salt = md.digest(transcript)

        val clientKey = Hkdf.deriveKey(
            ikm = secretBytes,
            salt = salt,
            info = "nearside-qr-client-confirm".toByteArray(Charsets.UTF_8),
            length = 32
        )

        val serverKey = Hkdf.deriveKey(
            ikm = secretBytes,
            salt = salt,
            info = "nearside-qr-server-confirm".toByteArray(Charsets.UTF_8),
            length = 32
        )

        return Pair(clientKey, serverKey)
    }

    fun generateConfirmation(keys: Pair<ByteArray, ByteArray>, transcript: ByteArray): ByteArray {
        val key = if (role == Role.CLIENT) keys.first else keys.second
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(transcript)
    }

    fun verifyPeerConfirmation(
        peerMac: ByteArray,
        expectedKey: ByteArray,
        transcript: ByteArray
    ): Boolean {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(expectedKey, "HmacSHA256"))
        val expectedMac = mac.doFinal(transcript)

        if (peerMac.size != expectedMac.size) return false
        var diff = 0
        for (i in peerMac.indices) {
            diff = diff or (peerMac[i].toInt() xor expectedMac[i].toInt())
        }
        return diff == 0
    }
}
