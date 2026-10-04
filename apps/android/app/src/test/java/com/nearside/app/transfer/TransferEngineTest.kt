package com.nearside.app.transfer

import com.nearside.app.crypto.DeviceIdentity
import com.nearside.app.crypto.PinnedTrustStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.security.MessageDigest

class TransferEngineTest {

    @Test
    fun testManifestSerialization() {
        val item = TransferItemManifest(
            index = 0,
            name = "archive_backup.tar.gz",
            mimeType = "application/gzip",
            size = 52428800L,
            sha256 = "4b227777d4dd1fc61c6f884f48641d02b4d121d3fd328cb08b5531fcacdabf8a"
        )
        val manifest = TransferManifest(
            transferId = "tx_88a4b2c1d90e",
            senderId = "ns1_39a8bc43d87e51240a1b9f4277cd01ab",
            totalBytes = 52428800L,
            itemCount = 1,
            items = listOf(item)
        )

        val json = manifest.toJson()
        val parsed = TransferManifest.fromJson(json)

        assertEquals(manifest.transferId, parsed.transferId)
        assertEquals(manifest.senderId, parsed.senderId)
        assertEquals(manifest.totalBytes, parsed.totalBytes)
        assertEquals(manifest.itemCount, parsed.itemCount)
        assertEquals(1, parsed.items.size)
        assertEquals(item.name, parsed.items[0].name)
        assertEquals(item.sha256, parsed.items[0].sha256)
    }

    @Test
    fun testAckAndErrorSerialization() {
        val ack = TransferAck(
            transferId = "tx_88a4b2c1d90e",
            status = "ACCEPTED",
            acceptedItems = listOf(0),
            bytesReceived = 0L,
            readyForStream = true
        )
        val ackParsed = TransferAck.fromJson(ack.toJson())
        assertEquals(ack.transferId, ackParsed.transferId)
        assertEquals(ack.status, ackParsed.status)
        assertEquals(listOf(0), ackParsed.acceptedItems)

        val err = ErrorFrame(403, "DEVICE_NOT_PAIRED", "Untrusted peer")
        val errParsed = ErrorFrame.fromJson(err.toJson())
        assertEquals(403, errParsed.code)
        assertEquals("DEVICE_NOT_PAIRED", errParsed.reason)
    }

    @Test
    fun testChunkEncodingAndDecoding() {
        val data = ByteArray(32768) { (it % 256).toByte() }
        val chunk = TransferChunk(itemIndex = 0, offset = 65536L, data = data)

        val encoded = chunk.encode()
        assertEquals(21 + data.size + 32, encoded.size)

        val decodedResult = TransferChunk.decode(encoded)
        assertNotNull(decodedResult)
        val (decodedChunk, consumed) = decodedResult!!

        assertEquals(encoded.size, consumed)
        assertEquals(0, decodedChunk.itemIndex)
        assertEquals(65536L, decodedChunk.offset)
        assertTrue(data.contentEquals(decodedChunk.data))
        assertEquals(chunk.sha256Hex, decodedChunk.sha256Hex)
    }

    @Test
    fun testChunkTamperDetection() {
        val data = "NearsideDataProtectedAgainstTampering".toByteArray(Charsets.UTF_8)
        val chunk = TransferChunk(itemIndex = 1, offset = 0L, data = data)
        val encoded = chunk.encode()

        // Tamper with payload byte
        encoded[25] = (encoded[25].toInt() xor 0xFF).toByte()
        val badDataResult = TransferChunk.decode(encoded)
        assertNull(badDataResult)

        // Tamper with magic bytes
        val badMagic = chunk.encode()
        badMagic[0] = 0x00
        val badMagicResult = TransferChunk.decode(badMagic)
        assertNull(badMagicResult)
    }

    @Test
    fun testRetryPolicyBackoffCalculation() {
        val policy = RetryPolicy(maxAttempts = 3, initialDelayMs = 500L, multiplier = 2.0)
        assertEquals(0L, policy.delayMs(0))
        assertEquals(500L, policy.delayMs(1))
        assertEquals(1000L, policy.delayMs(2))
        assertEquals(2000L, policy.delayMs(3))
    }

    @Test
    fun testPathTraversalRejection() = runBlocking {
        val destDir = Files.createTempDirectory("nearside_sec_dst").toFile()
        val trustStoreFile = Files.createTempFile("nearside_sec_trust", ".json").toFile()
        destDir.deleteOnExit()
        trustStoreFile.deleteOnExit()

        val senderIdentity = DeviceIdentity.generateEphemeral()
        val trustStore = PinnedTrustStore(trustStoreFile)
        trustStore.enroll(senderIdentity.publicIdentity, "Sec Sender", "android", senderIdentity.publicKey)

        val serverSocket = ServerSocket(0)
        val port = serverSocket.localPort

        var serverResult: Result<*>? = null
        val serverJob = CoroutineScope(Dispatchers.IO).launch {
            val client = serverSocket.accept()
            serverResult = TransferEngine.handleInboundConnection(
                socket = client,
                trustStore = trustStore,
                destinationDir = destDir,
                onProgress = { _, _ -> }
            )
            client.close()
            serverSocket.close()
        }

        // Malicious client sending path traversal in item name
        val clientSocket = Socket("127.0.0.1", port)
        val out = DataOutputStream(clientSocket.getOutputStream())
        val input = DataInputStream(clientSocket.getInputStream())

        val badItem = TransferItemManifest(0, "../../malicious.sh", "application/x-sh", 100, "abc")
        val manifest = TransferManifest("tx_bad", senderIdentity.publicIdentity, 100, 1, listOf(badItem))
        val manBytes = manifest.toJson().toString().toByteArray(Charsets.UTF_8)

        val header = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
        header.putInt(TransferChunk.MAGIC)
        header.put(FrameType.MANIFEST.code)
        header.putInt(manBytes.size)
        out.write(header.array())
        out.write(manBytes)
        out.flush()

        // Read server error response
        val errMagic = input.readInt()
        val errType = input.readByte()
        val errLen = input.readInt()
        val errPayload = ByteArray(errLen)
        input.readFully(errPayload)
        val errObj = org.json.JSONObject(String(errPayload, Charsets.UTF_8))

        assertEquals(TransferChunk.MAGIC, errMagic)
        assertEquals(FrameType.ERROR.code, errType)
        assertEquals(400, errObj.getInt("code"))
        assertEquals("INVALID_FILENAME", errObj.getString("reason"))

        clientSocket.close()
        serverJob.join()

        assertNotNull(serverResult)
        assertTrue(serverResult!!.isFailure)
    }

