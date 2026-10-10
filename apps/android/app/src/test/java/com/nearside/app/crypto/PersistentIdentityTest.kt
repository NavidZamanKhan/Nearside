package com.nearside.app.crypto

import com.nearside.app.diagnostics.*
import org.junit.Assert.*
import org.junit.Test

class PersistentIdentityTest {
    @Test fun existingIdentityIsReturnedWithoutCreatingAnotherKey() {
        val identity = DeviceIdentity.generateEphemeral()
        val loaded = DeviceIdentity.loadPersistentIdentity({ identity }, { error("Creation must not run") })
        assertSame(identity, loaded)
    }

    @Test fun deniedKeyReadDoesNotCreateAnEphemeralReplacement() {
        var creations = 0
        val denied = java.security.KeyStoreException("Key access denied")
        try {
            DeviceIdentity.loadPersistentIdentity({ throw denied }, { creations++; DeviceIdentity.generateEphemeral() })
            fail("Key access failure must propagate")
        } catch (error: NearsideError) {
            assertEquals(NearsideErrorCode.TRUST_STORAGE_FAILED, error.code)
            assertSame(denied, error.underlyingError)
        }
        assertEquals(0, creations)
    }

    @Test fun failedKeyCreationCannotReturnAnUnpersistedIdentity() {
        val failure = java.security.ProviderException("Keystore unavailable")
        try {
            DeviceIdentity.loadPersistentIdentity({ null }, { throw failure })
            fail("Creation failure must propagate")
        } catch (error: NearsideError) {
            assertSame(failure, error.underlyingError)
        }
    }
}
