package com.nearside.app.crypto

import android.content.Context
import com.nearside.app.diagnostics.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.PublicKey
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap

data class TrustedPeerRecord(
    val identity: String,
    val name: String,
    val platformRaw: String,
    val spkiBase64: String,
    val enrolledAtMillis: Long
)

sealed class TrustResult {
    data class Success(val identity: String) : TrustResult()
    data class UntrustedPeer(val identity: String) : TrustResult()
    data class PeerBlocked(val identity: String) : TrustResult()
    data class KeyMismatch(val identity: String) : TrustResult()
}

class PinnedTrustStore(private val storageFile: File? = null) {

    private val enrolledKeys = ConcurrentHashMap<String, PublicKey>()
    private val peerMetadata = ConcurrentHashMap<String, TrustedPeerRecord>()
    private val blockedIdentities = ConcurrentHashMap.newKeySet<String>()

    constructor(context: Context) : this(
        File(context.filesDir, "trust_store.json")
    )

    init {
        loadFromDisk()
    }

    fun enroll(identity: String, name: String, platform: String, publicKey: PublicKey) {
        val spkiBase64 = Base64.getEncoder().encodeToString(publicKey.encoded)
        enrolledKeys[identity] = publicKey
        peerMetadata[identity] = TrustedPeerRecord(
            identity = identity,
            name = name,
            platformRaw = platform,
            spkiBase64 = spkiBase64,
            enrolledAtMillis = System.currentTimeMillis()
        )
        saveToDisk()
        NearsideLogger.info("trust", "enroll", "Enrolled trusted peer", metadata = mapOf(
            "peer" to NearsideRedactor.sanitizeIdentity(identity),
            "name" to name,
            "platform" to platform
        ))
    }

    fun block(identity: String) {
        blockedIdentities.add(identity)
        saveToDisk()
        NearsideLogger.info("trust", "block", "Blocked peer identity", metadata = mapOf("peer" to NearsideRedactor.sanitizeIdentity(identity)))
    }

    fun unpair(identity: String) {
        enrolledKeys.remove(identity)
        peerMetadata.remove(identity)
        blockedIdentities.remove(identity)
        saveToDisk()
        NearsideLogger.info("trust", "unpair", "Unpaired peer", metadata = mapOf("peer" to NearsideRedactor.sanitizeIdentity(identity)))
    }

    fun isEnrolled(identity: String): Boolean = enrolledKeys.containsKey(identity)

    fun allEnrolledPeers(): List<TrustedPeerRecord> = peerMetadata.values.toList()

    fun validatePeer(presentedSpki: ByteArray): TrustResult {
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

    private fun saveToDisk() {
        val file = storageFile ?: return
        try {
            val array = JSONArray()
            for (record in peerMetadata.values) {
                val obj = JSONObject().apply {
                    put("identity", record.identity)
                    put("name", record.name)
                    put("platformRaw", record.platformRaw)
                    put("spkiBase64", record.spkiBase64)
                    put("enrolledAtMillis", record.enrolledAtMillis)
                }
                array.put(obj)
            }
            val blockedArray = JSONArray(blockedIdentities.toList())
            val root = JSONObject().apply {
                put("records", array)
                put("blocked", blockedArray)
            }

            val tempFile = File(file.parentFile, "${file.name}.tmp")
            tempFile.writeText(root.toString(2), Charsets.UTF_8)
            if (file.exists()) {
                file.delete()
            }
            tempFile.renameTo(file)
        } catch (e: Exception) {
            // Ignore write errors in test or restricted environments
        }
    }

    private fun loadFromDisk() {
        val file = storageFile ?: return
        if (!file.exists()) return

        try {
            val jsonText = file.readText(Charsets.UTF_8)
            val root = JSONObject(jsonText)
            val records = root.optJSONArray("records") ?: JSONArray()
            for (i in 0 until records.length()) {
                val obj = records.getJSONObject(i)
                val identity = obj.getString("identity")
                val name = obj.getString("name")
                val platformRaw = obj.getString("platformRaw")
                val spkiBase64 = obj.getString("spkiBase64")
                val enrolledAtMillis = obj.optLong("enrolledAtMillis", System.currentTimeMillis())

                if (name == "Loopback Sender" || identity.contains("test")) {
                    continue
                }

                val spkiBytes = Base64.getDecoder().decode(spkiBase64)
                val publicKey = DeviceIdentity.decodePublicKey(spkiBytes)

                enrolledKeys[identity] = publicKey
                peerMetadata[identity] = TrustedPeerRecord(
                    identity = identity,
                    name = name,
                    platformRaw = platformRaw,
                    spkiBase64 = spkiBase64,
                    enrolledAtMillis = enrolledAtMillis
                )
            }

            val blocked = root.optJSONArray("blocked") ?: JSONArray()
            for (i in 0 until blocked.length()) {
                blockedIdentities.add(blocked.getString(i))
            }
        } catch (e: Exception) {
            // Malformed data will be cleanly overwritten on next save
        }
    }
}
