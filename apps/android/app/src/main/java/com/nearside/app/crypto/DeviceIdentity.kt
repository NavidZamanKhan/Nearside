package com.nearside.app.crypto

import android.content.Context
import com.nearside.app.diagnostics.NearsideError
import com.nearside.app.diagnostics.NearsideErrorCode
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec

class DeviceIdentity(
    val privateKey: PrivateKey,
    val publicKey: PublicKey
) {
    val spkiDer: ByteArray = publicKey.encoded
    val publicIdentity: String = computeIdentity(spkiDer)

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val ALIAS_IDENTITY = "com.nearside.identity.p256"

        fun computeIdentity(spkiDer: ByteArray): String {
            val md = MessageDigest.getInstance("SHA-256")
            val digest = md.digest(spkiDer)
            val hex = digest.joinToString("") { "%02x".format(it) }
            return "ns1_$hex"
        }

        fun decodePublicKey(spkiDer: ByteArray): PublicKey {
            val keyFactory = KeyFactory.getInstance("EC")
            val keySpec = X509EncodedKeySpec(spkiDer)
            return keyFactory.generatePublic(keySpec)
        }

        fun generateEphemeral(): DeviceIdentity {
            val kpg = KeyPairGenerator.getInstance("EC")
            kpg.initialize(ECGenParameterSpec("secp256r1"))
            val pair = kpg.generateKeyPair()
            return DeviceIdentity(pair.private, pair.public)
        }

        @Synchronized fun loadOrCreateDefault(context: Context): DeviceIdentity {
            // Keep creation inside AndroidKeyStore; denied or failed key access must never
            // replace an enrolled identity with an unrelated ephemeral signing key.
            return loadPersistentIdentity(readKey = {
                val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE)
                keyStore.load(null)
                if (keyStore.containsAlias(ALIAS_IDENTITY)) {
                    val entry = keyStore.getEntry(ALIAS_IDENTITY, null) as? KeyStore.PrivateKeyEntry
                        ?: throw IllegalStateException("Stored device key is invalid")
                    DeviceIdentity(entry.privateKey, entry.certificate.publicKey)
                } else null
            }, createKey = {
                val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
                val spec = KeyGenParameterSpec.Builder(ALIAS_IDENTITY,
                    KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .build()
                kpg.initialize(spec)
                val pair = kpg.generateKeyPair()
                DeviceIdentity(pair.private, pair.public)
            })
        }

        internal fun loadPersistentIdentity(readKey: () -> DeviceIdentity?, createKey: () -> DeviceIdentity): DeviceIdentity {
            return try { readKey() ?: createKey() }
            catch (error: Exception) {
                throw NearsideError(NearsideErrorCode.TRUST_STORAGE_FAILED, "loadDeviceIdentity",
                    "Cannot access the persistent device identity. Unlock the device and restart Nearside.",
                    underlyingError = error)
            }
        }

        fun verify(signature: ByteArray, data: ByteArray, publicKey: PublicKey): Boolean {
            return try {
                val verifier = try {
                    Signature.getInstance("SHA256withECDSAinP1363Format")
                } catch (e: Exception) {
                    Signature.getInstance("SHA256withECDSA")
                }
                verifier.initVerify(publicKey)
                verifier.update(data)
                verifier.verify(signature)
            } catch (e: Exception) {
                false
            }
        }
    }

    fun sign(data: ByteArray): ByteArray {
        val signer = try {
            Signature.getInstance("SHA256withECDSAinP1363Format")
        } catch (e: Exception) {
            Signature.getInstance("SHA256withECDSA")
        }
        signer.initSign(privateKey)
        signer.update(data)
        return signer.sign()
    }
}
