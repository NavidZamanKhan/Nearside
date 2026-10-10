package com.nearside.app.transfer

import com.nearside.app.crypto.DeviceIdentity
import com.nearside.app.crypto.PinnedTrustStore
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import java.io.File
import java.net.ServerSocket
import java.util.Base64

/** Invoked explicitly by scripts/verify_secure_transfer.sh, never during regular unit tests. */
object CrossPlatformTransferHarness {
    @JvmStatic fun main(arguments: Array<String>) = runBlocking {
        val directory = File(arguments.single())
        val sender = JSONObject(File(directory, "sender.json").readText())
        val senderSpki = Base64.getDecoder().decode(sender.getString("spki"))
        val senderIdentity = DeviceIdentity.computeIdentity(senderSpki)
        check(senderIdentity == sender.getString("identity"))
        val local = DeviceIdentity.generateEphemeral()
        val trust = PinnedTrustStore()
        trust.enroll(senderIdentity, "Swift harness", "macos", DeviceIdentity.decodePublicKey(senderSpki))
        val destination = File(directory, "android_received").apply { mkdirs() }
        ServerSocket(0).use { server ->
            server.soTimeout = 30000
            File(directory, "server.json").writeText(JSONObject().apply {
                put("identity", local.publicIdentity)
                put("spki", Base64.getEncoder().encodeToString(local.spkiDer))
                put("port", server.localPort)
            }.toString())
            server.accept().use { socket ->
                val result = TransferEngine.handleInboundConnection(socket, trust, destination, { _, _ -> }, local)
                check(result.isSuccess) { "Swift-to-Kotlin transfer failed: ${result.exceptionOrNull()}" }
            }
        }
        val received = File(destination, "interop.bin")
        val expected = ByteArray(128 * 1024) { (it % 251).toByte() }
        check(received.readBytes().contentEquals(expected)) { "Swift-to-Kotlin on-disk content mismatch" }
        val reverse = TransferEngine.sendFiles(listOf(received), "127.0.0.1", sender.getInt("port"), local.publicIdentity,
            peerIdentity = senderIdentity, trustStore = trust, deviceIdentity = local)
        check(reverse.isSuccess) { "Kotlin-to-Swift transfer failed: ${reverse.exceptionOrNull()}" }
        File(directory, "android_success").writeText("authenticated encrypted transfer passed both directions")
        println("CrossPlatformTransferHarness: Swift-to-Kotlin verified; Kotlin-to-Swift receiver confirmed")
    }
}
