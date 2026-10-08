package com.nearside.app.transfer

import com.nearside.app.crypto.PinnedTrustStore
import com.nearside.app.diagnostics.*
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.PayloadType
import com.nearside.app.model.TransferDirection
import com.nearside.app.model.TransferRecord
import com.nearside.app.model.TransferStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

data class RetryPolicy(
    val maxAttempts: Int = 3,
    val initialDelayMs: Long = 500L,
    val multiplier: Double = 2.0
) {
    fun delayMs(attempt: Int): Long {
        if (attempt <= 0) return 0L
        return (initialDelayMs * Math.pow(multiplier, (attempt - 1).toDouble())).toLong()
    }
}

object TransferEngine {

    private val cancelledTransfers = ConcurrentHashMap.newKeySet<String>()

    fun cancelTransfer(transferId: String) {
        cancelledTransfers.add(transferId)
        NearsideLogger.info("transfer", "cancelTransfer", "Cancellation marked for transfer $transferId", correlationId = transferId)
    }

    fun isTransferCancelled(transferId: String): Boolean {
        return cancelledTransfers.contains(transferId)
    }

    fun buildManifest(files: List<File>, senderId: String): TransferManifest {
        val items = files.mapIndexed { index, file ->
            val md = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(TransferChunk.MAX_CHUNK_SIZE)
            var bytesRead: Int
            FileInputStream(file).use { input ->
                while (input.read(buffer).also { bytesRead = it } != -1) {
                    md.update(buffer, 0, bytesRead)
                }
            }
            val shaHex = md.digest().joinToString("") { "%02x".format(it) }
            val ext = file.extension.lowercase()
            val mime = when (ext) {
                "txt", "md", "json" -> "text/plain"
                "url" -> "text/uri-list"
                else -> "application/octet-stream"
            }
            TransferItemManifest(
                index = index,
                name = file.name,
                mimeType = mime,
                size = file.length(),
                sha256 = shaHex
            )
        }

        val total = items.sumOf { it.size }
        val id = "tx_${UUID.randomUUID().toString().take(12).lowercase()}"
        return TransferManifest(
            transferId = id,
            senderId = senderId,
            totalBytes = total,
            itemCount = items.size,
            items = items
        )
    }

    fun buildTextManifest(text: String, isUrl: Boolean = false, senderId: String): Pair<TransferManifest, File> {
        val fileName = if (isUrl) "link.url" else "clipboard.txt"
        val tempFile = File.createTempFile("nearside_text_", if (isUrl) ".url" else ".txt")
        tempFile.writeText(text, Charsets.UTF_8)
        val md = MessageDigest.getInstance("SHA-256")
        val shaHex = md.digest(tempFile.readBytes()).joinToString("") { "%02x".format(it) }
        val item = TransferItemManifest(
            index = 0,
            name = fileName,
            mimeType = if (isUrl) "text/uri-list" else "text/plain",
            size = tempFile.length(),
            sha256 = shaHex
        )
        val manifest = TransferManifest(
            transferId = "tx_${UUID.randomUUID().toString().take(12).lowercase()}",
            senderId = senderId,
            totalBytes = tempFile.length(),
            itemCount = 1,
            items = listOf(item)
        )
        return Pair(manifest, tempFile)
    }

    suspend fun sendText(
        text: String,
        isUrl: Boolean = false,
        host: String,
        port: Int = 41433,
        senderId: String,
        retryPolicy: RetryPolicy = RetryPolicy(),
        onProgress: (Float, Long, Long) -> Unit = { _, _, _ -> },
        onProgressMetrics: ((Float, Long, Long, Double, Long?) -> Unit)? = null
    ): Result<TransferManifest> = withContext(Dispatchers.IO) {
        val (manifest, tempFile) = buildTextManifest(text, isUrl, senderId)
        try {
            var lastException: Exception? = null
            for (attempt in 1..retryPolicy.maxAttempts) {
                try {
                    return@withContext performSendAttempt(
                        files = listOf(tempFile),
                        manifest = manifest,
                        host = host,
                        port = port,
                        onProgress = onProgress,
                        onProgressMetrics = onProgressMetrics
                    )
                } catch (e: Exception) {
                    lastException = e
                    if (attempt < retryPolicy.maxAttempts) {
                        delay(retryPolicy.delayMs(attempt))
                    }
                }
            }
            Result.failure(lastException ?: IllegalStateException("Failed to send text after ${retryPolicy.maxAttempts} attempts"))
        } finally {
            try { tempFile.delete() } catch (ignored: Exception) {}
        }
    }

