package com.nearside.app.transfer

import com.nearside.app.crypto.DeviceIdentity
import com.nearside.app.crypto.PinnedTrustStore
import com.nearside.app.model.PayloadType
import com.nearside.app.model.TransferStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.nio.file.Files
import java.security.MessageDigest

class ClipboardTransferTest {

    @Test
    fun testBuildTextManifestForPlainText() {
        val snippet = "Hello Nearside Clipboard!"
        val (manifest, tempFile) = TransferEngine.buildTextManifest(
            text = snippet,
            isUrl = false,
            senderId = "ns1_sender_test"
        )

        try {
            assertEquals("tx_", manifest.transferId.take(3))
            assertEquals("ns1_sender_test", manifest.senderId)
            assertEquals(1, manifest.itemCount)
            assertEquals(1, manifest.items.size)

            val item = manifest.items[0]
            assertEquals("clipboard.txt", item.name)
            assertEquals("text/plain", item.mimeType)
            assertEquals(snippet.toByteArray(Charsets.UTF_8).size.toLong(), item.size)

            val expectedSha = MessageDigest.getInstance("SHA-256")
                .digest(snippet.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            assertEquals(expectedSha, item.sha256)
        } finally {
            tempFile.delete()
        }
    }

    @Test
    fun testBuildTextManifestForUrl() {
        val link = "https://github.com/NavidZamanKhan/Nearside"
        val (manifest, tempFile) = TransferEngine.buildTextManifest(
            text = link,
            isUrl = true,
            senderId = "ns1_sender_test"
        )

        try {
            assertEquals("tx_", manifest.transferId.take(3))
            assertEquals(1, manifest.itemCount)

            val item = manifest.items[0]
            assertEquals("link.url", item.name)
            assertEquals("text/uri-list", item.mimeType)
            assertEquals(link.toByteArray(Charsets.UTF_8).size.toLong(), item.size)

            val expectedSha = MessageDigest.getInstance("SHA-256")
                .digest(link.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            assertEquals(expectedSha, item.sha256)
        } finally {
            tempFile.delete()
        }
    }

    @Test
    fun testEndToEndTextTransfer() {
        runBlocking {
            val tempDir = Files.createTempDirectory("nearside_rx_text_test").toFile()
            val trustStoreFile = Files.createTempFile("nearside_trust_text", ".json").toFile()
            val senderIdentity = DeviceIdentity.generateEphemeral()
            val receiverTrustStore = PinnedTrustStore(trustStoreFile)
            receiverTrustStore.enroll(
                identity = senderIdentity.publicIdentity,
                name = "Test Sender",
                platform = "macos",
                publicKey = senderIdentity.publicKey
            )

            val server = ServerSocket(0)
            val port = server.localPort

            val textToSend = "Swift and Kotlin cross-platform clipboard sharing works flawlessly!"
            var receivedRecord: com.nearside.app.model.TransferRecord? = null

            val serverJob = CoroutineScope(Dispatchers.IO).launch {
                val client = server.accept()
                val rxResult = TransferEngine.handleInboundConnection(
                    socket = client,
                    trustStore = receiverTrustStore,
                    destinationDir = tempDir,
                    onProgress = { _, _ -> }
                )
                assertTrue("Receiver must succeed", rxResult.isSuccess)
                receivedRecord = rxResult.getOrNull()
            }

            val sendResult = TransferEngine.sendText(
                text = textToSend,
                isUrl = false,
                host = "127.0.0.1",
                port = port,
                senderId = senderIdentity.publicIdentity,
                onProgress = { _, _, _ -> }
            )

            serverJob.join()
            server.close()

            assertTrue("Sender must report success", sendResult.isSuccess)
            assertNotNull("Receiver record must exist", receivedRecord)
            assertEquals(TransferStatus.COMPLETED, receivedRecord!!.status)
            assertEquals(PayloadType.TEXT, receivedRecord!!.payloadType)
            assertEquals(textToSend, receivedRecord!!.payloadText)

            tempDir.deleteRecursively()
            trustStoreFile.delete()
        }
    }

    @Test
    fun testEndToEndUrlTransfer() {
        runBlocking {
            val tempDir = Files.createTempDirectory("nearside_rx_url_test").toFile()
            val trustStoreFile = Files.createTempFile("nearside_trust_url", ".json").toFile()
            val senderIdentity = DeviceIdentity.generateEphemeral()
            val receiverTrustStore = PinnedTrustStore(trustStoreFile)
            receiverTrustStore.enroll(
                identity = senderIdentity.publicIdentity,
                name = "Test Sender",
                platform = "ios",
                publicKey = senderIdentity.publicKey
            )

            val server = ServerSocket(0)
            val port = server.localPort

            val urlToSend = "https://nearside.local/transfer/test"
            var receivedRecord: com.nearside.app.model.TransferRecord? = null

            val serverJob = CoroutineScope(Dispatchers.IO).launch {
                val client = server.accept()
                val rxResult = TransferEngine.handleInboundConnection(
                    socket = client,
                    trustStore = receiverTrustStore,
                    destinationDir = tempDir,
                    onProgress = { _, _ -> }
                )
                assertTrue("Receiver must succeed", rxResult.isSuccess)
                receivedRecord = rxResult.getOrNull()
            }

            val sendResult = TransferEngine.sendText(
                text = urlToSend,
                isUrl = true,
                host = "127.0.0.1",
                port = port,
                senderId = senderIdentity.publicIdentity,
                onProgress = { _, _, _ -> }
            )

            serverJob.join()
            server.close()

            assertTrue("Sender must report success", sendResult.isSuccess)
            assertNotNull("Receiver record must exist", receivedRecord)
            assertEquals(TransferStatus.COMPLETED, receivedRecord!!.status)
            assertEquals(PayloadType.URL, receivedRecord!!.payloadType)
            assertEquals(urlToSend, receivedRecord!!.payloadText)

            tempDir.deleteRecursively()
            trustStoreFile.delete()
        }
    }
}
