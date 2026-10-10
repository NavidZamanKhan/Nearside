# Pairing & Trust Diagnostics

## 1. Overview

Nearside uses mutual public-key cryptographic trust pinning:
- Identity: NIST P-256 SPKI key pairs (`ns1_<sha256_prefix>`).
- QR Pairing: Visual QR code transferring ephemeral session ID and 32-byte secret, verified via HKDF-SHA256 and constant-time HMAC-SHA256.
- Short Code Pairing: 8-digit numeric PAKE key agreement with 5-attempt rate-limiting lockout.
- Pinned Trust Store: Permanent local storage of enrolled peer public keys.

## 2. Relevant Error Codes

- `NS-PAIR-001`: Pairing session expired (validity window: 180 seconds).
- `NS-PAIR-002`: Cryptographic HMAC commitment verification failed.
- `NS-PAIR-003`: PAKE rate limit exceeded (lockout triggered after 5 failed attempts).
- `NS-PAIR-004`: Malformed pairing URI or JSON payload.
- `NS-TRUST-001`: Inbound transfer from untrusted (unpaired) peer.
- `NS-TRUST-002`: Blocked peer attempted connection.
- `NS-TRUST-003`: Peer presented public key differing from pinned SPKI key.
- `NS-TRUST-004`: Pinned trust store disk write or load failure.

## 3. Correlation ID

- `pairingSessionId`: UUID generated during QR creation or PAKE initiation. Links the session creation, payload generation, peer scan, derivation, and enrollment logs.

## 4. Privacy Guidelines

- Never log the 32-byte shared secret, raw PAKE pin, or private key material.
- Only log truncated fingerprints (`ns1_8b31...029`) via `NearsideRedactor.sanitizeIdentity`.

## 5. Android QR scanning and authenticated enrollment

The Android pairing dialog offers **Scan QR**, **Show mine**, and manual URI entry. Camera permission is requested only when the scan view is opened. A denial leaves retry, app-settings, and manual URI recovery available. CameraX binds preview and analysis to the foreground lifecycle; leaving the scan tab, capturing a valid QR, or dismissing the dialog closes its camera use cases. Decode failures for ordinary camera frames are silent; repeated invalid QR frames are suppressed.

QR URIs carry `created` and `ttl` in addition to version, session UUID, host identity, and the 32-byte secret. Parsing rejects duplicate/missing fields, unsupported versions, malformed identities/secrets, invalid ports, non-finite timestamps, and lifetimes above 180 seconds. Scanning preserves the host's original expiry instead of issuing a fresh lifetime. Codes produced by older builds without timestamps must be regenerated using the updated host.

Enrollment uses the existing QR HKDF/HMAC transcript over the session UUID, both identities, and fresh client/server nonces. A `CHALLENGE` response proves the host secret and binds its SPKI digest to the scanned fingerprint. The client confirmation is then verified before the host atomically consumes the in-memory displayed session and enrolls the client. The final `ACCEPTED` proof is checked before client enrollment. Session removal on dialog dismissal, expiry, or success prevents reuse. Blocked peers and pinned key mismatches remain rejected. Pairing frames are capped at 16 KiB.

Failures reuse `NS-PAIR-001` (expired, dismissed, or consumed session), `NS-PAIR-002` (proof mismatch or unauthenticated legacy pairing), `NS-PAIR-004` (malformed QR/frame), and `NS-TRUST-002` / `NS-TRUST-003` (blocked identity / key mismatch). Logs use `pairingSessionId` as `correlationId` and never include the URI, QR secret, nonce/proof bytes, or public-key payload. Camera startup reports a safe native cause without recording image data.

The previously unauthenticated direct-IP/empty-code and short-code network enrollment paths now fail closed with instructions to scan or paste a current QR. Short-code cryptographic utilities remain present, but no verified network PAKE exchange was implemented in the existing application. A plain IP or short code must never establish trust through that old shortcut.

Manual device verification: on the updated Mac, open Preferences → Pair New Device and display its QR; on Android choose Scan QR, grant permission, capture, and verify. Confirm both trust lists update only after verification. Deny camera access, retry from app settings, background/foreground the scan view, switch tabs, scan a non-Nearside QR, scan an expired/dismissed code, and attempt to reuse a successfully consumed code. Repeat with Android displaying its QR and the Mac pasting the current full pairing URI.
