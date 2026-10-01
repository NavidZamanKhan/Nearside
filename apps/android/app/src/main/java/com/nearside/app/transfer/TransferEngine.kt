package com.nearside.app.transfer

import com.nearside.app.crypto.PinnedTrustStore
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.TransferDirection
import com.nearside.app.model.TransferRecord
import com.nearside.app.model.TransferStatus
import kotlinx.coroutines.Dispatchers
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

object TransferEngine {

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
            TransferItemManifest(
                index = index,
                name = file.name,
                mimeType = "application/octet-stream",
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

    suspend fun sendFiles(
        files: List<File>,
        host: String,
        port: Int,
        senderId: String,
        onProgress: (Float, Long, Long) -> Unit
    ): Result<TransferManifest> = withContext(Dispatchers.IO) {
        try {
            val manifest = buildManifest(files, senderId)
            Socket(host, port).use { socket ->
                socket.tcpNoDelay = true
                socket.soTimeout = 15000
                val out = DataOutputStream(socket.getOutputStream())
                val input = DataInputStream(socket.getInputStream())

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
                    return@withContext Result.failure(IllegalStateException("Invalid magic in ACK"))
                }
                val ackType = input.readByte()
                if (ackType != FrameType.ACK.code) {
                    return@withContext Result.failure(IllegalStateException("Unexpected response type $ackType"))
                }
                val ackLen = input.readInt()
                val ackPayload = ByteArray(ackLen)
                input.readFully(ackPayload)

                val ackJson = JSONObject(String(ackPayload, Charsets.UTF_8))
                val ack = TransferAck.fromJson(ackJson)
                if (ack.status != "ACCEPTED") {
                    return@withContext Result.failure(IllegalStateException("Transfer rejected: ${ack.status}"))
                }

                // Stream chunks
                var totalTransferred = 0L
                val totalBytes = manifest.totalBytes
                val chunkBuffer = ByteArray(TransferChunk.MAX_CHUNK_SIZE)

                for ((index, file) in files.withIndex()) {
                    var fileOffset = 0L
                    FileInputStream(file).use { fis ->
                        var read: Int
                        while (fis.read(chunkBuffer).also { read = it } != -1) {
                            val chunkData = chunkBuffer.copyOf(read)
                            val chunk = TransferChunk(index, fileOffset, chunkData)
                            out.write(chunk.encode())
                            out.flush()

                            fileOffset += read
                            totalTransferred += read
                            val fraction = if (totalBytes > 0) totalTransferred.toFloat() / totalBytes else 1.0f
                            onProgress(fraction, totalTransferred, totalBytes)
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
                Result.success(manifest)
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun handleInboundConnection(
        socket: Socket,
        trustStore: PinnedTrustStore,
        destinationDir: File,
        onProgress: (Float, TransferRecord) -> Unit
    ): Result<TransferRecord> = withContext(Dispatchers.IO) {
        try {
            socket.tcpNoDelay = true
            socket.soTimeout = 15000
            val input = DataInputStream(socket.getInputStream())
            val out = DataOutputStream(socket.getOutputStream())

            val magic = input.readInt()
            if (magic != TransferChunk.MAGIC) {
                return@withContext Result.failure(IllegalStateException("Invalid stream magic"))
            }
            val frameType = input.readByte()
            if (frameType != FrameType.MANIFEST.code) {
                return@withContext Result.failure(IllegalStateException("Expected manifest frame, got $frameType"))
            }

            val len = input.readInt()
            val manifestBytes = ByteArray(len)
            input.readFully(manifestBytes)

            val manifestObj = JSONObject(String(manifestBytes, Charsets.UTF_8))
            val manifest = TransferManifest.fromJson(manifestObj)

            // Validate against trust store
            if (!trustStore.isEnrolled(manifest.senderId)) {
                val err = ErrorFrame(403, "DEVICE_NOT_PAIRED", "Sender ${manifest.senderId} is not in trust store")
                val errBytes = err.toJson().toString().toByteArray(Charsets.UTF_8)
                val errH = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
                errH.putInt(TransferChunk.MAGIC)
                errH.put(FrameType.ERROR.code)
                errH.putInt(errBytes.size)
                out.write(errH.array())
                out.write(errBytes)
                out.flush()
                return@withContext Result.failure(SecurityException("Untrusted sender: ${manifest.senderId}"))
            }

            // Send ACK
            val ack = TransferAck(
                transferId = manifest.transferId,
                status = "ACCEPTED",
                acceptedItems = manifest.items.map { it.index },
                bytesReceived = 0L,
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
                progress = 0.0f,
                status = TransferStatus.TRANSFERRING,
                timestamp = System.currentTimeMillis()
            )

            // Receive chunks
            val fileOutputs = mutableMapOf<Int, FileOutputStream>()
            val fileDigests = mutableMapOf<Int, MessageDigest>()
            for (item in manifest.items) {
                val destFile = File(destinationDir, item.name)
                fileOutputs[item.index] = FileOutputStream(destFile)
                fileDigests[item.index] = MessageDigest.getInstance("SHA-256")
            }

            var totalReceived = 0L
            val totalBytes = manifest.totalBytes

            try {
                while (true) {
                    val chunkMagic = input.readInt()
                    if (chunkMagic != TransferChunk.MAGIC) break

                    val cType = input.readByte()
                    if (cType == FrameType.COMPLETE.code) {
                        input.readInt() // 0 length
                        break
                    }

                    if (cType != FrameType.CHUNK.code) {
                        return@withContext Result.failure(IllegalStateException("Unexpected frame type: $cType"))
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
                        return@withContext Result.failure(SecurityException("Chunk hash mismatch"))
                    }

                    val fos = fileOutputs[itemIndex] ?: throw IllegalStateException("Unknown item index $itemIndex")
                    fos.write(payload)
                    fileDigests[itemIndex]?.update(payload)

                    totalReceived += payloadLen
                    val frac = if (totalBytes > 0) totalReceived.toFloat() / totalBytes else 1.0f
                    record = record.copy(progress = frac)
                    onProgress(frac, record)
                }

                // Verify full file SHA-256
                for (item in manifest.items) {
                    val digest = fileDigests[item.index]?.digest() ?: continue
                    val calculatedHex = digest.joinToString("") { "%02x".format(it) }
                    if (calculatedHex != item.sha256) {
                        return@withContext Result.failure(SecurityException("File checksum mismatch for ${item.name}"))
                    }
                }

                record = record.copy(progress = 1.0f, status = TransferStatus.COMPLETED)
                onProgress(1.0f, record)
                Result.success(record)
            } finally {
                fileOutputs.values.forEach { try { it.close() } catch (ignored: Exception) {} }
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
