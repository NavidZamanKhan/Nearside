# Integrity Verification Diagnostics

## 1. Overview

Nearside enforces two-level cryptographic integrity:
1. **Per-Chunk Hash**: Every 64 KiB chunk packet carries a SHA-256 hash of its payload bytes in the binary header.
2. **Whole-File Checksum**: Upon stream completion (marked by `FrameType.COMPLETE`), the receiver finalizes the overall SHA-256 hash of the reconstructed file and compares it against `TransferItemManifest.sha256`.

## 2. Relevant Error Codes

- `NS-VERIFY-001`: 64 KiB chunk SHA-256 hash does not match chunk header.
- `NS-VERIFY-002`: Reconstructed file SHA-256 checksum does not match manifest.

## 3. Failure Behavior

- When `NS-VERIFY-001` or `NS-VERIFY-002` occurs, the receiver marks the transfer as failed and removes or prunes the unverified file data from the destination folder to prevent corrupt or tampered file consumption.
- The failure log records the item index, expected SHA-256 prefix, and computed SHA-256 prefix.
