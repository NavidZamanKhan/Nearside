package com.nearside.app.transfer

import com.nearside.app.crypto.PinnedTrustStore
import com.nearside.app.discovery.NsdDiscoveryService
import com.nearside.app.diagnostics.*
import com.nearside.app.model.DevicePlatform
import com.nearside.app.model.PayloadType
import com.nearside.app.model.TransferDirection
import com.nearside.app.model.TransferRecord
import com.nearside.app.model.TransferStatus
import com.nearside.app.model.NearsideDevice
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
    init {
        require(maxAttempts in 1..10)
        require(initialDelayMs in 0..30_000)
        require(multiplier.isFinite() && multiplier >= 1.0)
    }
    fun delayMs(attempt: Int): Long {
        if (attempt <= 0) return 0L
        return (initialDelayMs * Math.pow(multiplier, (attempt - 1).toDouble())).toLong().coerceAtMost(30_000L)
    }
}

internal data class PeerEndpoint(val host: String, val port: Int) {
    companion object {
        fun fromDiscovery(identity: String, device: NearsideDevice?): PeerEndpoint? {
            if (device == null || device.id != identity || device.fingerprint != identity) return null
            val host = device.ipAddress?.takeIf { it.isNotBlank() } ?: return null
            val port = device.port?.takeIf { it in 1..65535 } ?: return null
            return PeerEndpoint(host, port)
        }
    }
}

