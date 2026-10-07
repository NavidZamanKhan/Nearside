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
