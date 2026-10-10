package com.nearside.app.transfer

import com.nearside.app.crypto.*
import com.nearside.app.diagnostics.NearsideError
import com.nearside.app.diagnostics.NearsideErrorCode
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.util.Base64

/** All messages are bounded. No peer is enrolled until a mutually authenticated QR exchange completes. */
object QRPairingTransport {
    private const val MAX_FRAME_BYTES = 16384
    private fun malformed(sessionId: String? = null): Nothing = throw NearsideError(
        NearsideErrorCode.PAIRING_MALFORMED_PAYLOAD, "pairQR", "Invalid pairing frame", correlationId = sessionId)

    private inline fun <T> withSession(sessionId: String, exchange: () -> T): T = try {
        exchange()
    } catch (error: NearsideError) {
        if (error.correlationId != null) throw error
        throw NearsideError(error.code, error.operation, error.message, subsystem = error.subsystem,
            underlyingError = error.underlyingError, correlationId = sessionId,
            retryCount = error.retryCount, timestamp = error.timestamp)
    }

    fun write(out: DataOutputStream, type: FrameType, obj: JSONObject) {
        val bytes = obj.toString().toByteArray(Charsets.UTF_8)
        require(bytes.size in 1..MAX_FRAME_BYTES)
        out.writeInt(TransferChunk.MAGIC); out.writeByte(type.code.toInt()); out.writeInt(bytes.size)
        out.write(bytes); out.flush()
    }

    fun read(input: DataInputStream, type: FrameType): JSONObject {
        if (input.readInt() != TransferChunk.MAGIC || input.readByte() != type.code) malformed()
        return readPayload(input)
    }

    fun readPayload(input: DataInputStream): JSONObject {
        val length = input.readInt()
        if (length !in 1..MAX_FRAME_BYTES) malformed()
        val bytes = ByteArray(length); input.readFully(bytes)
        return try { JSONObject(String(bytes, Charsets.UTF_8)) } catch (_: Exception) { malformed() }
    }

    fun client(input: DataInputStream, out: DataOutputStream, identity: DeviceIdentity, name: String,
               payload: QRPairingPayload, trustStore: PinnedTrustStore, host: String, port: Int): PairResponseFrame = withSession(payload.sessionId) {
        val session = QRPairingSession(QRPairingSession.Role.CLIENT, identity, payload)
        val handshake = QRPairingHandshake(session, identity.publicIdentity, payload.hostIdentity)
        val nonce = Base64.getEncoder().encodeToString(session.localNonce)
        val request = PairRequestFrame(identity.publicIdentity, name, "android",
            Base64.getEncoder().encodeToString(identity.spkiDer), "", qrSessionId = payload.sessionId, qrNonceBase64 = nonce)
        write(out, FrameType.PAIR_REQUEST, request.toJson())
        val challenge = PairResponseFrame.fromJson(read(input, FrameType.PAIR_RESPONSE))
        if (challenge.status != "CHALLENGE" || challenge.qrSessionId != payload.sessionId || challenge.serverId != payload.hostIdentity) malformed(payload.sessionId)
        val key = QRPairingHandshake.validatePeer(challenge.serverId, challenge.serverSpkiBase64, trustStore)
        val serverNonce = challenge.qrNonceBase64 ?: malformed(payload.sessionId)
        handshake.verify(serverNonce, challenge.qrConfirmationBase64 ?: malformed(payload.sessionId))
        write(out, FrameType.PAIR_REQUEST, request.copy(qrConfirmationBase64 = handshake.confirmation(serverNonce)).toJson())
        val response = PairResponseFrame.fromJson(read(input, FrameType.PAIR_RESPONSE))
        if (response.status != "ACCEPTED" || response.qrSessionId != payload.sessionId ||
            response.serverId != challenge.serverId || response.serverSpkiBase64 != challenge.serverSpkiBase64 ||
            response.qrNonceBase64 != serverNonce) malformed(payload.sessionId)
        handshake.verify(serverNonce, response.qrConfirmationBase64 ?: malformed(payload.sessionId), accepted = true)
        trustStore.enrollVerifiedPeer(response.serverId, response.serverName, response.serverPlatform, key, host, port)
        response
    }

    fun server(input: DataInputStream, out: DataOutputStream, first: PairRequestFrame,
               identity: DeviceIdentity, name: String, trustStore: PinnedTrustStore): PairResponseFrame {
        val sessionId = first.qrSessionId ?: malformed()
        return withSession(sessionId) {
            val payload = QRPairingSessions.requireActive(sessionId)
            if (payload.hostIdentity != identity.publicIdentity || first.qrConfirmationBase64 != null) malformed(sessionId)
            val key = QRPairingHandshake.validatePeer(first.clientId, first.clientSpkiBase64, trustStore)
            val session = QRPairingSession(QRPairingSession.Role.HOST, identity, payload)
            val handshake = QRPairingHandshake(session, first.clientId, identity.publicIdentity)
            val clientNonce = first.qrNonceBase64 ?: malformed(sessionId)
            val response = PairResponseFrame("CHALLENGE", identity.publicIdentity, name, "android",
                Base64.getEncoder().encodeToString(identity.spkiDer), qrSessionId = sessionId,
                qrNonceBase64 = Base64.getEncoder().encodeToString(session.localNonce),
                qrConfirmationBase64 = handshake.confirmation(clientNonce))
            write(out, FrameType.PAIR_RESPONSE, response.toJson())
            val proof = PairRequestFrame.fromJson(read(input, FrameType.PAIR_REQUEST))
            if (proof.copy(qrConfirmationBase64 = null) != first) malformed(sessionId)
            handshake.verify(clientNonce, proof.qrConfirmationBase64 ?: malformed(sessionId))
            if (!QRPairingSessions.consume(sessionId)) throw NearsideError(NearsideErrorCode.PAIRING_SESSION_EXPIRED,
                "pairQR", "Pairing session expired or already used", correlationId = sessionId)
            trustStore.enrollVerifiedPeer(first.clientId, first.clientName, first.clientPlatform, key)
            val accepted = response.copy(status = "ACCEPTED", qrConfirmationBase64 = handshake.confirmation(clientNonce, accepted = true))
            write(out, FrameType.PAIR_RESPONSE, accepted.toJson())
            accepted
        }
    }
}