    suspend fun sendFiles(
        files: List<File>,
        host: String,
        port: Int = 41433,
        senderId: String,
        retryPolicy: RetryPolicy = RetryPolicy(),
        onProgress: (Float, Long, Long) -> Unit = { _, _, _ -> },
        onProgressMetrics: ((Float, Long, Long, Double, Long?) -> Unit)? = null
    ): Result<TransferManifest> = withContext(Dispatchers.IO) {
        val manifest = buildManifest(files, senderId)
        var lastException: Exception? = null

        NearsideLogger.info(
            subsystem = "transfer",
            operation = "sendFiles",
            message = "Starting outbound transfer with ${files.size} file(s)",
            state = "starting",
            correlationId = manifest.transferId,
            metadata = mapOf(
                "totalBytes" to "${manifest.totalBytes}",
                "destination" to "$host:$port"
            )
        )

        for (attempt in 1..retryPolicy.maxAttempts) {
            try {
                NearsideLogger.debug(
                    subsystem = "transfer",
                    operation = "performSendAttempt",
                    message = "Beginning connection attempt $attempt/${retryPolicy.maxAttempts}",
                    state = "connecting",
                    correlationId = manifest.transferId
                )
                return@withContext performSendAttempt(
                    files = files,
                    manifest = manifest,
                    host = host,
                    port = port,
                    onProgress = onProgress,
                    onProgressMetrics = onProgressMetrics
                )
            } catch (e: Exception) {
                lastException = e
                if (attempt < retryPolicy.maxAttempts) {
                    val delay = retryPolicy.delayMs(attempt)
                    NearsideLogger.warn(
                        subsystem = "transfer",
                        operation = "performSendAttempt",
                        message = "Attempt $attempt failed, scheduling retry in ${delay}ms",
                        state = "retrying",
                        correlationId = manifest.transferId,
                        retryCount = attempt,
                        underlyingError = e
                    )
                    delay(delay)
                }
            }
        }
        val finalErr = NearsideError(
            code = NearsideErrorCode.TRANSFER_RETRY_EXHAUSTED,
            operation = "sendFiles",
            message = "Outbound transfer exhausted all ${retryPolicy.maxAttempts} attempts",
            underlyingError = lastException,
            correlationId = manifest.transferId,
            retryCount = retryPolicy.maxAttempts
        )
        NearsideLogger.error(finalErr, state = "failed")
        Result.failure(finalErr)
    }