    @Test
    fun testLoopbackSocketTransfer() = runBlocking {
        val tempDir = Files.createTempDirectory("nearside_tx_src").toFile()
        val destDir = Files.createTempDirectory("nearside_tx_dst").toFile()
        val trustStoreFile = Files.createTempFile("nearside_trust", ".json").toFile()
        tempDir.deleteOnExit()
        destDir.deleteOnExit()
        trustStoreFile.deleteOnExit()

        val senderIdentity = DeviceIdentity.generateEphemeral()
        val trustStore = PinnedTrustStore(trustStoreFile)
        trustStore.enroll(senderIdentity.publicIdentity, "Android Sender", "android", senderIdentity.publicKey)

        // Create test file (128 KiB)
        val testFile = File(tempDir, "test_file.bin")
        val content = ByteArray(128 * 1024) { (it % 251).toByte() }
        testFile.writeBytes(content)

        val serverSocket = ServerSocket(0)
        val port = serverSocket.localPort

        var serverResult: Result<*>? = null
        val serverJob = CoroutineScope(Dispatchers.IO).launch {
            val client = serverSocket.accept()
            serverResult = TransferEngine.handleInboundConnection(
                socket = client,
                trustStore = trustStore,
                destinationDir = destDir,
                onProgress = { _, _ -> }
            )
            client.close()
            serverSocket.close()
        }

        // Run client sender
        val clientResult = TransferEngine.sendFiles(
            files = listOf(testFile),
            host = "127.0.0.1",
            port = port,
            senderId = senderIdentity.publicIdentity,
            onProgress = { _, _, _ -> }
        )

        assertTrue(clientResult.isSuccess)
        serverJob.join()

        assertNotNull(serverResult)
        assertTrue(serverResult!!.isSuccess)

        val receivedFile = File(destDir, "test_file.bin")
        assertTrue(receivedFile.exists())
        assertEquals(content.size.toLong(), receivedFile.length())
        assertTrue(content.contentEquals(receivedFile.readBytes()))
    }

    @Test
    fun testInterruptionAndResumeTransfer() = runBlocking {
        val tempDir = Files.createTempDirectory("nearside_resume_src").toFile()
        val destDir = Files.createTempDirectory("nearside_resume_dst").toFile()
        val trustStoreFile = Files.createTempFile("nearside_resume_trust", ".json").toFile()
        tempDir.deleteOnExit()
        destDir.deleteOnExit()
        trustStoreFile.deleteOnExit()

        val senderIdentity = DeviceIdentity.generateEphemeral()
        val trustStore = PinnedTrustStore(trustStoreFile)
        trustStore.enroll(senderIdentity.publicIdentity, "Resume Sender", "android", senderIdentity.publicKey)

        // 128 KiB full file
        val filename = "resumable_file.bin"
        val fullFile = File(tempDir, filename)
        val content = ByteArray(128 * 1024) { ((it * 7) % 251).toByte() }
        fullFile.writeBytes(content)

        // Pre-populate destination with exactly first 64 KiB (simulating interrupted previous transfer)
        val partialDestFile = File(destDir, filename)
        val firstHalf = content.copyOfRange(0, 64 * 1024)
        partialDestFile.writeBytes(firstHalf)
        assertEquals(64 * 1024L, partialDestFile.length())

        val serverSocket = ServerSocket(0)
        val port = serverSocket.localPort

        var serverResult: Result<*>? = null
        val serverJob = CoroutineScope(Dispatchers.IO).launch {
            val client = serverSocket.accept()
            serverResult = TransferEngine.handleInboundConnection(
                socket = client,
                trustStore = trustStore,
                destinationDir = destDir,
                onProgress = { _, _ -> }
            )
            client.close()
            serverSocket.close()
        }

        // Send file: should detect partial 64 KiB, negotiate resume, stream only remaining 64 KiB
        var reportedStartBytes = -1L
        val clientResult = TransferEngine.sendFiles(
            files = listOf(fullFile),
            host = "127.0.0.1",
            port = port,
            senderId = senderIdentity.publicIdentity,
            onProgress = { _, current, _ ->
                if (reportedStartBytes == -1L) {
                    reportedStartBytes = current
                }
            }
        )

        assertTrue(clientResult.isSuccess)
        serverJob.join()

        assertNotNull(serverResult)
        assertTrue(serverResult!!.isSuccess)

        // Verify destination file now has full 128 KiB and exactly matches
        assertTrue(partialDestFile.exists())
        assertEquals(content.size.toLong(), partialDestFile.length())
        assertTrue(content.contentEquals(partialDestFile.readBytes()))
    }
}
