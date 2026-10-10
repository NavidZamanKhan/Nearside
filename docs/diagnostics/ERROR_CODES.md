# Nearside Error Code Registry

This document is the authoritative registry of all Nearside error codes.

Format: `NS-[SUBSYSTEM]-[NUMBER]`

### Error Code Policies
- **Stable Identity**: Once assigned, a code's semantic meaning is permanently fixed.
- **Never Recycled**: Retired codes are marked `[DEPRECATED]` and never reassigned to new meanings.
- **Cross-Platform Consistency**: The same semantic failure on macOS, iOS, or Android shares the identical Nearside error code, while preserving platform-specific underlying causes.
- **Privacy Assurance**: Diagnostic logs containing error codes must never log private keys, passwords, clipboard text, or authentication secrets.

---

## 1. Discovery Subsystem (`NS-DISC`)

| Error Code | Semantic Name | Meaning | Common Underlying Causes | Investigation Steps |
|---|---|---|---|---|
| `NS-DISC-001` | `discoveryRegistrationFailed` | Failed to register mDNS / DNS-SD service announcement. | Port 41433 already in use, local network permission denied, mDNSResponder crash. | Check if another Nearside instance is running. Check macOS/iOS Local Network permission. Check console for `EADDRINUSE`. |
| `NS-DISC-002` | `discoveryBrowserFailed` | Peer discovery scanner / browser failed to start or died. | Local network permission denied, network interface offline, mDNS daemon failure. | Ensure device is connected to a local Wi-Fi or Ethernet network with multicast enabled. |
| `NS-DISC-003` | `discoveryResolveFailed` | Failed to resolve DNS-SD service TXT attributes or IP endpoint. | Peer went offline during discovery, network multicast drop, Android NsdManager internal error. | Check if peer disconnected. Check NsdManager error code in log metadata. |

---

## 2. Pairing Subsystem (`NS-PAIR`)

| Error Code | Semantic Name | Meaning | Common Underlying Causes | Investigation Steps |
|---|---|---|---|---|
| `NS-PAIR-001` | `pairingSessionExpired` | Pairing QR session or ephemeral secret has expired. | User waited longer than 180 seconds to scan the QR code. | Generate a fresh pairing QR code on the host device. |
| `NS-PAIR-002` | `pairingVerificationFailed` | Pairing cryptographic HMAC commitment verification failed. | Incorrect short code entered, corrupted QR scan, mismatched secret. | Confirm the short code matches the peer's displayed code. Rescan QR code. |
| `NS-PAIR-003` | `pairingRateLimitExceeded` | PAKE short code rate limit exceeded (lockout triggered). | 5 consecutive invalid short code attempts. | Wait for the lockout timeout or initiate a fresh pairing session from the host device. |
| `NS-PAIR-004` | `pairingMalformedPayload` | QR code URI or pairing payload failed parsing. | Invalid `nearside://pair` URI scheme, missing version, truncated base64 secret. | Verify QR generator version matches scanner protocol version. |
| `NS-PAIR-005` | `pairingCameraUnavailable` | QR scanning camera could not start or was interrupted. | Missing camera, camera in use, capture setup or runtime failure. | Retry scanning or paste the current pairing URI. |
| `NS-PAIR-006` | `pairingCameraPermissionDenied` | QR scanning camera permission is denied or restricted. | User denied access or the OS restricts it. | Enable camera permission in app settings or paste the current pairing URI. |

---

## 3. Trust Subsystem (`NS-TRUST`)

| Error Code | Semantic Name | Meaning | Common Underlying Causes | Investigation Steps |
|---|---|---|---|---|
| `NS-TRUST-001` | `trustUntrustedPeer` | Inbound transfer or connection from an un-enrolled peer. | Devices have not completed mutual QR or short code pairing. | Pair the two devices first using the Settings / Preferences menu. |
| `NS-TRUST-002` | `trustPeerBlocked` | Peer identity is in the local blocked devices list. | User manually blocked this device identity. | Check Preferences -> Paired Devices -> Blocked list to unblock if intended. |
| `NS-TRUST-003` | `trustKeyMismatch` | Peer presented a public key that differs from the pinned SPKI key. | Peer reinstalled application without migrating keypair, or potential MITM attempt. | If peer regenerated keypair, unpair previous entry and re-pair freshly. |
| `NS-TRUST-004` | `trustStorageFailed` | Failed to read or persist trust store to disk / Keychain. | Disk full, Keychain access denied, corrupted `trust_store.json`. | Check file permissions on application storage directory or Keychain entitlement. |

---

## 4. Connection Subsystem (`NS-CONN`)

