# Nearside Protocol Specification: Pairing & Trust Enrollment

Nearside establishes end-to-end authenticated trust relationships through out-of-band visual (QR code) or manual verification (short code).

## 1. Trust Model

- Each device generates a persistent NIST P-256 (secp256r1) keypair stored securely in hardware keystores (Apple Keychain / Android Keystore).
- Device identity is designated by the SubjectPublicKeyInfo (SPKI) SHA-256 hash prefix: `ns1_<hex_hash>`.
- Trust is explicit and persistent: once paired, peers retain public keys and trust anchors locally.

## 2. QR Code Pairing Flow

QR code pairing is asymmetric: one device displays a high-entropy session QR code, and the peer scans it using their camera.

```
Device A (Display QR)                      Device B (Scanner)
   |                                              |
   | Generates ephemeral secret R (256-bit)       |
   | Displays QR: nearside://pair?id=...&sec=...  |
   |                                              |
   |                                  Scans QR, extracts R
   |                                  Connects over TCP
   |<-------------- PairRequest ------------------|
   |  (Ephemeral public key B_eph, Fingerprint_B) |
   |                                              |
   | Computes Shared Secret & Auth Tag            |
   | Tag = HMAC-SHA256(R, EphemeralKeys || IDs)   |
   |---------------- PairResponse --------------->|
   |  (Ephemeral public key A_eph, AuthTag)       |
   |                                              |
   |                                  Verifies Auth Tag using R
   |<-------------- PairVerify -------------------|
   |  (ClientAuthTag = HMAC(R, "CLIENT" || ...))  |
   |                                              |
   | Verifies ClientAuthTag                       |
   | Saves Device B to Trust Store                |
   |---------------- PairComplete --------------->|
   |                                  Saves Device A to Trust Store
```

## 3. Short Code Pairing Flow (PAKE)

When visual scanning is inconvenient, an 8-digit numeric verification code is exchanged:

1. Both parties enter or confirm an 8-digit decimal code (26.5 bits of entropy).
2. Code is combined with device fingerprints and ephemeral ECDH keys via PBKDF2/HKDF.
3. Mutual confirmation tags prove key agreement without leaking the code over the wire.
4. Security constraint: Strict rate-limiting enforced (max 5 consecutive failures before 5-minute lockout) to prevent brute-force attacks.
