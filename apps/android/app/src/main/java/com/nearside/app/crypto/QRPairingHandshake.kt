package com.nearside.app.crypto

import com.nearside.app.diagnostics.NearsideError
import com.nearside.app.diagnostics.NearsideErrorCode
import java.util.Base64

/** Mutually confirms the scanned secret and binds it to both SPKI identities and fresh nonces. */
class QRPairingHandshake(
    private val session: QRPairingSession,
    private val clientIdentity: String,
    private val serverIdentity: String
) {
    fun confirmation(remoteNonceBase64: String, accepted: Boolean = false): String {
        val transcript = transcript(remoteNonceBase64)
        return Base64.getEncoder().encodeToString(session.generateConfirmation(session.deriveConfirmationKeys(transcript), if (accepted) transcript + "nearside-qr-accepted".toByteArray(Charsets.UTF_8) else transcript))
    }

    fun verify(remoteNonceBase64: String, confirmationBase64: String, accepted: Boolean = false) {
        val transcript = transcript(remoteNonceBase64)
        val keys = session.deriveConfirmationKeys(transcript)
        val expectedKey = if (session.role == QRPairingSession.Role.CLIENT) keys.second else keys.first
        val mac = decode(confirmationBase64)
        if (!session.verifyPeerConfirmation(mac, expectedKey, if (accepted) transcript + "nearside-qr-accepted".toByteArray(Charsets.UTF_8) else transcript)) fail("QR confirmation failed")
    }

    private fun transcript(remoteNonceBase64: String): ByteArray {
        if (session.payload.isExpired) throw NearsideError(NearsideErrorCode.PAIRING_SESSION_EXPIRED,
            "verifyQR", "Pairing session expired", correlationId = session.payload.sessionId)
        val nonce = decode(remoteNonceBase64)
        if (nonce.size != 32) fail("Invalid QR nonce")
        if (serverIdentity != session.payload.hostIdentity) fail("Scanned host identity mismatch")
        return session.buildTranscript(nonce, clientIdentity, serverIdentity)
    }

    private fun decode(encoded: String): ByteArray = try { Base64.getDecoder().decode(encoded) }
        catch (_: IllegalArgumentException) { fail("Malformed QR proof") }

    private fun fail(message: String): Nothing = throw NearsideError(NearsideErrorCode.PAIRING_VERIFICATION_FAILED,
        "verifyQR", message, correlationId = session.payload.sessionId)

    companion object {
        fun validatePeer(identity: String, spkiBase64: String, trustStore: PinnedTrustStore): java.security.PublicKey {
            val spki = try { Base64.getDecoder().decode(spkiBase64) } catch (_: Exception) {
                throw NearsideError(NearsideErrorCode.PAIRING_MALFORMED_PAYLOAD, "verifyQR", "Malformed peer public key")
            }
            if (DeviceIdentity.computeIdentity(spki) != identity) throw NearsideError(
                NearsideErrorCode.TRUST_KEY_MISMATCH, "verifyQR", "Peer identity does not match public key")
            when (trustStore.validatePeer(spki)) {
                is TrustResult.PeerBlocked -> throw NearsideError(NearsideErrorCode.TRUST_PEER_BLOCKED, "verifyQR", "Peer is blocked")
                is TrustResult.KeyMismatch -> throw NearsideError(NearsideErrorCode.TRUST_KEY_MISMATCH, "verifyQR", "Peer key differs from pinned key")
                else -> Unit
            }
            return DeviceIdentity.decodePublicKey(spki)
        }
    }
}
