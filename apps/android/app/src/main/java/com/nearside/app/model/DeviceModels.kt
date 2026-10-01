package com.nearside.app.model

import java.util.UUID

enum class DevicePlatform(val displayName: String) {
    MACOS("macOS"),
    ANDROID("Android"),
    IOS("iOS"),
    WINDOWS("Windows"),
    LINUX("Linux")
}

enum class DeviceReachability {
    ONLINE,
    BUSY,
    UNREACHABLE
}

data class NearsideDevice(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val platform: DevicePlatform,
    val fingerprint: String,
    val ipAddress: String? = null,
    val port: Int? = null,
    val reachability: DeviceReachability = DeviceReachability.ONLINE,
    val lastSeenTimestamp: Long = System.currentTimeMillis()
) {
    val shortFingerprint: String
        get() = if (fingerprint.startsWith("ns1_") && fingerprint.length >= 12) {
            fingerprint.substring(4, 12)
        } else {
            fingerprint.take(8)
        }
}

enum class TransferDirection {
    INCOMING,
    OUTGOING
}

enum class TransferStatus {
    TRANSFERRING,
    COMPLETED,
    FAILED,
    CANCELLED
}

data class TransferRecord(
    val id: String = UUID.randomUUID().toString(),
    val deviceName: String,
    val devicePlatform: DevicePlatform,
    val direction: TransferDirection,
    val filename: String,
    val fileCount: Int = 1,
    val totalSizeBytes: Long,
    val progress: Float = 1.0f,
    val status: TransferStatus = TransferStatus.COMPLETED,
    val timestamp: Long = System.currentTimeMillis()
) {
    val formattedSize: String
        get() {
            val kb = totalSizeBytes / 1024.0
            val mb = kb / 1024.0
            val gb = mb / 1024.0
            return when {
                gb >= 1.0 -> String.format("%.1f GB", gb)
                mb >= 1.0 -> String.format("%.1f MB", mb)
                kb >= 1.0 -> String.format("%.1f KB", kb)
                else -> "$totalSizeBytes B"
            }
        }
}
