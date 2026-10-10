package com.nearside.app.state

import com.nearside.app.crypto.QRPairingPayload
import com.nearside.app.diagnostics.NearsideError
import com.nearside.app.diagnostics.NearsideErrorCode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

enum class PairingPhase { SCANNING, VERIFYING, FAILED }

data class PairingFlowState(
    val requestId: String,
    val targetName: String? = null,
    val expectedIdentity: String? = null,
    val phase: PairingPhase = PairingPhase.SCANNING,
    val errorMessage: String? = null
)

data class PairingAttempt(val requestId: String, val payload: QRPairingPayload)

/** Owns the user's selected identity across capture, verification and retry. */
class PairingFlowController {
    private val mutableState = MutableStateFlow<PairingFlowState?>(null)
    val state = mutableState.asStateFlow()

    @Synchronized fun openScan(targetName: String? = null, expectedIdentity: String? = null) {
        if (mutableState.value?.phase == PairingPhase.VERIFYING) return
        mutableState.value = PairingFlowState(UUID.randomUUID().toString(), targetName, expectedIdentity)
    }

    @Synchronized fun begin(uri: String, localIdentity: String, requestId: String? = null): PairingAttempt? {
        // Camera callbacks can outlive a cancelled or replaced Compose view.
        if (requestId != null && (mutableState.value?.requestId != requestId ||
                mutableState.value?.phase != PairingPhase.SCANNING)) return null
        if (mutableState.value == null) openScan()
        val flow = mutableState.value ?: return null
        if (flow.phase == PairingPhase.VERIFYING) return null
        val payload = QRPairingPayload.fromUri(uri) ?: throw rejection(
            flow, NearsideErrorCode.PAIRING_MALFORMED_PAYLOAD, "Invalid Nearside pairing QR code")
        if (payload.isExpired) throw rejection(flow, NearsideErrorCode.PAIRING_SESSION_EXPIRED,
            "Pairing QR expired. Display a fresh code.", payload.sessionId)
        if (payload.hostIdentity == localIdentity ||
            (flow.expectedIdentity != null && payload.hostIdentity != flow.expectedIdentity)) {
            throw rejection(flow, NearsideErrorCode.PAIRING_VERIFICATION_FAILED,
                "This QR code belongs to a different device. Scan the selected device's QR.", payload.sessionId)
        }
        mutableState.value = flow.copy(phase = PairingPhase.VERIFYING, errorMessage = null)
        return PairingAttempt(flow.requestId, payload)
    }

    @Synchronized fun complete(requestId: String): Boolean {
        if (mutableState.value?.requestId != requestId) return false
        mutableState.value = null
        return true
    }

    @Synchronized fun fail(requestId: String, message: String) {
        val flow = mutableState.value?.takeIf { it.requestId == requestId } ?: return
        mutableState.value = flow.copy(phase = PairingPhase.FAILED, errorMessage = message)
    }

    @Synchronized fun retry() {
        val flow = mutableState.value ?: return
        if (flow.phase == PairingPhase.VERIFYING) return
        mutableState.value = flow.copy(requestId = UUID.randomUUID().toString(), phase = PairingPhase.SCANNING, errorMessage = null)
    }

    @Synchronized fun cancel(): Boolean {
        val flow = mutableState.value ?: return false
        if (flow.phase == PairingPhase.VERIFYING) return false
        mutableState.value = null
        return true
    }

    private fun rejection(flow: PairingFlowState, code: NearsideErrorCode, message: String,
        sessionId: String? = null): NearsideError {
        mutableState.value = flow.copy(phase = PairingPhase.FAILED, errorMessage = message)
        return NearsideError(code, "selectPairingTarget", message, correlationId = sessionId ?: flow.requestId)
    }
}
