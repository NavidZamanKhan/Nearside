# Nearside Protocol Specification: Security Architecture

This document describes the cryptographic primitives, threat model, and security boundaries.

## 1. Cryptographic Primitives

- **Asymmetric Identity**: NIST P-256 (secp256r1) keypairs.
- **Key Exchange**: Ephemeral ECDH (NIST P-256) combined with out-of-band commitment secret (HKDF-SHA256).
- **Symmetric Encryption**: AES-256-GCM or ChaCha20-Poly1305 with unique nonces per message.
- **Integrity Checksums**: SHA-256 per complete file; CRC32 or Blake3 per transmission chunk.
- **Key Derivation**: HKDF-SHA256 with domain separation labels ("nearside-pairing-v1", "nearside-transfer-v1").

## 2. Threat Model

### 2.1 Passive Wiretapping
Local Wi-Fi or LAN eavesdroppers cannot read transferred data or pairing verification codes because all traffic is encrypted end-to-end.

### 2.2 Active Man-in-the-Middle (MITM)
- QR pairing uses high-entropy session secrets not present on the wire.
- Short-code pairing binds ephemeral public keys to the entered verification code. Any modification in transit causes auth tag verification to fail immediately.

### 2.3 Brute Force on Verification Codes
Short codes (8 digits) are protected by strict rate limiting:
- Maximum 5 failed attempts per peer address.
- 5-minute exponential backoff upon repeated failures.

### 2.4 Device Impersonation
Peer identities are pinned by public key fingerprint in the local Trust Store. Changes in public key require explicit re-pairing authorization from the user.
