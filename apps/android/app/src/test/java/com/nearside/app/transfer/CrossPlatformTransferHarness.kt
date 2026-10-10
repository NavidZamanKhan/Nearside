package com.nearside.app.transfer

import com.nearside.app.crypto.DeviceIdentity
import com.nearside.app.crypto.PinnedTrustStore
import com.nearside.app.crypto.QRPairingPayload
import com.nearside.app.crypto.QRPairingSessions
import com.nearside.app.crypto.TrustResult
import com.nearside.app.model.TransferStatus
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.net.ServerSocket
import java.net.Socket
import java.util.Base64

/** Invoked explicitly by scripts/verify_secure_transfer.sh, never during regular unit tests. */
object CrossPlatformTransferHarness {
    private fun waitForFile(file: File) {
        val deadline = System.nanoTime() + 30_000_000_000L
        while (!file.isFile) {
            check(System.nanoTime() < deadline) { "Swift harness phase timed out" }
            Thread.sleep(50)
        }
    }

    private fun pairWithSwift(sender: JSONObject, local: DeviceIdentity, trust: PinnedTrustStore,
                              qr: QRPairingPayload): PairResponseFrame {
        Socket("127.0.0.1", sender.getInt("port")).use { socket ->
            socket.soTimeout = 15000
            return QRPairingTransport.client(DataInputStream(socket.getInputStream()), DataOutputStream(socket.getOutputStream()),
                local, "Kotlin harness", qr, trust, "127.0.0.1", sender.getInt("port"))
        }
    }

    @JvmStatic fun main(arguments: Array<String>) = runBlocking {
        val directory = File(arguments.single())
        val sender = JSONObject(File(directory, "sender.json").readText())
        val senderSpki = Base64.getDecoder().decode(sender.getString("spki"))
        val senderIdentity = DeviceIdentity.computeIdentity(senderSpki)
        check(senderIdentity == sender.getString("identity"))
        val senderQR = checkNotNull(QRPairingPayload.fromUri(sender.getString("qrUri")))
        check(senderQR.hostIdentity == senderIdentity && !senderQR.isExpired)
        val local = DeviceIdentity.generateEphemeral()
        val trustFile = File(directory, "android_trust.json")
        val trust = PinnedTrustStore(trustFile)
        check(trust.allEnrolledPeers().isEmpty()) { "Kotlin harness must start without any peer pins" }
        val destination = File(directory, "android_received").apply { mkdirs() }
        ServerSocket(0).use { server ->
            server.soTimeout = 30000
            val qr = QRPairingPayload.createNew(local.publicIdentity, "Kotlin harness", "127.0.0.1", server.localPort)
            QRPairingSessions.register(qr)
            try {
                File(directory, "server.json").writeText(JSONObject().apply {
                    put("identity", local.publicIdentity)
                    put("spki", Base64.getEncoder().encodeToString(local.spkiDer))
                    put("port", server.localPort)
                    put("qrUri", qr.toUri())
                }.toString())

                check(runCatching { pairWithSwift(sender, local, trust, senderQR) }.isFailure) {
                    "Swift QR selected-target mismatch unexpectedly accepted Kotlin"
                }
                check(trust.allEnrolledPeers().isEmpty()) { "Rejected QR target established Kotlin trust" }
                waitForFile(File(directory, "swift_pairing_ready"))
                val response = pairWithSwift(sender, local, trust, senderQR)
                check(response.status == "ACCEPTED" && response.serverId == senderIdentity && response.qrSessionId == senderQR.sessionId) {
                    "Kotlin QR client did not verify final acceptance from the selected identity"
                }
                check(trust.validatePeer(senderSpki) == TrustResult.Success(senderIdentity))
                check(PinnedTrustStore(trustFile).validatePeer(senderSpki) == TrustResult.Success(senderIdentity)) {
                    "Kotlin QR enrollment did not persist its exact public-key pin"
                }
                File(directory, "android_first_pairing").writeText("verified")

                server.accept().use { socket ->
                    socket.soTimeout = 15000
                    val input = DataInputStream(socket.getInputStream())
                    val output = DataOutputStream(socket.getOutputStream())
                    val first = PairRequestFrame.fromJson(QRPairingTransport.read(input, FrameType.PAIR_REQUEST))
                    check(first.clientId == senderIdentity) { "Reverse QR client differs from the intended identity" }
                    val accepted = QRPairingTransport.server(input, output, first, local, "Kotlin harness", trust)
                    check(accepted.status == "ACCEPTED" && accepted.qrSessionId == qr.sessionId)
                }
                check(!QRPairingSessions.consume(qr.sessionId)) { "Successful Kotlin QR session was not consumed" }
                check(trust.canTransfer(senderIdentity))
                check(PinnedTrustStore(trustFile).validatePeer(senderSpki) == TrustResult.Success(senderIdentity))
                File(directory, "android_reverse_pairing").writeText("verified")

                server.accept().use { socket ->
                    val result = TransferEngine.handleInboundConnection(socket, trust, destination, { _, _ -> }, local)
                    val record = result.getOrThrow()
                    check(record.status == TransferStatus.COMPLETED && record.fileCount == 1) {
                        "Swift-to-Kotlin receiver did not verify final completion"
                    }
                }
            } finally { QRPairingSessions.unregister(qr.sessionId) }
        }
        val received = File(destination, "interop.bin")
        val expected = ByteArray(128 * 1024) { (it % 251).toByte() }
        check(received.readBytes().contentEquals(expected)) { "Swift-to-Kotlin on-disk content mismatch" }
        val reverse = TransferEngine.sendFiles(listOf(received), "127.0.0.1", sender.getInt("port"), local.publicIdentity,
            peerIdentity = senderIdentity, trustStore = trust, deviceIdentity = local)
        val sent = reverse.getOrThrow()
        check(sent.totalBytes == expected.size.toLong()) { "Kotlin sender did not receive the encrypted final acknowledgement" }
        File(directory, "android_success").writeText("mutual QR enrollment and authenticated encrypted transfer passed both directions")
        println("CrossPlatformTransferHarness: QR acceptance and durable pins verified; Swift-to-Kotlin checksum verified; Kotlin-to-Swift receiver confirmed")
    }
}
