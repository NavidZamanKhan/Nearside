# Transfer & Connection Diagnostics

## 1. Overview

The Transfer subsystem manages framed TCP socket transport, manifest/ACK negotiation, 64 KiB chunk streaming, offset resume, and retry backoff across macOS, iOS, and Android.

## 2. Relevant Error Codes

- `NS-CONN-001`: Peer connection timed out.
- `NS-CONN-002`: Peer connection refused or host unreachable.
- `NS-CONN-003`: Connection closed or stream reset mid-transfer.
- `NS-CONN-004`: Server listener port bind failed.
- `NS-PROTO-001`: Framing magic mismatch (`MAGIC != 0x4E53`).
- `NS-PROTO-002`: Invalid frame type code.
- `NS-PROTO-003`: JSON manifest or ACK decoding failure.
- `NS-PROTO-004`: Path traversal rejected in item filename.
- `NS-TRANSFER-001`: Transfer interrupted before completion.
- `NS-TRANSFER-002`: Transfer rejected by receiver.
- `NS-TRANSFER-003`: Transfer retry attempts exhausted.
- `NS-TRANSFER-004`: Transfer cancelled by user.

## 3. Correlation ID

The primary correlation ID is `transferId` (formatted as `tx_[hex]`).
- Appears in `TransferManifest.transferId`
- Appears in `TransferAck.transferId`
- Appears in `TransferRecord.id` and `TransferRecord.correlationId`
- Propagated through all outbound and inbound logs

For early inbound connections before manifest exchange, `connectionId` (formatted as `conn_[hex]`) is used.

## 4. State Transitions

```
[idle]
  |
  v (sendFiles requested)
[connecting]
  |
  +---> [retrying] (on transient connection failure, up to maxAttempts)
  |        |
  |        v
  |     [connecting]
  |
  v (socket connected)
[negotiating] (manifest offer & ACK exchange)
  |
  +---> [rejected] (untrusted peer or invalid manifest -> NS-TRANSFER-002 / NS-TRUST-001)
  |
  v (ACK received)
[transferring] (streaming 64 KiB chunks)
  |
  +---> [failed] (interrupted -> NS-TRANSFER-001)
  |
  v (all chunks transferred)
[verifying] (SHA-256 hash checks)
  |
  +---> [failed] (hash mismatch -> NS-VERIFY-001 / NS-VERIFY-002)
  |
  v
[completed]
```

## 5. How to Diagnose a Transfer Failure

1. **Locate the Failure Code**: Look for `NS-TRANSFER-*` or `NS-CONN-*` in the logs or in `TransferRecord.errorCode`.
2. **Extract the `correlationId`**: Copy the `tx_...` identifier.
3. **Filter Logs by `correlationId`**:
   - Trace the lifecycle from `state=starting` through `state=transferring`.
   - Identify the attempt number (`retryCount=...`).
   - Inspect the `underlying` description for native OS socket errors (`POSIXError: Connection reset by peer` or `SocketTimeoutException`).
4. **Inspect Resume Checkpoint**: If a retry occurred, check whether the receiver acknowledged partial bytes (`bytesReceived=...`).

## 6. Endpoint Recovery

Live discovery for the selected persistent identity takes precedence over its saved address. Android re-resolves active service registrations after a transport failure, with a two-second discovery deadline. Apple connects using the current Bonjour service endpoint so DNS-SD resolves its address on each attempt. A service lost during resolution cannot replace an active identity record.

Only the selected identity is considered; display names, an arbitrary nearby device, localhost ports, and emulator addresses are never recovery candidates. Discovery supplies address hints and cannot enroll a peer or replace its pinned key. Receiver and sender trust checks enforce user blocks. Missing endpoints produce `NS-CONN-002`, and transport retry exhaustion produces `NS-TRANSFER-003` with the original native error, transfer correlation ID, and retry count. Protocol, integrity, trust, and cancellation failures are terminal.

The default retry limit is three attempts, with at most ten allowed by configuration and a thirty-second ceiling on backoff. A completed transfer updates endpoint metadata without changing the enrolled identity or public key. macOS persists blocked identities alongside trust records and accepts the previous records-only storage format.

For manual validation, pair the devices, transfer a small file, change the recipient's Wi-Fi/DHCP address, and send again from the existing paired-device entry. Confirm one recipient identity remains, the new address is used, and the file checksum matches. Repeat with the recipient offline to confirm bounded failure; block the recipient and verify discovery cannot restore transfer permission.
