# Nearside Diagnostic Retrofit Plan

This document establishes the architectural foundation and execution plan for retrofitting Nearside with a centralized, permanent diagnosability framework.

---

## 1. Existing Important Subsystems

Nearside consists of seven critical architectural subsystems across Apple (macOS/iOS) and Android:

1. **Discovery Subsystem**:
   - Apple: [`DiscoveryService.swift`](file:///Users/navidzamankhan/Code/Nearside/apps/apple/Shared/Discovery/DiscoveryService.swift) using `NWListener` (port 41433) and `NWBrowser` (`_nearside._tcp`).
   - Android: [`NsdDiscoveryService.kt`](file:///Users/navidzamankhan/Code/Nearside/apps/android/app/src/main/java/com/nearside/app/discovery/NsdDiscoveryService.kt) using Android `NsdManager` for registration, discovery, and DNS-SD resolution.
2. **Device Identity & Trust Subsystem**:
   - NIST P-256 SPKI key generation and `ns1_<hex>` SHA-256 fingerprinting ([`DeviceIdentity.swift`](file:///Users/navidzamankhan/Code/Nearside/apps/apple/Shared/Crypto/DeviceIdentity.swift) and [`DeviceIdentity.kt`](file:///Users/navidzamankhan/Code/Nearside/apps/android/app/src/main/java/com/nearside/app/crypto/DeviceIdentity.kt)).
   - Persistent pinned trust store ([`PinnedTrustStore.swift`](file:///Users/navidzamankhan/Code/Nearside/apps/apple/Shared/Crypto/PinnedTrustStore.swift) and [`PinnedTrustStore.kt`](file:///Users/navidzamankhan/Code/Nearside/apps/android/app/src/main/java/com/nearside/app/crypto/PinnedTrustStore.kt)).
3. **Pairing Protocols**:
   - Visual QR code pairing with ephemeral 32-byte secret and HKDF-SHA256 transcript verification ([`QRPairingProtocol.swift`](file:///Users/navidzamankhan/Code/Nearside/apps/apple/Shared/Crypto/QRPairingProtocol.swift) and [`QRPairingProtocol.kt`](file:///Users/navidzamankhan/Code/Nearside/apps/android/app/src/main/java/com/nearside/app/crypto/QRPairingProtocol.kt)).
   - 8-digit numeric PAKE key agreement with 5-attempt rate-limiting lockout ([`ShortCodePakeProtocol.swift`](file:///Users/navidzamankhan/Code/Nearside/apps/apple/Shared/Crypto/ShortCodePakeProtocol.swift) and [`ShortCodePakeProtocol.kt`](file:///Users/navidzamankhan/Code/Nearside/apps/android/app/src/main/java/com/nearside/app/crypto/ShortCodePakeProtocol.kt)).
4. **Transfer Engine & Stream Coordinator**:
   - Binary framed TCP transfer pipeline with 64 KiB bounded chunk streaming, manifest/ACK negotiation, and resume support ([`TransferEngine.swift`](file:///Users/navidzamankhan/Code/Nearside/apps/apple/Shared/Transfer/TransferEngine.swift) and [`TransferEngine.kt`](file:///Users/navidzamankhan/Code/Nearside/apps/android/app/src/main/java/com/nearside/app/transfer/TransferEngine.kt)).
5. **Receiver Service & Power Subsystem**:
   - Android foreground service [`NearsideReceiverService.kt`](file:///Users/navidzamankhan/Code/Nearside/apps/android/app/src/main/java/com/nearside/app/service/NearsideReceiverService.kt) managing `ServerSocket` (port 41433) and interactive notifications.
   - Reference-counted `PowerLockManager.kt` acquiring and releasing wake/wifi locks during active transfers.
6. **State & UI Coordinators**:
   - macOS / iOS [`AppState.swift`](file:///Users/navidzamankhan/Code/Nearside/apps/apple/Shared/AppState.swift) and Android [`AppViewModel.kt`](file:///Users/navidzamankhan/Code/Nearside/apps/android/app/src/main/java/com/nearside/app/state/AppViewModel.kt).
   - Menu bar shelf popover, Compose home activity, iOS home view, and Share extension controllers.
7. **Instant Content & Clipboard**:
   - Inbound and outbound zero-staging `text/plain` and `text/uri-list` payload pipeline.

---

## 2. Existing Failure Boundaries

1. **Discovery Boundaries**:
   - Listener port bind failure (`EADDRINUSE` / port collision).
   - mDNS service registration rejection by OS daemon.
   - Browser start failure or daemon crash.
   - Service name resolution failure (NsdManager error codes `FAILURE_ALREADY_ACTIVE`, `FAILURE_INTERNAL_ERROR`).
2. **Trust & Pairing Boundaries**:
   - Expired QR / PAKE session timestamps.
   - HMAC verification failure on pairing commitment.
   - PAKE rate limit exceeded (5 failed attempts).
   - Inbound transfer from untrusted or blocked peer (ErrorFrame 403).
3. **Transport & Connection Boundaries**:
   - TCP connect timeout (`ETIMEDOUT`).
   - Host unreachable / network interface down (`ENETUNREACH`).
   - Connection reset by peer mid-stream (`ECONNRESET`).
4. **Protocol & Framing Boundaries**:
   - Magic bytes mismatch (`MAGIC != 0x4E532020` or `0x4E53`).
   - Invalid frame type code.
   - Corrupted or unparseable JSON manifest / ACK payload.
   - Path traversal attempt (relative paths containing `..`, `/`, `\`).
5. **Transfer & Integrity Boundaries**:
   - Per-chunk SHA-256 hash mismatch.
   - Full file SHA-256 checksum mismatch after stream completion.
   - Unexpected socket EOF during chunk read.
6. **Storage Boundaries**:
   - Source file open/read permission failure.
   - Destination file creation or disk space exhaustion.

---

## 3. Existing State Machines

1. **Discovery State Machine**:
   - `idle` -> `starting` -> `advertising` / `browsing` -> `failed` / `stopped`.
2. **Pairing State Machine**:
   - QR: `created` -> `scanned` -> `deriving` -> `verifying` -> `enrolled` / `failed(expired | verification_failed | malformed)`.
   - PAKE: `initial` -> `committed` -> `exchanged` -> `verified` / `locked_out` / `failed`.
3. **Transfer State Machine**:
   - `idle` -> `connecting` -> `negotiating` -> `transferring` -> `verifying` -> `completed` / `failed` (with explicit error code, message, and retry count) / `cancelled`.
4. **Receiver Service State Machine**:
   - `stopped` -> `starting` -> `listening` -> `receiving` (locks held) -> `paused` / `stopped`.

---

## 4. Existing Errors and Exceptions

- **Apple**:
  - `TransferEngineError`: `.connectionFailed`, `.untrustedPeer`, `.manifestRejected`, `.integrityMismatch`, `.fileAccessError`, `.cancelled`.
  - `PairingError`: `.sessionExpired`, `.invalidSecret`, `.verificationFailed`, `.malformedPayload`.
  - `TrustError`: `.untrustedPeer`, `.peerBlocked`, `.keyMismatch`, `.invalidCertificate`.
  - `PakeError`: `.sessionExpired`, `.maxAttemptsExceeded`, `.tagMismatch`.
  - Native errors: `NWError`, `POSIXError`, `CocoaError`.
- **Android**:
  - `TrustResult`: `Success`, `UntrustedPeer`, `PeerBlocked`, `KeyMismatch`.
  - Native exceptions: `IOException`, `SocketTimeoutException`, `ConnectException`, `SecurityException`, `IllegalStateException`.

---

## 5. Operations Requiring Correlation IDs

1. `transferId`: Originates in `TransferManifest` (`tx_...`) and spans:
   - Outbound file preparation / manifest build.
   - Connection creation and state updates.
   - Manifest offer and receiver ACK negotiation.
   - Chunk streaming, offset progression, and retry attempts.
   - Final SHA-256 verification and record completion/failure.
2. `pairingSessionId`: Originates in QR payload (`sessionId` UUID) or PAKE session:
   - Spans payload generation, QR scanning, key derivation, and trust enrollment.
3. `connectionId`: Short identifier (`conn_...`) identifying a physical socket connection lifecycle before a manifest is bound.

---

## 6. Existing Logs Worth Preserving

- Android `NsdDiscoveryService.kt`: Service registration, discovery start/stop, service found/lost events.
- Probe verification outputs: Output statements validating probe harness passes.

---

## 7. Missing Diagnosability (Gaps Identified)

1. **No Canonical Error Codes**: Failures emit free-form strings (`"Cannot open file"`, `"Invalid magic in ACK"`) rather than stable machine-readable codes.
2. **Swallowed Exceptions**: In `NearsideReceiverService.kt`, socket accept failures and bind errors hit empty `catch` blocks. In `AppState.swift`, `.failure` ignores the error object.
3. **Loss of Native OS Error**: Wrapping strings replaces the underlying `NWError` / `POSIXError` / `SocketException`.
4. **Missing Retry Visibility**: Retries happen silently without logging attempt numbers, backoff delays, or exhaustion.
5. **No Structured Diagnostics in Records**: `TransferRecord` only tracks `status: .failed` without recording which subsystem or error code caused the failure.

---

## 8. Proposed Nearside Error-Code Namespaces

- `NS-DISC` (Discovery): `NS-DISC-001` (Registration failed), `NS-DISC-002` (Browser failed), `NS-DISC-003` (Resolve failed).
- `NS-PAIR` (Pairing): `NS-PAIR-001` (Session expired), `NS-PAIR-002` (Verification failed), `NS-PAIR-003` (Rate limit lockout), `NS-PAIR-004` (Malformed payload).
- `NS-TRUST` (Trust): `NS-TRUST-001` (Untrusted peer), `NS-TRUST-002` (Peer blocked), `NS-TRUST-003` (Key mismatch), `NS-TRUST-004` (Trust store failure).
- `NS-CONN` (Connection): `NS-CONN-001` (Timed out), `NS-CONN-002` (Refused / unreachable), `NS-CONN-003` (Closed / reset), `NS-CONN-004` (Bind failed).
- `NS-PROTO` (Protocol): `NS-PROTO-001` (Magic mismatch), `NS-PROTO-002` (Invalid frame type), `NS-PROTO-003` (Decode failed), `NS-PROTO-004` (Path traversal rejected).
- `NS-TRANSFER` (Transfer): `NS-TRANSFER-001` (Interrupted), `NS-TRANSFER-002` (Rejected), `NS-TRANSFER-003` (Retry exhausted), `NS-TRANSFER-004` (Cancelled).
- `NS-VERIFY` (Verification): `NS-VERIFY-001` (Chunk hash mismatch), `NS-VERIFY-002` (File checksum mismatch).
- `NS-STORAGE` (Storage): `NS-STORAGE-001` (Read error), `NS-STORAGE-002` (Write error).

---

## 9. Files and Modules Requiring Modification

- `apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift` (New shared Apple diagnostic model).
- `apps/android/app/src/main/java/com/nearside/app/diagnostics/NearsideDiagnostics.kt` (New shared Android diagnostic model).
- `apps/apple/Shared/DeviceModels.swift` and `apps/android/.../DeviceModels.kt` (Add diagnostic fields to `TransferRecord`).
- `apps/apple/Shared/Transfer/TransferEngine.swift` and `apps/android/.../TransferEngine.kt` (Structured logs, retry diagnostics, error codes).
- `apps/apple/Shared/Discovery/DiscoveryService.swift` and `apps/android/.../NsdDiscoveryService.kt` (Diagnostic logs and error code mapping).
- `apps/apple/Shared/Crypto/PinnedTrustStore.swift` and `apps/android/.../PinnedTrustStore.kt` (Trust diagnostics).
- `apps/apple/Shared/Crypto/QRPairingProtocol.swift` and `ShortCodePakeProtocol.swift` (Pairing diagnostics).
- `apps/android/app/src/main/java/com/nearside/app/service/NearsideReceiverService.kt` (Eliminate swallowed exceptions, log bind/accept states).
- `apps/apple/Shared/AppState.swift` and `apps/android/.../AppViewModel.kt` (Error propagation to active transfer and history).

---

## 10. Tests to Add

- Apple: `apps/apple/Tests/DiagnosticTests.swift` testing error code stability, native error preservation, redactor privacy sanitization, and transfer error propagation.
- Android: `apps/android/app/src/test/java/com/nearside/app/diagnostics/DiagnosticTest.kt` testing registry consistency, exception cause wrapping, and redaction.
- Verification Script: Update `scripts/verify_diagnostics.sh` and existing suites to ensure 100% test pass rate.
