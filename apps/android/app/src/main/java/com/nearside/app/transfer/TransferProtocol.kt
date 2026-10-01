package com.nearside.app.transfer

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

data class TransferItemManifest(
    val index: Int,
    val name: String,
    val mimeType: String,
    val size: Long,
    val sha256: String
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("index", index)
        put("name", name)
        put("mime_type", mimeType)
        put("size", size)
        put("sha256", sha256)
    }

    companion object {
        fun fromJson(obj: JSONObject): TransferItemManifest = TransferItemManifest(
            index = obj.getInt("index"),
            name = obj.getString("name"),
            mimeType = obj.optString("mime_type", "application/octet-stream"),
            size = obj.getLong("size"),
            sha256 = obj.getString("sha256")
        )
    }
}

data class TransferManifest(
    val transferId: String,
    val senderId: String,
    val totalBytes: Long,
    val itemCount: Int,
    val items: List<TransferItemManifest>
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("transfer_id", transferId)
        put("sender_id", senderId)
        put("total_bytes", totalBytes)
        put("item_count", itemCount)
        val arr = JSONArray()
        items.forEach { arr.put(it.toJson()) }
        put("items", arr)
    }

    companion object {
        fun fromJson(obj: JSONObject): TransferManifest {
            val arr = obj.getJSONArray("items")
            val items = (0 until arr.length()).map {
                TransferItemManifest.fromJson(arr.getJSONObject(it))
            }
            return TransferManifest(
                transferId = obj.getString("transfer_id"),
                senderId = obj.getString("sender_id"),
                totalBytes = obj.getLong("total_bytes"),
                itemCount = obj.optInt("item_count", items.size),
                items = items
            )
        }
    }
}

data class TransferAck(
    val transferId: String,
    val status: String,
    val acceptedItems: List<Int>,
    val bytesReceived: Long,
    val readyForStream: Boolean
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("transfer_id", transferId)
        put("status", status)
        val arr = JSONArray()
        acceptedItems.forEach { arr.put(it) }
        put("accepted_items", arr)
        put("bytes_received", bytesReceived)
        put("ready_for_stream", readyForStream)
    }

    companion object {
        fun fromJson(obj: JSONObject): TransferAck {
            val arr = obj.optJSONArray("accepted_items") ?: JSONArray()
            val items = (0 until arr.length()).map { arr.getInt(it) }
            return TransferAck(
                transferId = obj.getString("transfer_id"),
                status = obj.getString("status"),
                acceptedItems = items,
                bytesReceived = obj.optLong("bytes_received", 0L),
                readyForStream = obj.optBoolean("ready_for_stream", true)
            )
        }
    }
}

data class ErrorFrame(
    val code: Int,
    val reason: String,
    val detail: String
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("code", code)
        put("reason", reason)
        put("detail", detail)
    }

    companion object {
        fun fromJson(obj: JSONObject): ErrorFrame = ErrorFrame(
            code = obj.getInt("code"),
            reason = obj.getString("reason"),
            detail = obj.getString("detail")
        )
    }
}

enum class FrameType(val code: Byte) {
    MANIFEST(0x01),
    ACK(0x02),
    CHUNK(0x03),
    ERROR(0x04),
    COMPLETE(0x05)
}

data class TransferChunk(
    val itemIndex: Int,
    val offset: Long,
    val data: ByteArray,
    val sha256Hex: String = run {
        val digest = MessageDigest.getInstance("SHA-256").digest(data)
        digest.joinToString("") { "%02x".format(it) }
    }
) {
    companion object {
        const val MAGIC: Int = 0x4E534644 // "NSFD" in ASCII
        const val MAX_CHUNK_SIZE: Int = 64 * 1024 // 64 KiB bounded chunk

        fun decode(streamData: ByteArray): Pair<TransferChunk, Int>? {
            if (streamData.size < 21 + 32) return null

            val buffer = ByteBuffer.wrap(streamData).order(ByteOrder.BIG_ENDIAN)
            val magic = buffer.int
            if (magic != MAGIC) return null

            val frameType = buffer.get()
            if (frameType != FrameType.CHUNK.code) return null

            val length = buffer.int
            if (length <= 0 || length > MAX_CHUNK_SIZE) return null

            val totalExpected = 21 + length + 32
            if (streamData.size < totalExpected) return null

            val itemIndex = buffer.int
            val offset = buffer.long

            val chunkPayload = ByteArray(length)
            buffer.get(chunkPayload)

            val presentedHash = ByteArray(32)
            buffer.get(presentedHash)

            val computedHash = MessageDigest.getInstance("SHA-256").digest(chunkPayload)
            if (!computedHash.contentEquals(presentedHash)) return null

            val chunk = TransferChunk(itemIndex, offset, chunkPayload)
            return Pair(chunk, totalExpected)
        }
    }

    fun encode(): ByteArray {
        val buffer = ByteBuffer.allocate(21 + data.size + 32).order(ByteOrder.BIG_ENDIAN)
        buffer.putInt(MAGIC)
        buffer.put(FrameType.CHUNK.code)
        buffer.putInt(data.size)
        buffer.putInt(itemIndex)
        buffer.putLong(offset)
        buffer.put(data)

        val hash = MessageDigest.getInstance("SHA-256").digest(data)
        buffer.put(hash)

        return buffer.array()
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as TransferChunk
        if (itemIndex != other.itemIndex) return false
        if (offset != other.offset) return false
        if (!data.contentEquals(other.data)) return false
        return true
    }

    override fun hashCode(): Int {
        var result = itemIndex
        result = 31 * result + offset.hashCode()
        result = 31 * result + data.contentHashCode()
        return result
    }
}