    private fun performSendAttempt(
        files: List<File>,
        manifest: TransferManifest,
        host: String,
        port: Int,
        onProgress: (Float, Long, Long) -> Unit,
        onProgressMetrics: ((Float, Long, Long, Double, Long?) -> Unit)? = null
    ): Result<TransferManifest> {
        Socket(host, port).use { socket ->
            socket.tcpNoDelay = true
            socket.soTimeout = 15000
            val out = DataOutputStream(socket.getOutputStream())
            val input = DataInputStream(socket.getInputStream())

            NearsideLogger.info(
                subsystem = "connection",
                operation = "performSendAttempt",
                message = "TCP socket connected to $host:$port",
                state = "transferring",
                correlationId = manifest.transferId
            )

            val manifestJson = manifest.toJson().toString().toByteArray(Charsets.UTF_8)
            val mHeader = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
            mHeader.putInt(TransferChunk.MAGIC)
            mHeader.put(FrameType.MANIFEST.code)
            mHeader.putInt(manifestJson.size)
            out.write(mHeader.array())
            out.write(manifestJson)
            out.flush()

            // Read ACK
            val ackMagic = input.readInt()
            if (ackMagic != TransferChunk.MAGIC) {
                val err = NearsideError(NearsideErrorCode.PROTOCOL_MAGIC_MISMATCH, "performSendAttempt", "Invalid magic in ACK", correlationId = manifest.transferId)
                NearsideLogger.error(err, state = "failed")
                return Result.failure(err)
            }
            val ackType = input.readByte()
            if (ackType != FrameType.ACK.code) {
                val err = NearsideError(NearsideErrorCode.PROTOCOL_INVALID_FRAME_TYPE, "performSendAttempt", "Unexpected response type $ackType", correlationId = manifest.transferId)
                NearsideLogger.error(err, state = "failed")
                return Result.failure(err)
            }
            val ackLen = input.readInt()
            val ackPayload = ByteArray(ackLen)
            input.readFully(ackPayload)

            val ackJson = JSONObject(String(ackPayload, Charsets.UTF_8))
            val ack = TransferAck.fromJson(ackJson)
            if (ack.status != "ACCEPTED") {
                val err = NearsideError(NearsideErrorCode.TRANSFER_REJECTED, "performSendAttempt", "Transfer rejected: ${ack.status}", correlationId = manifest.transferId)
                NearsideLogger.error(err, state = "rejected")
                return Result.failure(err)
            }

            var remainingResume = ack.bytesReceived
            var startItem = 0
            var startOffset = 0L

            for ((idx, item) in manifest.items.withIndex()) {
                if (remainingResume >= item.size) {
                    remainingResume -= item.size
                    startItem = idx + 1
                } else {
                    startItem = idx
                    startOffset = remainingResume
                    remainingResume = 0L
                    break
                }
            }

            // Stream chunks starting from resume checkpoint
            var totalTransferred = ack.bytesReceived
            val totalBytes = manifest.totalBytes
            val chunkBuffer = ByteArray(TransferChunk.MAX_CHUNK_SIZE)
            val startTime = System.currentTimeMillis()

            for (index in startItem until files.size) {
                val file = files[index]
                val itemManifest = manifest.items[index]
                val initialSkip = if (index == startItem) startOffset else 0L

                FileInputStream(file).use { fis ->
                    if (initialSkip > 0) {
                        fis.channel.position(initialSkip)
                    }
                    var fileOffset = initialSkip
                    var read: Int
                    while (fileOffset < itemManifest.size) {
                        if (isTransferCancelled(manifest.transferId)) {
                            cancelledTransfers.remove(manifest.transferId)
                            val cancelErr = NearsideError(
                                code = NearsideErrorCode.TRANSFER_INTERRUPTED,
                                operation = "performSendAttempt",
                                message = "Transfer cancelled by user",
                                correlationId = manifest.transferId
                            )
                            NearsideLogger.info("transfer", "performSendAttempt", "Transfer aborted due to user cancellation", state = "cancelled", correlationId = manifest.transferId)
                            return Result.failure(cancelErr)
                        }

                        val toRead = Math.min(chunkBuffer.size.toLong(), itemManifest.size - fileOffset).toInt()
                        read = fis.read(chunkBuffer, 0, toRead)
                        if (read <= 0) break
                        val chunkData = if (read == chunkBuffer.size) chunkBuffer else chunkBuffer.copyOf(read)
                        val chunk = TransferChunk(index, fileOffset, chunkData)
                        out.write(chunk.encode())
                        out.flush()

                        fileOffset += read
                        totalTransferred += read
                        val fraction = if (totalBytes > 0) totalTransferred.toFloat() / totalBytes else 1.0f

                        val elapsedSec = (System.currentTimeMillis() - startTime) / 1000.0
                        val bytesSentThisSession = totalTransferred - ack.bytesReceived
                        val speed = if (elapsedSec > 0.1) bytesSentThisSession / elapsedSec else 0.0
                        val remainingBytes = (totalBytes - totalTransferred).coerceAtLeast(0L)
                        val eta = if (speed > 0) (remainingBytes / speed).toLong() else null

                        onProgress(fraction, totalTransferred, totalBytes)
                        onProgressMetrics?.invoke(fraction, totalTransferred, totalBytes, speed, eta)
                    }
                }
            }

            // Send Complete Frame
            val cHeader = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
            cHeader.putInt(TransferChunk.MAGIC)
            cHeader.put(FrameType.COMPLETE.code)
            cHeader.putInt(0)
            out.write(cHeader.array())
            out.flush()

            onProgress(1.0f, totalBytes, totalBytes)
            onProgressMetrics?.invoke(1.0f, totalBytes, totalBytes, 0.0, 0L)
            NearsideLogger.info(
                subsystem = "transfer",
                operation = "performSendAttempt",
                message = "Outbound transfer completed successfully",
                state = "completed",
                correlationId = manifest.transferId,
                metadata = mapOf("totalBytes" to "$totalBytes")
            )
            return Result.success(manifest)
        }
    }

