package com.nearside.app.crypto

import android.content.Context
import com.nearside.app.diagnostics.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.PublicKey
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class TrustedPeerRecord(
    val identity: String,
    val name: String,
    val platformRaw: String,
    val spkiBase64: String,
    val enrolledAtMillis: Long,
    var lastKnownIp: String? = null,
    var lastKnownPort: Int? = null
)

sealed class TrustResult {
    data class Success(val identity: String) : TrustResult()
    data class UntrustedPeer(val identity: String) : TrustResult()
    data class PeerBlocked(val identity: String) : TrustResult()
    data class KeyMismatch(val identity: String) : TrustResult()
}

class PinnedTrustStore(private val storageFile: File? = null) {
    companion object {
        private val sharedStores = mutableMapOf<String, PinnedTrustStore>()

        /** The UI and receiver must observe the same pins, blocks and enrollment. */
        fun fromContext(context: Context): PinnedTrustStore = sharedForFile(
            File(context.applicationContext.filesDir, "trust_store.json"))

        @Synchronized internal fun sharedForFile(file: File): PinnedTrustStore =
            sharedStores.getOrPut(file.canonicalPath) { PinnedTrustStore(file.canonicalFile) }
    }

    private var loadFailed = false
    private val enrolledKeys = ConcurrentHashMap<String, PublicKey>()
    private val peerMetadata = ConcurrentHashMap<String, TrustedPeerRecord>()
    private val blockedIdentities = ConcurrentHashMap.newKeySet<String>()
    private val revision = MutableStateFlow(0L)
    val changes = revision.asStateFlow()

    constructor(context: Context) : this(
        File(context.filesDir, "trust_store.json")
    )

    init {
        loadFromDisk()
    }

    fun enroll(
        identity: String, name: String, platform: String, publicKey: PublicKey,
        lastKnownIp: String? = null, lastKnownPort: Int? = null
    ) {
        try { enrollVerifiedPeer(identity, name, platform, publicKey, lastKnownIp, lastKnownPort) }
        catch (error: NearsideError) { NearsideLogger.error(error, state = "failed") }
    }

    /** QR pairing succeeds only after a validated pin is durably stored. */
    @Synchronized fun enrollVerifiedPeer(
        identity: String, name: String, platform: String, publicKey: PublicKey,
        lastKnownIp: String? = null, lastKnownPort: Int? = null
    ) {
        if (DeviceIdentity.computeIdentity(publicKey.encoded) != identity) {
            throw NearsideError(NearsideErrorCode.TRUST_KEY_MISMATCH, "enrollVerifiedPeer", "Peer identity does not match its public key")
        }
        val previousKey = enrolledKeys[identity]
        val previousRecord = peerMetadata[identity]
        enrolledKeys[identity] = publicKey
        peerMetadata[identity] = TrustedPeerRecord(identity, name, platform,
            Base64.getEncoder().encodeToString(publicKey.encoded), System.currentTimeMillis(), lastKnownIp, lastKnownPort)
        try { saveToDisk() }
        catch (error: NearsideError) {
            if (previousKey == null) enrolledKeys.remove(identity) else enrolledKeys[identity] = previousKey
            if (previousRecord == null) peerMetadata.remove(identity) else peerMetadata[identity] = previousRecord
            throw error
        }
        revision.value += 1
        NearsideLogger.info("trust", "enroll", "Enrolled trusted peer", metadata = mapOf(
            "peer" to NearsideRedactor.sanitizeIdentity(identity), "platform" to platform
        ))
    }

    @Synchronized fun updatePeerEndpoint(identity: String, ip: String?, port: Int?) {
        val previous = peerMetadata[identity] ?: return
        val record = previous.copy()
        var changed = false
        if (!ip.isNullOrBlank() && record.lastKnownIp != ip) {
            record.lastKnownIp = ip
            changed = true
        }
        if (port != null && port in 1..65535 && record.lastKnownPort != port) {
            record.lastKnownPort = port
            changed = true
        }
        if (changed) {
            peerMetadata[identity] = record
            try { saveToDisk() }
            catch (error: NearsideError) {
                peerMetadata[identity] = previous
                NearsideLogger.error(error, state = "failed")
                return
            }
            revision.value += 1
        }
    }

    @Synchronized fun block(identity: String) {
        blockedIdentities.add(identity)
        try { saveToDisk() }
        catch (error: NearsideError) { NearsideLogger.error(error, state = "failed") }
        revision.value += 1
        NearsideLogger.info("trust", "block", "Blocked peer identity", metadata = mapOf("peer" to NearsideRedactor.sanitizeIdentity(identity)))
    }

    @Synchronized fun unpair(identity: String) {
        enrolledKeys.remove(identity)
        peerMetadata.remove(identity)
        blockedIdentities.remove(identity)
        try { saveToDisk() }
        catch (error: NearsideError) { NearsideLogger.error(error, state = "failed") }
        revision.value += 1
        NearsideLogger.info("trust", "unpair", "Unpaired peer", metadata = mapOf("peer" to NearsideRedactor.sanitizeIdentity(identity)))
    }

    @Synchronized fun isEnrolled(identity: String): Boolean = enrolledKeys.containsKey(identity)

    @Synchronized fun isBlocked(identity: String): Boolean = blockedIdentities.contains(identity)

    @Synchronized fun canTransfer(identity: String): Boolean = !loadFailed && isEnrolled(identity) && !isBlocked(identity)

