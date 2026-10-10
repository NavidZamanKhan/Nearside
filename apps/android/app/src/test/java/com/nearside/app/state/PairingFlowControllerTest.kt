package com.nearside.app.state

import com.nearside.app.crypto.DeviceIdentity
import com.nearside.app.crypto.QRPairingPayload
import com.nearside.app.diagnostics.NearsideError
import com.nearside.app.diagnostics.NearsideErrorCode
import org.junit.Assert.*
import org.junit.Test

class PairingFlowControllerTest {
    private val local = DeviceIdentity.generateEphemeral().publicIdentity
    private val target = DeviceIdentity.generateEphemeral().publicIdentity
    private fun payload(identity: String = target) = QRPairingPayload.createNew(identity, "MacBook")

    @Test fun mainScreenActionOpensScanningImmediately() {
        val flow = PairingFlowController()
        flow.openScan()
        assertEquals(PairingPhase.SCANNING, flow.state.value?.phase)
        assertNull(flow.state.value?.expectedIdentity)
    }

    @Test fun discoveredPairActionKeepsExactIdentity() {
        val flow = PairingFlowController()
        flow.openScan("MacBook", target)
        val attempt = flow.begin(payload().toUri(), local)!!
        assertEquals(target, attempt.payload.hostIdentity)
        assertEquals(target, flow.state.value?.expectedIdentity)
        assertEquals(PairingPhase.VERIFYING, flow.state.value?.phase)
        assertTrue(flow.complete(attempt.requestId))
        assertNull(flow.state.value)
    }

    @Test fun matchingDisplayNameCannotSubstituteDifferentIdentity() {
        val flow = PairingFlowController()
        flow.openScan("MacBook", target)
        val other = payload(DeviceIdentity.generateEphemeral().publicIdentity)
        val error = assertThrows(NearsideError::class.java) { flow.begin(other.toUri(), local) }
        assertEquals(NearsideErrorCode.PAIRING_VERIFICATION_FAILED, error.code)
        assertEquals(other.sessionId, error.correlationId)
        assertEquals(PairingPhase.FAILED, flow.state.value?.phase)
        assertEquals(target, flow.state.value?.expectedIdentity)
    }

    @Test fun invalidAndExpiredPayloadsNeverBeginVerification() {
        val flow = PairingFlowController()
        flow.openScan()
        assertEquals(NearsideErrorCode.PAIRING_MALFORMED_PAYLOAD,
            assertThrows(NearsideError::class.java) { flow.begin("https://example.com", local) }.code)
        flow.retry()
        val expired = payload().copy(createdAtSeconds = System.currentTimeMillis() / 1000.0 - 181)
        assertEquals(NearsideErrorCode.PAIRING_SESSION_EXPIRED,
            assertThrows(NearsideError::class.java) { flow.begin(expired.toUri(), local) }.code)
        assertEquals(PairingPhase.FAILED, flow.state.value?.phase)
    }

    @Test fun duplicateFramesCannotStartConcurrentHandshakes() {
        val flow = PairingFlowController()
        flow.openScan()
        val uri = payload().toUri()
        val attempt = flow.begin(uri, local)!!
        repeat(20) { assertNull(flow.begin(uri, local)) }
        assertFalse(flow.cancel())
        assertTrue(flow.complete(attempt.requestId))
    }

    @Test fun retryPreservesSelectedTargetAndIgnoresEarlierCompletion() {
        val flow = PairingFlowController()
        flow.openScan("MacBook", target)
        val attempt = flow.begin(payload().toUri(), local)!!
        flow.fail(attempt.requestId, "Peer unavailable")
        flow.retry()
        assertEquals(target, flow.state.value?.expectedIdentity)
        assertNotEquals(attempt.requestId, flow.state.value?.requestId)
        assertFalse(flow.complete(attempt.requestId))
        assertEquals(PairingPhase.SCANNING, flow.state.value?.phase)
    }

    @Test fun cancellationClearsSelectionWithoutGrantingTrust() {
        val flow = PairingFlowController()
        flow.openScan("MacBook", target)
        val oldRequest = flow.state.value!!.requestId
        assertTrue(flow.cancel())
        assertNull(flow.state.value)
        flow.openScan()
        assertNull(flow.state.value?.expectedIdentity)
        assertFalse(flow.complete(oldRequest))
    }

    @Test fun ownQrCannotEnrollTheLocalDeviceAsAPeer() {
        val flow = PairingFlowController()
        assertEquals(NearsideErrorCode.PAIRING_VERIFICATION_FAILED,
            assertThrows(NearsideError::class.java) { flow.begin(payload(local).toUri(), local) }.code)
    }
}