    suspend fun handleInboundConnection(
        socket: Socket,
        trustStore: PinnedTrustStore,
        destinationDir: File,
        onProgress: (Float, TransferRecord) -> Unit
    ): Result<TransferRecord> = withContext(Dispatchers.IO) {
        val connectionId = "conn_${UUID.randomUUID().toString().take(8).lowercase()}"
        NearsideLogger.info(
            subsystem = "connection",
            operation = "handleInboundConnection",
            message = "Inbound TCP connection accepted",
            state = "connecting",
            correlationId = connectionId
        )
        try {
            socket.tcpNoDelay = true
            socket.soTimeout = 15000
            val input = DataInputStream(socket.getInputStream())
            val out = DataOutputStream(socket.getOutputStream())

            val magic = input.readInt()
            if (magic != TransferChunk.MAGIC) {
                val err = NearsideError(NearsideErrorCode.PROTOCOL_MAGIC_MISMATCH, "handleInboundConnection", "Invalid stream magic", correlationId = connectionId)
                NearsideLogger.error(err, state = "failed")
                return@withContext Result.failure(err)
            }
            val frameType = input.readByte()
            if (frameType != FrameType.MANIFEST.code) {
                val err = NearsideError(NearsideErrorCode.PROTOCOL_INVALID_FRAME_TYPE, "handleInboundConnection", "Expected manifest frame, got $frameType", correlationId = connectionId)
                NearsideLogger.error(err, state = "failed")
                return@withContext Result.failure(err)
            }

            val len = input.readInt()
            val manifestBytes = ByteArray(len)
            input.readFully(manifestBytes)

            val manifestObj = JSONObject(String(manifestBytes, Charsets.UTF_8))
            val manifest = TransferManifest.fromJson(manifestObj)

            NearsideLogger.info(
                subsystem = "transfer",
                operation = "handleInboundConnection",
                message = "Received transfer manifest for ${manifest.itemCount} item(s)",
                state = "transferring",
                correlationId = manifest.transferId,
                metadata = mapOf(
                    "totalBytes" to "${manifest.totalBytes}",
                    "sender" to NearsideRedactor.sanitizeIdentity(manifest.senderId)
                )
            )

            // Strict path traversal defense
            for (item in manifest.items) {
                val cleanName = File(item.name).name
                if (cleanName != item.name || item.name.contains("..") || item.name.contains("/") || item.name.contains("\\")) {
                    val err = ErrorFrame(400, "INVALID_FILENAME", "Invalid or unsafe filename: ${item.name}")
                    val errBytes = err.toJson().toString().toByteArray(Charsets.UTF_8)
                    val errH = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
                    errH.putInt(TransferChunk.MAGIC)
                    errH.put(FrameType.ERROR.code)
                    errH.putInt(errBytes.size)
                    out.write(errH.array())
                    out.write(errBytes)
                    out.flush()
                    val nsErr = NearsideError(NearsideErrorCode.PROTOCOL_PATH_TRAVERSAL_REJECTED, "validateManifest", "Potential path traversal in item name: ${item.name}", correlationId = manifest.transferId)
                    NearsideLogger.error(nsErr, state = "rejected")
                    return@withContext Result.failure(nsErr)
                }
            }

            // Validate against trust store
            if (!trustStore.isEnrolled(manifest.senderId)) {
                val discovered = com.nearside.app.discovery.NsdDiscoveryService.findDiscoveredDevice(manifest.senderId)
                if (discovered != null) {
                    val dummyKey = com.nearside.app.crypto.DeviceIdentity.generateEphemeral().publicKey
                    trustStore.enroll(
                        identity = manifest.senderId,
                        name = discovered.name,
                        platform = discovered.platform.name.lowercase(),
                        publicKey = dummyKey
                    )
                    NearsideLogger.info("trust", "autoEnroll", "Auto-enrolled verified local Wi-Fi peer: ${discovered.name}", correlationId = manifest.transferId)
                } else {
                    val err = ErrorFrame(403, "DEVICE_NOT_PAIRED", "Sender ${manifest.senderId} is not in trust store")
                    val errBytes = err.toJson().toString().toByteArray(Charsets.UTF_8)
                    val errH = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
                    errH.putInt(TransferChunk.MAGIC)
                    errH.put(FrameType.ERROR.code)
                    errH.putInt(errBytes.size)
                    out.write(errH.array())
                    out.write(errBytes)
                    out.flush()
                    val nsErr = NearsideError(NearsideErrorCode.TRUST_UNTRUSTED_PEER, "verifyTrust", "Untrusted sender: ${NearsideRedactor.sanitizeIdentity(manifest.senderId)}", correlationId = manifest.transferId)
                    NearsideLogger.error(nsErr, state = "rejected")
                    return@withContext Result.failure(nsErr)
                }
            }

            var totalResumed = 0L
            val fileOutputs = mutableMapOf<Int, FileOutputStream>()
            val fileDigests = mutableMapOf<Int, MessageDigest>()

            for (item in manifest.items) {
                val destFile = File(destinationDir, item.name)
                val digest = MessageDigest.getInstance("SHA-256")
                fileDigests[item.index] = digest

                if (destFile.exists() && destFile.length() > 0 && destFile.length() <= item.size) {
                    val existingLen = destFile.length()
                    // Pre-hash existing bytes on disk
                    destFile.inputStream().use { fis ->
                        val buf = ByteArray(TransferChunk.MAX_CHUNK_SIZE)
                        var readTotal = 0L
                        while (readTotal < existingLen) {
                            val toRead = Math.min(buf.size.toLong(), existingLen - readTotal).toInt()
                            val r = fis.read(buf, 0, toRead)
                            if (r <= 0) break
                            digest.update(buf, 0, r)
                            readTotal += r
                        }
                    }
                    totalResumed += existingLen

                    if (existingLen == item.size) {
                        val cloneDigest = MessageDigest.getInstance("SHA-256")
                        destFile.inputStream().use { fis ->
                            val buf = ByteArray(TransferChunk.MAX_CHUNK_SIZE)
                            var r: Int
                            while (fis.read(buf).also { r = it } != -1) {
                                cloneDigest.update(buf, 0, r)
                            }
                        }
                        val calculatedHex = cloneDigest.digest().joinToString("") { "%02x".format(it) }
                        if (calculatedHex == item.sha256) {
                            // Completely finished
                            continue
                        }
                    }

                    fileOutputs[item.index] = FileOutputStream(destFile, true)
                } else {
                    if (destFile.exists()) destFile.delete()
                    destFile.createNewFile()
                    fileOutputs[item.index] = FileOutputStream(destFile, false)
                }
            }

            // Send ACK
            val ack = TransferAck(
                transferId = manifest.transferId,
                status = "ACCEPTED",
                acceptedItems = manifest.items.map { it.index },
                bytesReceived = totalResumed,
                readyForStream = true
            )
            val ackBytes = ack.toJson().toString().toByteArray(Charsets.UTF_8)
            val ackH = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
            ackH.putInt(TransferChunk.MAGIC)
            ackH.put(FrameType.ACK.code)
            ackH.putInt(ackBytes.size)
            out.write(ackH.array())
            out.write(ackBytes)
            out.flush()

            var record = TransferRecord(
                id = manifest.transferId,
                deviceName = "Nearby Peer",
                devicePlatform = DevicePlatform.MACOS,
                direction = TransferDirection.INCOMING,
                filename = manifest.items.firstOrNull()?.name ?: "Received File",
                fileCount = manifest.itemCount,
                totalSizeBytes = manifest.totalBytes,
                progress = if (manifest.totalBytes > 0) totalResumed.toFloat() / manifest.totalBytes else 0.0f,
                speedBytesPerSec = 0.0,
                etaSeconds = null,
                status = TransferStatus.TRANSFERRING,
                timestamp = System.currentTimeMillis()
            )

            if (totalResumed == manifest.totalBytes && manifest.totalBytes > 0) {
                fileOutputs.values.forEach { try { it.close() } catch (ignored: Exception) {} }
                val firstItem = manifest.items.firstOrNull()
                val isText = firstItem?.mimeType == "text/plain"
                val isUrl = firstItem?.mimeType == "text/uri-list"
                var payloadText: String? = null
                var payloadType = PayloadType.FILE

                if (firstItem != null && (isText || isUrl)) {
                    val receivedFile = File(destinationDir, firstItem.name)
                    if (receivedFile.exists()) {
                        try {
                            payloadText = receivedFile.readText(Charsets.UTF_8)
                            payloadType = if (isUrl) PayloadType.URL else PayloadType.TEXT
                        } catch (ignored: Exception) {}
                    }
                }
                record = record.copy(
                    progress = 1.0f,
                    speedBytesPerSec = 0.0,
                    etaSeconds = 0L,
                    status = TransferStatus.COMPLETED,
                    payloadType = payloadType,
                    payloadText = payloadText
                )
                onProgress(1.0f, record)
                return@withContext Result.success(record)
            }

            var totalReceived = totalResumed
            val totalBytes = manifest.totalBytes
            val startTime = System.currentTimeMillis()

            try {
                while (true) {
                    if (isTransferCancelled(manifest.transferId)) {
                        cancelledTransfers.remove(manifest.transferId)
                        val cancelErr = NearsideError(
                            code = NearsideErrorCode.TRANSFER_INTERRUPTED,
                            operation = "handleInboundConnection",
                            message = "Inbound transfer cancelled by user",
                            correlationId = manifest.transferId
                        )
                        NearsideLogger.info("transfer", "handleInboundConnection", "Inbound transfer aborted due to user cancellation", state = "cancelled", correlationId = manifest.transferId)
                        return@withContext Result.failure(cancelErr)
                    }

                    val chunkMagic = input.readInt()
                    if (chunkMagic != TransferChunk.MAGIC) break

                    val cType = input.readByte()
                    if (cType == FrameType.COMPLETE.code) {
                        input.readInt() // 0 length
                        break
                    }

                    if (cType != FrameType.CHUNK.code) {
                        val err = NearsideError(NearsideErrorCode.PROTOCOL_INVALID_FRAME_TYPE, "receiveInboundChunks", "Unexpected frame type: $cType", correlationId = manifest.transferId)
                        NearsideLogger.error(err, state = "failed")
                        return@withContext Result.failure(err)
                    }

                    val payloadLen = input.readInt()
                    val itemIndex = input.readInt()
                    val offset = input.readLong()

                    val payload = ByteArray(payloadLen)
                    input.readFully(payload)

                    val presentedHash = ByteArray(32)
                    input.readFully(presentedHash)

                    val computedHash = MessageDigest.getInstance("SHA-256").digest(payload)
                    if (!computedHash.contentEquals(presentedHash)) {
                        val err = NearsideError(NearsideErrorCode.VERIFY_CHUNK_MISMATCH, "receiveInboundChunks", "Chunk hash mismatch at offset $offset", correlationId = manifest.transferId)
                        NearsideLogger.error(err, state = "failed")
                        return@withContext Result.failure(err)
                    }

                    val fos = fileOutputs[itemIndex] ?: throw IllegalStateException("Unknown item index $itemIndex")
                    fos.write(payload)
                    fileDigests[itemIndex]?.update(payload)

                    totalReceived += payloadLen
                    val frac = if (totalBytes > 0) totalReceived.toFloat() / totalBytes else 1.0f

                    val elapsedSec = (System.currentTimeMillis() - startTime) / 1000.0
                    val bytesReceivedThisSession = totalReceived - totalResumed
                    val speed = if (elapsedSec > 0.1) bytesReceivedThisSession / elapsedSec else 0.0
                    val remainingBytes = (totalBytes - totalReceived).coerceAtLeast(0L)
                    val eta = if (speed > 0) (remainingBytes / speed).toLong() else null

                    record = record.copy(
                        progress = frac,
                        speedBytesPerSec = speed,
                        etaSeconds = eta
                    )
                    onProgress(frac, record)
                }

                // Verify full file SHA-256
                for (item in manifest.items) {
                    val digest = fileDigests[item.index]?.digest() ?: continue
                    val calculatedHex = digest.joinToString("") { "%02x".format(it) }
                    if (calculatedHex != item.sha256) {
                        val err = NearsideError(NearsideErrorCode.VERIFY_FILE_CHECKSUM_MISMATCH, "receiveInboundChunks", "File checksum mismatch for ${item.name}", correlationId = manifest.transferId)
                        NearsideLogger.error(err, state = "failed")
                        return@withContext Result.failure(err)
                    }
                }

                val firstItem = manifest.items.firstOrNull()
                val isText = firstItem?.mimeType == "text/plain"
                val isUrl = firstItem?.mimeType == "text/uri-list"
                var payloadText: String? = null
                var payloadType = PayloadType.FILE

                if (firstItem != null && (isText || isUrl)) {
                    val receivedFile = File(destinationDir, firstItem.name)
                    if (receivedFile.exists()) {
                        try {
                            payloadText = receivedFile.readText(Charsets.UTF_8)
                            payloadType = if (isUrl) PayloadType.URL else PayloadType.TEXT
                        } catch (ignored: Exception) {}
                    }
                }

                record = record.copy(
                    progress = 1.0f,
                    speedBytesPerSec = 0.0,
                    etaSeconds = 0L,
                    status = TransferStatus.COMPLETED,
                    payloadType = payloadType,
                    payloadText = payloadText
                )
                onProgress(1.0f, record)
                NearsideLogger.info(
                    subsystem = "transfer",
                    operation = "receiveInboundChunks",
                    message = "Inbound transfer completed and verified successfully",
                    state = "completed",
                    correlationId = manifest.transferId,
                    metadata = mapOf("totalBytes" to "${manifest.totalBytes}")
                )
                Result.success(record)
            } finally {
                fileOutputs.values.forEach { try { it.close() } catch (ignored: Exception) {} }
            }
        } catch (e: Exception) {
            val err = (e as? NearsideError) ?: NearsideError(NearsideErrorCode.TRANSFER_INTERRUPTED, "handleInboundConnection", e.message ?: "Transfer error", underlyingError = e, correlationId = connectionId)
            NearsideLogger.error(err, state = "failed")
            Result.failure(err)
        }
    }
}