    @Synchronized fun allEnrolledPeers(): List<TrustedPeerRecord> = peerMetadata.values.map { it.copy() }

    @Synchronized fun validatePeer(presentedSpki: ByteArray): TrustResult {
        val identity = DeviceIdentity.computeIdentity(presentedSpki)

        if (blockedIdentities.contains(identity)) {
            NearsideLogger.warn("trust", "validatePeer", "Blocked peer attempted access", metadata = mapOf(
                "peer" to NearsideRedactor.sanitizeIdentity(identity),
                "code" to NearsideErrorCode.TRUST_PEER_BLOCKED.code
            ))
            return TrustResult.PeerBlocked(identity)
        }

        val enrolledKey = enrolledKeys[identity]
            ?: run {
                NearsideLogger.warn("trust", "validatePeer", "Untrusted peer attempted access", metadata = mapOf(
                    "peer" to NearsideRedactor.sanitizeIdentity(identity),
                    "code" to NearsideErrorCode.TRUST_UNTRUSTED_PEER.code
                ))
                return TrustResult.UntrustedPeer(identity)
            }

        if (!enrolledKey.encoded.contentEquals(presentedSpki)) {
            val err = NearsideError(
                NearsideErrorCode.TRUST_KEY_MISMATCH,
                "validatePeer",
                "Presented SPKI does not match pinned SPKI for peer ${NearsideRedactor.sanitizeIdentity(identity)}"
            )
            NearsideLogger.error(err, state = "failed")
            return TrustResult.KeyMismatch(identity)
        }

        return TrustResult.Success(identity)
    }

    @Synchronized private fun saveToDisk() {
        val file = storageFile ?: return
        if (loadFailed) throw NearsideError(NearsideErrorCode.TRUST_STORAGE_FAILED, "saveTrustStore",
            "Trust storage could not be read. Existing data was preserved; restore it before pairing")
        val tempFile = File(file.parentFile, "${file.name}.${UUID.randomUUID()}.tmp")
        try {
            val array = JSONArray()
            for (record in peerMetadata.values) {
                array.put(JSONObject().apply {
                    put("identity", record.identity); put("name", record.name); put("platformRaw", record.platformRaw)
                    put("spkiBase64", record.spkiBase64); put("enrolledAtMillis", record.enrolledAtMillis)
                    record.lastKnownIp?.let { put("lastKnownIp", it) }
                    record.lastKnownPort?.let { put("lastKnownPort", it) }
                })
            }
            val root = JSONObject().apply {
                put("records", array); put("blocked", JSONArray(blockedIdentities.toList()))
            }
            FileOutputStream(tempFile).use { output ->
                output.write(root.toString().toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
            // Same-directory atomic replacement never deletes the old store first.
            Files.move(tempFile.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (error: Exception) {
            throw storageFailure("saveTrustStore", error)
        } finally { tempFile.delete() }
    }

    @Synchronized private fun loadFromDisk() {
        val file = storageFile ?: return
        if (!file.exists()) return
        try {
            val root = JSONObject(file.readText(Charsets.UTF_8))
            val records = root.getJSONArray("records")
            val blocked = if (root.has("blocked")) root.getJSONArray("blocked") else JSONArray()
            val keys = mutableMapOf<String, PublicKey>()
            val metadata = mutableMapOf<String, TrustedPeerRecord>()
            val blocks = mutableSetOf<String>()
            for (i in 0 until records.length()) {
                val obj = records.getJSONObject(i)
                val identity = obj.getString("identity")
                val spkiBase64 = obj.getString("spkiBase64")
                val spki = Base64.getDecoder().decode(spkiBase64)
                val publicKey = DeviceIdentity.decodePublicKey(spki)
                if (DeviceIdentity.computeIdentity(spki) != identity || keys.containsKey(identity)) {
                    throw NearsideError(NearsideErrorCode.TRUST_STORAGE_FAILED, "loadTrustStore",
                        "Trust storage contains an invalid peer record. Existing data was preserved")
                }
                keys[identity] = publicKey
                metadata[identity] = TrustedPeerRecord(identity, obj.getString("name"), obj.getString("platformRaw"),
                    spkiBase64, obj.getLong("enrolledAtMillis"),
                    if (obj.has("lastKnownIp")) obj.getString("lastKnownIp").takeIf { it.isNotEmpty() } else null,
                    if (obj.has("lastKnownPort")) obj.getInt("lastKnownPort").takeIf { it in 1..65535 } else null)
            }
            for (i in 0 until blocked.length()) blocks.add(blocked.getString(i))
            enrolledKeys.putAll(keys)
            peerMetadata.putAll(metadata)
            blockedIdentities.addAll(blocks)
        } catch (error: Exception) {
            loadFailed = true
            NearsideLogger.error((error as? NearsideError) ?: storageFailure("loadTrustStore", error), state = "failed")
        }
    }

    private fun storageFailure(operation: String, error: Exception): NearsideError {
        // Native type/classification is useful; native messages may contain a
        // private path, JSON payload or key data and must not enter diagnostics.
        val nativeErrno = generateSequence<Throwable>(error) { it.cause }
            .filterIsInstance<android.system.ErrnoException>().firstOrNull()?.errno
        val classification = error.javaClass.name + (nativeErrno?.let { " errno=$it" } ?: "")
        return NearsideError(NearsideErrorCode.TRUST_STORAGE_FAILED, operation,
            "Trust storage is unavailable. Check local storage access and retry; existing data was preserved",
            underlyingError = Exception(classification))
    }
}
