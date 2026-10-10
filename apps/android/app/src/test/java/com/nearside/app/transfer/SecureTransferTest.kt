package com.nearside.app.transfer

import com.nearside.app.crypto.DeviceIdentity
import com.nearside.app.crypto.PinnedTrustStore
import org.junit.Assert.*
import org.junit.Test
import java.security.MessageDigest
import java.util.Base64

class SecureTransferTest {
    @Test fun signedHandshakeDerivesDirectionalEncryptedRecords() {
        val clientIdentity = DeviceIdentity.generateEphemeral()
        val serverIdentity = DeviceIdentity.generateEphemeral()
        val clientTrust = PinnedTrustStore()
        val serverTrust = PinnedTrustStore()
        clientTrust.enroll(serverIdentity.publicIdentity, "Server", "macos", serverIdentity.publicKey)
        serverTrust.enroll(clientIdentity.publicIdentity, "Client", "android", clientIdentity.publicKey)
        val client = SecureTransferHandshake(clientIdentity, serverIdentity.publicIdentity)
        val server = SecureTransferHandshake(serverIdentity, clientIdentity.publicIdentity)
        val clientHello = client.hello("client")
        server.validate(clientHello, "client", ByteArray(0), serverTrust)
        val binding = MessageDigest.getInstance("SHA-256").digest(clientHello.canonical())
        val serverHello = server.hello("server", binding)
        client.validate(serverHello, "server", binding, clientTrust)
        val send = client.records(clientHello, serverHello, true)
        val receive = server.records(clientHello, serverHello, false)
        val payload = "secret filename and content".toByteArray()
        val ciphertext = send.seal(payload)
        assertFalse(ciphertext.contentEquals(payload))
        assertArrayEquals(payload, receive.open(ciphertext))
        assertArrayEquals("accepted".toByteArray(), send.open(receive.seal("accepted".toByteArray())))
        assertThrows(Exception::class.java) { receive.open(ciphertext) }
    }

    @Test fun handshakeRejectsDifferentEnrolledRecipientAndTamperedSignature() {
        val sender = DeviceIdentity.generateEphemeral()
        val expected = DeviceIdentity.generateEphemeral()
        val attacker = DeviceIdentity.generateEphemeral()
        val trust = PinnedTrustStore()
        trust.enroll(expected.publicIdentity, "Same name", "macos", expected.publicKey)
        trust.enroll(attacker.publicIdentity, "Same name", "macos", attacker.publicKey)
        val client = SecureTransferHandshake(sender, expected.publicIdentity)
        val wrongPeer = SecureTransferHandshake(attacker, sender.publicIdentity).hello("server")
        assertThrows(Exception::class.java) { client.validate(wrongPeer, "server", ByteArray(0), trust) }
        val valid = SecureTransferHandshake(expected, sender.publicIdentity).hello("server")
        client.validate(valid, "server", ByteArray(0), trust)
        val signature = Base64.getDecoder().decode(valid.signature).apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }
        assertThrows(Exception::class.java) { client.validate(valid.copy(signature = Base64.getEncoder().encodeToString(signature)), "server", ByteArray(0), trust) }
        assertThrows(Exception::class.java) { client.validate(valid.copy(target = attacker.publicIdentity), "server", ByteArray(0), trust) }
        trust.block(expected.publicIdentity)
        assertThrows(Exception::class.java) { client.validate(valid, "server", ByteArray(0), trust) }
    }

    @Test fun encryptedRecordsRejectTamperingAndWrongDirection() {
        val client = SecureTransferRecords(ByteArray(32) { 1 }, ByteArray(32) { 2 }, ByteArray(32) { 3 }, true)
        val server = SecureTransferRecords(ByteArray(32) { 1 }, ByteArray(32) { 2 }, ByteArray(32) { 3 }, false)
        val encrypted = client.seal("content".toByteArray())
        assertThrows(Exception::class.java) { client.open(encrypted) }
        encrypted[0] = (encrypted[0].toInt() xor 1).toByte()
        assertThrows(Exception::class.java) { server.open(encrypted) }
        assertThrows(Exception::class.java) { server.open(ByteArray(16)) }
        assertThrows(Exception::class.java) { client.seal(ByteArray(SecureTransferRecords.MAX_RECORD + 1)) }
    }
}