/** Discovery is an address hint for one identity; it never enrolls or changes a peer key. */
internal suspend fun <T> retryPeerEndpoint(
    initial: PeerEndpoint,
    policy: RetryPolicy,
    latest: () -> PeerEndpoint?,
    refresh: suspend () -> PeerEndpoint?,
    send: suspend (PeerEndpoint) -> Result<T>,
    onRetry: (Int, Exception) -> Unit = { _, _ -> },
    onSuccess: (PeerEndpoint) -> Unit = {},
    pause: suspend (Long) -> Unit = { delay(it) }
): Result<T> {
    var endpoint = latest() ?: initial
    var lastError: Exception? = null
    for (attempt in 1..policy.maxAttempts) {
        try {
            val result = send(endpoint)
            if (result.isSuccess) onSuccess(endpoint)
            // Protocol/trust rejection is terminal. Only native transport failures retry.
            return result
        } catch (error: java.io.IOException) {
            lastError = error
            if (attempt < policy.maxAttempts) {
                onRetry(attempt, error)
                endpoint = refresh() ?: latest() ?: endpoint
                pause(policy.delayMs(attempt))
            }
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (error: Exception) {
            return Result.failure(error)
        }
    }
    return Result.failure(lastError ?: java.io.IOException("Peer endpoint retries exhausted"))
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

    suspend fun initiatePairing(
        host: String,
        port: Int = 41433,
        confirmationCode: String = "",
        trustStore: PinnedTrustStore,
        qrPayload: com.nearside.app.crypto.QRPairingPayload? = null,
        deviceIdentity: com.nearside.app.crypto.DeviceIdentity? = null
    ): Result<PairResponseFrame> = withContext(Dispatchers.IO) {
        try {
            val payload = qrPayload ?: throw NearsideError(NearsideErrorCode.PAIRING_VERIFICATION_FAILED,
                "initiatePairing", "Scan or paste a current Nearside QR code to securely pair")
            if (payload.isExpired) throw NearsideError(NearsideErrorCode.PAIRING_SESSION_EXPIRED,
                "initiatePairing", "Pairing session expired", correlationId = payload.sessionId)
            Socket().use { socket ->
                socket.connect(java.net.InetSocketAddress(host, port), 5000)
                socket.soTimeout = 8000
                socket.tcpNoDelay = true
                val response = QRPairingTransport.client(DataInputStream(socket.getInputStream()),
                    DataOutputStream(socket.getOutputStream()),
                    deviceIdentity ?: throw NearsideError(NearsideErrorCode.PAIRING_VERIFICATION_FAILED, "pairQR", "Local device identity unavailable"), android.os.Build.MODEL,
                    payload, trustStore, host, port)
                NearsideLogger.info("pairing", "verifyQR", "Mutual QR pairing completed", state = "completed", correlationId = payload.sessionId)
                Result.success(response)
            }
        } catch (e: Exception) {
            val error = if (e is NearsideError) e else NearsideError(NearsideErrorCode.CONNECTION_REFUSED,
                "initiatePairing", "Pairing connection failed", underlyingError = e, correlationId = qrPayload?.sessionId)
            NearsideLogger.error(error, state = "failed")
            Result.failure(error)
        }
    }

    suspend fun sendText(
        text: String,
        isUrl: Boolean = false,
        host: String,
        port: Int = 41433,
        senderId: String,
        retryPolicy: RetryPolicy = RetryPolicy(),
        peerIdentity: String? = null,
        trustStore: PinnedTrustStore? = null,
        deviceIdentity: com.nearside.app.crypto.DeviceIdentity? = null,
        onProgress: (Float, Long, Long) -> Unit = { _, _, _ -> },
        onProgressMetrics: ((Float, Long, Long, Double, Long?) -> Unit)? = null
    ): Result<TransferManifest> = withContext(Dispatchers.IO) {
        val (manifest, tempFile) = buildTextManifest(text, isUrl, senderId)
        try {
            sendManifest(listOf(tempFile), manifest, host, port, senderId, retryPolicy,
                peerIdentity, trustStore, deviceIdentity, onProgress, onProgressMetrics)
        } finally {
            tempFile.delete()
        }
    }

    suspend fun sendFiles(
        files: List<File>,
        host: String,
        port: Int = 41433,
        senderId: String,
        retryPolicy: RetryPolicy = RetryPolicy(),
        peerIdentity: String? = null,
        trustStore: PinnedTrustStore? = null,
        deviceIdentity: com.nearside.app.crypto.DeviceIdentity? = null,
        onProgress: (Float, Long, Long) -> Unit = { _, _, _ -> },
        onProgressMetrics: ((Float, Long, Long, Double, Long?) -> Unit)? = null
    ): Result<TransferManifest> = withContext(Dispatchers.IO) {
        val manifest = buildManifest(files, senderId)
        sendManifest(files, manifest, host, port, senderId, retryPolicy,
            peerIdentity, trustStore, deviceIdentity, onProgress, onProgressMetrics)
    }

    private suspend fun sendManifest(
        files: List<File>,
        manifest: TransferManifest,
        host: String,
        port: Int,
        senderId: String,
        retryPolicy: RetryPolicy,
        peerIdentity: String?,
        trustStore: PinnedTrustStore?,
        deviceIdentity: com.nearside.app.crypto.DeviceIdentity?,
        onProgress: (Float, Long, Long) -> Unit,
        onProgressMetrics: ((Float, Long, Long, Double, Long?) -> Unit)?
    ): Result<TransferManifest> {
        if (peerIdentity == null || trustStore == null || deviceIdentity == null || deviceIdentity.publicIdentity != senderId) {
            return Result.failure(secureFailure("Persistent sender identity and paired recipient are required"))
        }
        if (!trustStore.canTransfer(peerIdentity)) {
            val code = if (trustStore?.isBlocked(peerIdentity) == true)
                NearsideErrorCode.TRUST_PEER_BLOCKED else NearsideErrorCode.TRUST_UNTRUSTED_PEER
            return Result.failure(NearsideError(code, "sendFiles", "Pair the selected peer before sending",
                correlationId = manifest.transferId))
        }
        val latest = {
            peerIdentity?.let { PeerEndpoint.fromDiscovery(it, NsdDiscoveryService.findDiscoveredDevice(it)) }
        }
        if (host.isBlank() && latest() == null) {
            return Result.failure(NearsideError(NearsideErrorCode.CONNECTION_REFUSED, "sendFiles",
                "Selected peer has no live endpoint", correlationId = manifest.transferId))
        }
        NearsideLogger.info("transfer", "sendFiles", "Starting outbound transfer with ${files.size} file(s)",
            state = "starting", correlationId = manifest.transferId,
            metadata = mapOf("totalBytes" to "${manifest.totalBytes}"))
        val result = retryPeerEndpoint(
            initial = PeerEndpoint(host, port),
            policy = retryPolicy,
            latest = latest,
            refresh = {
                peerIdentity?.let { PeerEndpoint.fromDiscovery(it, NsdDiscoveryService.refreshDiscoveredDevice(it)) }
            },
            send = { endpoint ->
                performSendAttempt(files, manifest, endpoint.host, endpoint.port, peerIdentity, trustStore, deviceIdentity, onProgress, onProgressMetrics)
            },
            onRetry = { attempt, error ->
                NearsideLogger.warn("connection", "refreshPeerEndpoint", "Refreshing selected peer endpoint before retry",
                    state = "retrying", correlationId = manifest.transferId, retryCount = attempt,
                    underlyingError = error)
            },
            onSuccess = { endpoint ->
                if (peerIdentity != null) trustStore?.updatePeerEndpoint(peerIdentity, endpoint.host, endpoint.port)
            }
        )
        val error = result.exceptionOrNull()
        if (error !is java.io.IOException) return result
        val finalError = NearsideError(NearsideErrorCode.TRANSFER_RETRY_EXHAUSTED, "sendFiles",
            "Outbound transfer exhausted all ${retryPolicy.maxAttempts} attempts", underlyingError = error,
            correlationId = manifest.transferId, retryCount = retryPolicy.maxAttempts)
        NearsideLogger.error(finalError, state = "failed")
        return Result.failure(finalError)
    }

    private fun performSendAttempt(
        files: List<File>,
        manifest: TransferManifest,
        host: String,
        port: Int,
        peerIdentity: String,
        trustStore: PinnedTrustStore,
        deviceIdentity: com.nearside.app.crypto.DeviceIdentity,
        onProgress: (Float, Long, Long) -> Unit,
        onProgressMetrics: ((Float, Long, Long, Double, Long?) -> Unit)? = null
    ): Result<TransferManifest> {
        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.soTimeout = 15000
            socket.connect(java.net.InetSocketAddress(host, port), 3000)
        } catch (error: Exception) {
            socket.close()
            throw error
        }
        socket.use {
            val channel = SecureTransferChannel.client(DataInputStream(socket.getInputStream()),
                DataOutputStream(socket.getOutputStream()), deviceIdentity, peerIdentity, trustStore)
            val out = channel.output
            val input = channel.input

            NearsideLogger.info(
                subsystem = "connection",
                operation = "performSendAttempt",
                message = "TCP socket connected to selected peer",
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
            if (ackLen !in 1..16384) throw secureFailure("Invalid acknowledgment size")
            val ackPayload = ByteArray(ackLen)
            input.readFully(ackPayload)

            val ackJson = JSONObject(String(ackPayload, Charsets.UTF_8))
            val ack = TransferAck.fromJson(ackJson)
            if (ack.transferId != manifest.transferId || ack.bytesReceived !in 0..manifest.totalBytes) {
                return Result.failure(secureFailure("Acknowledgment does not match transfer"))
            }
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

            if (input.readInt() != TransferChunk.MAGIC || input.readByte() != FrameType.ACK.code) {
                return Result.failure(secureFailure("Receiver completion acknowledgment required"))
            }
            val finalLength = input.readInt()
            if (finalLength !in 1..16384) throw secureFailure("Invalid completion acknowledgment size")
            val finalBytes = ByteArray(finalLength); input.readFully(finalBytes)
            val finalAck = TransferAck.fromJson(JSONObject(String(finalBytes, Charsets.UTF_8)))
            if (finalAck.transferId != manifest.transferId || finalAck.status != "COMPLETED" || finalAck.bytesReceived != manifest.totalBytes) {
                return Result.failure(secureFailure("Receiver did not verify transfer completion"))
            }

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
        onProgress: (Float, TransferRecord) -> Unit,
        deviceIdentity: com.nearside.app.crypto.DeviceIdentity? = null
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
            var input = DataInputStream(socket.getInputStream())
            var out = DataOutputStream(socket.getOutputStream())

            val magic = input.readInt()
            if (magic != TransferChunk.MAGIC) {
                val err = NearsideError(NearsideErrorCode.PROTOCOL_MAGIC_MISMATCH, "handleInboundConnection", "Invalid stream magic", correlationId = connectionId)
                NearsideLogger.error(err, state = "failed")
                return@withContext Result.failure(err)
            }
            val frameType = input.readByte()
            if (frameType == FrameType.PAIR_REQUEST.code) {
                val pairReq = PairRequestFrame.fromJson(QRPairingTransport.readPayload(input))
                QRPairingTransport.server(input, out, pairReq,
                    deviceIdentity ?: throw NearsideError(NearsideErrorCode.PAIRING_VERIFICATION_FAILED, "pairQR", "Local device identity unavailable"), android.os.Build.MODEL, trustStore)
                NearsideLogger.info("pairing", "verifyQR", "Mutual QR pairing completed", state = "completed", correlationId = pairReq.qrSessionId)
                socket.close()

                val record = TransferRecord(
                    deviceName = pairReq.clientName,
                    devicePlatform = DevicePlatform.MACOS,
                    direction = TransferDirection.INCOMING,
                    filename = "Pairing Handshake",
                    fileCount = 0,
                    totalSizeBytes = 0,
                    progress = 1.0f,
                    speedBytesPerSec = 0.0,
                    etaSeconds = null,
                    status = TransferStatus.COMPLETED
                )
                return@withContext Result.success(record)
            }
            if (frameType != SecureTransferChannel.CLIENT_HELLO || deviceIdentity == null) {
                return@withContext Result.failure(secureFailure("Authenticated encrypted transfer required"))
            }
            val channel = SecureTransferChannel.server(input, out, deviceIdentity, trustStore)
            input = channel.input
            out = channel.output
            if (input.readInt() != TransferChunk.MAGIC || input.readByte() != FrameType.MANIFEST.code) {
                return@withContext Result.failure(secureFailure("Expected authenticated manifest"))
            }

            val len = input.readInt()
            if (len !in 1..SecureTransferRecords.MAX_RECORD) throw secureFailure("Invalid manifest size")
            val manifestBytes = ByteArray(len)
            input.readFully(manifestBytes)

            val manifestObj = JSONObject(String(manifestBytes, Charsets.UTF_8))
            val manifest = TransferManifest.fromJson(manifestObj)
            if (manifest.senderId != channel.peerIdentity) throw secureFailure("Manifest sender differs from authenticated peer")
            if (manifest.itemCount != manifest.items.size || manifest.itemCount !in 1..1024 ||
                manifest.items.map { it.name }.distinct().size != manifest.itemCount) throw secureFailure("Invalid manifest item count")
            var declaredTotal = 0L
            for ((index, item) in manifest.items.withIndex()) {
                if (item.index != index || item.size < 0 || item.size > Long.MAX_VALUE - declaredTotal ||
                    !item.sha256.matches(Regex("[0-9a-f]{64}"))) throw secureFailure("Invalid manifest item")
                declaredTotal += item.size
            }
            if (declaredTotal != manifest.totalBytes) throw secureFailure("Invalid manifest total")

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

            // Discovery cannot grant trust or bypass a user block.
            if (!trustStore.canTransfer(manifest.senderId)) {
                val blocked = trustStore.isBlocked(manifest.senderId)
                val err = ErrorFrame(403, if (blocked) "DEVICE_BLOCKED" else "DEVICE_NOT_PAIRED", "Sender is not permitted")
                val errBytes = err.toJson().toString().toByteArray(Charsets.UTF_8)
                val errH = ByteBuffer.allocate(9).order(ByteOrder.BIG_ENDIAN)
                errH.putInt(TransferChunk.MAGIC)
                errH.put(FrameType.ERROR.code)
                errH.putInt(errBytes.size)
                out.write(errH.array())
                out.write(errBytes)
                out.flush()
                val nsErr = NearsideError(if (blocked) NearsideErrorCode.TRUST_PEER_BLOCKED else NearsideErrorCode.TRUST_UNTRUSTED_PEER,
                    "verifyTrust", "Sender is not permitted", correlationId = manifest.transferId)
                NearsideLogger.error(nsErr, state = "rejected")
                return@withContext Result.failure(nsErr)
            }

            var totalResumed = 0L
            val fileOutputs = mutableMapOf<Int, FileOutputStream>()
            val fileDigests = mutableMapOf<Int, MessageDigest>()

            val receivedOffsets = mutableMapOf<Int, Long>()
            var mayResumePrefix = true
            try {
                for (item in manifest.items) {
                    val destFile = File(destinationDir, item.name)
                    if (destFile.canonicalFile.parentFile != destinationDir.canonicalFile) throw secureFailure("Unsafe destination path")
                    var digest = MessageDigest.getInstance("SHA-256")
                    var resume = 0L
                    if (mayResumePrefix && destFile.isFile && destFile.length() in 1..item.size) {
                        val existingSize = destFile.length()
                        destFile.inputStream().use { inputFile ->
                            val buffer = ByteArray(TransferChunk.MAX_CHUNK_SIZE)
                            var count = 0L
                            while (count < existingSize) {
                                val size = inputFile.read(buffer, 0, minOf(buffer.size.toLong(), existingSize - count).toInt())
                                if (size <= 0) throw java.io.IOException("Resume file changed during read")
                                digest.update(buffer, 0, size); count += size
                            }
                        }
                        resume = existingSize
                        if (existingSize == item.size) {
                            val actual = MessageDigest.getInstance("SHA-256").digest(destFile.readBytes()).joinToString("") { "%02x".format(it) }
                            if (actual != item.sha256) { resume = 0; digest = MessageDigest.getInstance("SHA-256") }
                        }
                    }
                    fileOutputs[item.index] = FileOutputStream(destFile, resume > 0)
                    fileDigests[item.index] = digest
                    receivedOffsets[item.index] = resume
                    totalResumed += resume
                    mayResumePrefix = mayResumePrefix && resume == item.size
                }
            } catch (error: Exception) {
                fileOutputs.values.forEach { try { it.close() } catch (_: Exception) {} }
                throw error
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
                    if (chunkMagic != TransferChunk.MAGIC) throw secureFailure("Invalid encrypted chunk magic")

                    val cType = input.readByte()
                    if (cType == FrameType.COMPLETE.code) {
                        if (input.readInt() != 0) throw secureFailure("Invalid completion frame")
                        break
                    }

                    if (cType != FrameType.CHUNK.code) {
                        val err = NearsideError(NearsideErrorCode.PROTOCOL_INVALID_FRAME_TYPE, "receiveInboundChunks", "Unexpected frame type: $cType", correlationId = manifest.transferId)
                        NearsideLogger.error(err, state = "failed")
                        return@withContext Result.failure(err)
                    }

                    val payloadLen = input.readInt()
                    if (payloadLen !in 1..TransferChunk.MAX_CHUNK_SIZE) throw secureFailure("Invalid transfer chunk size")
                    val itemIndex = input.readInt()
                    val offset = input.readLong()
                    val item = manifest.items.getOrNull(itemIndex) ?: throw secureFailure("Unknown transfer item")
                    val expectedOffset = receivedOffsets[itemIndex] ?: throw secureFailure("Missing item offset")
                    if (offset != expectedOffset || payloadLen.toLong() > item.size - expectedOffset) throw secureFailure("Invalid transfer chunk offset")

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
                    fileDigests.getValue(itemIndex).update(payload)
                    receivedOffsets[itemIndex] = expectedOffset + payloadLen

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

                fileOutputs.values.forEach { it.close() }
                if (totalReceived != manifest.totalBytes) throw secureFailure("Incomplete transfer byte count")
                // Verify every on-disk size and digest before acknowledging completion.
                for (item in manifest.items) {
                    if (receivedOffsets[item.index] != item.size || File(destinationDir, item.name).length() != item.size) throw secureFailure("Incomplete transfer item")
                    val digest = fileDigests.getValue(item.index).digest()
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
                val completeAck = TransferAck(manifest.transferId, "COMPLETED", manifest.items.map { it.index }, manifest.totalBytes, false)
                val completeBytes = completeAck.toJson().toString().toByteArray(Charsets.UTF_8)
                out.writeInt(TransferChunk.MAGIC); out.writeByte(FrameType.ACK.code.toInt()); out.writeInt(completeBytes.size)
                out.write(completeBytes); out.flush()
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