| Error Code | Semantic Name | Meaning | Common Underlying Causes | Investigation Steps |
|---|---|---|---|---|
| `NS-CONN-001` | `connectionTimedOut` | TCP connection attempt to peer timed out. | Peer is sleeping, Wi-Fi client isolation enabled on router, incorrect IP in DNS-SD. | Verify peer device is awake and connected to the same Wi-Fi subnet. |
| `NS-CONN-002` | `connectionRefused` | TCP connection actively refused or host unreachable. | Peer Nearside receiver is stopped or paused, firewall blocking port 41433. | Verify receiving is active on receiver. Check local firewall rules. |
| `NS-CONN-003` | `connectionClosed` | Active TCP socket connection closed or reset unexpectedly. | Peer terminated app, network dropped, Wi-Fi handoff. | Check retry count. Check if peer app crashed or went into background freeze. |
| `NS-CONN-004` | `connectionBindFailed` | Failed to bind local TCP server socket to port 41433. | Another process or background instance bound to port 41433. | Check for zombie Nearside processes with `lsof -i :41433`. |

---

## 5. Protocol Subsystem (`NS-PROTO`)

| Error Code | Semantic Name | Meaning | Common Underlying Causes | Investigation Steps |
|---|---|---|---|---|
| `NS-PROTO-001` | `protocolMagicMismatch` | Framing magic header did not match `0x4E53` ("NS"). | Non-Nearside traffic connected to socket, corrupted stream bytes. | Inspect first 4 bytes of stream in logs. |
| `NS-PROTO-002` | `protocolInvalidFrameType` | Received frame type code is unrecognized. | Protocol version mismatch between sender and receiver. | Check client versions on sender and receiver. |
| `NS-PROTO-003` | `protocolDecodeFailed` | JSON manifest, ACK, or control frame failed decoding. | Truncated payload, encoding error. | Inspect frame payload length and JSON parser exception in logs. |
| `NS-PROTO-004` | `protocolPathTraversalRejected` | File item name contains path traversal characters (`..`, `/`, `\`). | Malicious sender or corrupted filename. | Check sanitized filename in logs. Transfer is automatically aborted for security. |

---

## 6. Transfer Subsystem (`NS-TRANSFER`)

| Error Code | Semantic Name | Meaning | Common Underlying Causes | Investigation Steps |
|---|---|---|---|---|
| `NS-TRANSFER-001` | `transferInterrupted` | Transfer interrupted mid-stream before all chunks transferred. | Socket disconnect, network switch, peer application pause. | Search logs for `correlationId=tx_...` to inspect last successful chunk offset. |
| `NS-TRANSFER-002` | `transferRejected` | Transfer manifest explicitly rejected by receiver. | Receiver disk full, user declined transfer, unsupported payload. | Check receiver ACK reason code in logs. |
| `NS-TRANSFER-003` | `transferRetryExhausted` | All transfer retry attempts exhausted without successful delivery. | Persistent network failure, receiver unreachable across 3 retry attempts. | Inspect retry backoff sequence in logs for underlying socket errors. |
| `NS-TRANSFER-004` | `transferCancelled` | Transfer was manually cancelled by the user. | User pressed Cancel on transfer progress card. | Normal user action. |

---

## 7. Verification Subsystem (`NS-VERIFY`)

| Error Code | Semantic Name | Meaning | Common Underlying Causes | Investigation Steps |
|---|---|---|---|---|
| `NS-VERIFY-001` | `verifyChunkMismatch` | 64 KiB chunk SHA-256 hash does not match chunk header hash. | Memory corruption, byte stream framing misalignment. | Check chunk offset and size in log metadata. |
| `NS-VERIFY-002` | `verifyFileChecksumMismatch` | Completed file SHA-256 checksum does not match manifest. | Corrupted file write, partial chunk drop, unexpected disk modification. | Check manifest SHA-256 vs computed SHA-256 in logs. Receiver prunes corrupted destination file. |

---

## 8. Storage Subsystem (`NS-STORAGE`)

| Error Code | Semantic Name | Meaning | Common Underlying Causes | Investigation Steps |
|---|---|---|---|---|
| `NS-STORAGE-001` | `storageReadFailed` | Failed to read source file from local disk. | File removed before transfer, permissions denied, sandbox restriction. | Check file path and OS error code (`EACCES`, `ENOENT`). |
| `NS-STORAGE-002` | `storageWriteFailed` | Failed to write chunk to destination storage. | Disk full (`ENOSPC`), read-only filesystem, sandbox permission failure. | Check available disk space in Downloads directory. |
