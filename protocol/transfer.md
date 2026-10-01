# Nearside Protocol Specification: Data Transfer

This document specifies the batch transfer negotiation, chunking, and acknowledgement protocol.

## 1. Transfer Stages

A transfer consists of three sequential phases:

1. **Manifest Negotiation**: Sender presents item count, names, total byte sizes, and checksums. Receiver prompts user or auto-accepts based on trust policy.
2. **Chunked Streaming**: Payloads are streamed in bounded chunks (typically 64 KiB) over the encrypted TLS/Noise channel.
3. **Completion & Verification**: Sender issues TransferComplete. Receiver validates total byte count and individual file SHA-256 hashes before moving files from staging to target destination.

## 2. Manifest Schema

```json
{
  "transfer_id": "tx_9f83a21b4c7d",
  "sender_id": "ns1_39a8bc43d87e",
  "total_bytes": 104857600,
  "item_count": 2,
  "items": [
    {
      "index": 0,
      "name": "presentation.pdf",
      "mime_type": "application/pdf",
      "size": 78643200,
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    },
    {
      "index": 1,
      "name": "notes.txt",
      "mime_type": "text/plain",
      "size": 26214400,
      "sha256": "cb8379ac2098aa165029e3938a51da0bcecfc008fd008f483bfaec321306d131"
    }
  ]
}
```

## 3. Streaming and Backpressure

- Streaming chunks are indexed by `file_index` and `chunk_index`.
- Receiver can issue `ChunkAck` every N chunks to regulate transmission speed or signal pauses.
- If network drops mid-stream, receiver preserves staging state. Resumption negotiates starting chunk offset.
