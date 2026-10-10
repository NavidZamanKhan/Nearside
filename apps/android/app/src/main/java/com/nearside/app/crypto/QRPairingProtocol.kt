package com.nearside.app.crypto

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import com.nearside.app.diagnostics.NearsideError
import com.nearside.app.diagnostics.NearsideErrorCode
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

data class QRPairingPayload(
    val version: Int = 1,
    val sessionId: String,
    val hostIdentity: String,
    val hostName: String,
    val sharedSecretBase64: String,
    val ip: String? = null,
    val port: Int? = 41433,
    val createdAtSeconds: Double = System.currentTimeMillis() / 1000.0,
    val expirySeconds: Double = 180.0
) {
    val isExpired: Boolean
        get() = !isValidAt(System.currentTimeMillis() / 1000.0)

    fun isValidAt(nowSeconds: Double): Boolean = version == 1 &&
        createdAtSeconds.isFinite() && expirySeconds.isFinite() && expirySeconds > 0 &&
        expirySeconds <= 180 && createdAtSeconds <= nowSeconds + 30 &&
        nowSeconds < createdAtSeconds + expirySeconds

    fun toUri(): String {
        fun encode(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
        val params = linkedMapOf(
            "v" to version.toString(), "sid" to sessionId, "id" to hostIdentity,
            "name" to hostName, "sec" to sharedSecretBase64,
            "created" to createdAtSeconds.toString(), "ttl" to expirySeconds.toString()
        )
        if (!ip.isNullOrEmpty()) {
            params["ip"] = ip
            params["port"] = (port ?: 41433).toString()
        }
        return "nearside://pair?" + params.entries.joinToString("&") { "${it.key}=${encode(it.value)}" }
    }

    companion object {
        fun createNew(hostIdentity: String, hostName: String, ip: String? = null, port: Int? = 41433): QRPairingPayload {
            val secretBytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
            return QRPairingPayload(sessionId = UUID.randomUUID().toString(), hostIdentity = hostIdentity,
                hostName = hostName, sharedSecretBase64 = Base64.getEncoder().encodeToString(secretBytes),
                ip = ip, port = port)
        }

        fun fromUri(uriString: String): QRPairingPayload? = try {
            if (uriString.length > 4096) throw IllegalArgumentException()
            val uri = URI(uriString)
            require(uri.scheme == "nearside" && uri.host == "pair" && uri.userInfo == null &&
                uri.port == -1 && uri.path.isNullOrEmpty() && uri.fragment == null)
            val params = linkedMapOf<String, String>()
            for (part in (uri.rawQuery ?: throw IllegalArgumentException()).split("&")) {
                val pair = part.split("=", limit = 2)
                require(pair.size == 2)
                fun decode(value: String) = URLDecoder.decode(value.replace("+", "%2B"), "UTF-8")
                val key = decode(pair[0])
                require(!params.containsKey(key))
                params[key] = decode(pair[1])
            }
            val sid = params.getValue("sid")
            require(UUID.fromString(sid).toString().equals(sid, ignoreCase = true))
            val id = params.getValue("id")
            require(id.matches(Regex("ns1_[0-9a-f]{64}")))
            val secret = params.getValue("sec")
            require(Base64.getDecoder().decode(secret).size == 32)
            val name = params["name"] ?: "Nearby Peer"
            require(name.isNotBlank() && name.length <= 255 && name.none { it.isISOControl() })
            val port = params["port"]?.toInt() ?: 41433
            require(port in 1..65535)
            val ip = params["ip"]
            require(ip == null || (ip.length <= 253 && ip.isNotBlank() && ip.none { it.isWhitespace() || it.isISOControl() }))
            val payload = QRPairingPayload(version = params.getValue("v").toInt(), sessionId = sid,
                hostIdentity = id, hostName = name, sharedSecretBase64 = secret, ip = ip, port = port,
                createdAtSeconds = params.getValue("created").toDouble(), expirySeconds = params.getValue("ttl").toDouble())
            require(payload.version == 1 && payload.createdAtSeconds.isFinite() && payload.expirySeconds.isFinite() &&
                payload.expirySeconds > 0 && payload.expirySeconds <= 180)
            payload
        } catch (_: Exception) { null }
    }
}

/** Active display sessions exist only in memory, expire, and are consumed exactly once. */
object QRPairingSessions {
    private val sessions = mutableMapOf<String, QRPairingPayload>()
    @Synchronized fun register(payload: QRPairingPayload) {
        sessions.entries.removeAll { it.value.isExpired }
        sessions[payload.sessionId] = payload
    }
    @Synchronized fun unregister(sessionId: String) { sessions.remove(sessionId) }
    @Synchronized fun requireActive(sessionId: String): QRPairingPayload {
        val payload = sessions[sessionId] ?: throw NearsideError(NearsideErrorCode.PAIRING_SESSION_EXPIRED,
            "verifyQR", "Pairing session expired or already used", correlationId = sessionId)
        if (payload.isExpired) {
            sessions.remove(sessionId)
            throw NearsideError(NearsideErrorCode.PAIRING_SESSION_EXPIRED, "verifyQR", "Pairing session expired", correlationId = sessionId)
        }
        return payload
    }
    @Synchronized fun consume(sessionId: String): Boolean {
        val payload = sessions.remove(sessionId) ?: return false
        return !payload.isExpired
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
