# Nearside Protocol Specification: Message Frames

This document specifies the canonical framing, structure, and serialization formats for Nearside peer-to-peer control and data communication over TCP.

## 1. Transport Framing

All Nearside protocol messages transmitted over TCP use length-prefixed binary or JSON frames.

### 1.1 Frame Structure

Every frame consists of a 6-byte header followed by a variable-length payload:

```
+----------------+----------------+-------------------------------+
| Magic (2B)     | MsgType (2B)   | PayloadLength (4B, BigEndian) |
| 0x4E 0x53      | uint16         | uint32                        |
+----------------+----------------+-------------------------------+
| Payload (PayloadLength bytes)...                                |
+-----------------------------------------------------------------+
```

- Magic bytes: `0x4E 0x53` (ASCII "NS")
- MsgType: 16-bit unsigned integer identifying the message schema
- PayloadLength: 32-bit unsigned big-endian integer (max 64 MiB)
- Payload: Encrypted or plaintext payload depending on session state

## 2. Message Types

| Type ID | Name               | Description                                           |
|---------|--------------------|-------------------------------------------------------|
| 0x0001  | HandshakeInit      | Client initiates TLS/Noise handshake or PAKE session  |
| 0x0002  | HandshakeResponse  | Server responds to handshake initiation               |
| 0x0003  | HandshakeAuth      | Authenticated proof of session key possession         |
| 0x0010  | PairRequest        | Out-of-band or short-code pairing initiation          |
| 0x0011  | PairResponse       | Verification code commitment and public parameters    |
| 0x0012  | PairVerify         | Final authentication proof for pairing confirmation   |
| 0x0013  | PairComplete       | Pairing acknowledged and trust anchor stored          |
| 0x0020  | ManifestOffer      | Sender presents batch transfer manifest to receiver   |
| 0x0021  | ManifestDecision   | Receiver accepts or rejects batch transfer            |
| 0x0022  | ChunkStream        | Binary file data chunk with sequence and checksum     |
| 0x0023  | ChunkAck           | Receiver acknowledges received bytes or window        |
| 0x0024  | TransferComplete   | Final transfer confirmation and verification hash     |
| 0x00FF  | ErrorFrame         | Explicit error code and human-readable reason         |

## 3. Serialization Rules

- All control messages (Handshake, Pairing, Manifest, Error) are encoded as canonical UTF-8 JSON.
- Binary data streams (ChunkStream) encapsulate raw bytes with a 16-byte binary header:
  - `file_index` (uint16)
  - `chunk_index` (uint32)
  - `chunk_length` (uint32)
  - `crc32` or `sha256_prefix` (uint32)
- All numbers in binary headers are big-endian (network byte order).
