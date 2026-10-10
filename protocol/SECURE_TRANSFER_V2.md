# Authenticated encrypted transfer transport, version 2

Transfer connections require mutually enrolled signing keys. DNS-SD records are address hints and never grant trust. A sender requires the exact selected peer identity and rejects a different enrolled peer at that address. A receiver verifies the sender before reading any manifest or creating any destination file. There is no plaintext fallback; both devices must run a version supporting this transport.

## Handshake

The client sends a frame with magic `0x4E534644`, type `0x20`, and a four-byte unsigned big-endian JSON length. The server responds with type `0x21`. Handshake bodies are limited to 16 KiB. Both JSON bodies contain `version` (2), `role` (`client` or `server`), `identity`, `target`, `spki`, `ephemeral`, `nonce`, `binding`, and `signature`.

`spki` contains the enrolled signing key's DER SubjectPublicKeyInfo in standard Base64. `ephemeral` contains a fresh P-256 key agreement public key in 65-byte uncompressed X9.63 form. `nonce` contains 32 random bytes. The client binding is empty; the server binding is SHA-256 of the client's canonical fields. The identity equals `ns1_` followed by the lowercase SHA-256 hex digest of the SPKI. `target` is the recipient's exact persistent identity.

The signed canonical bytes consist of these UTF-8 strings, in order, each prefixed by its four-byte unsigned big-endian byte length:

1. `nearside-transfer-v2`
2. `2`
3. `role`
4. `identity`
5. `target`
6. `spki`
7. `ephemeral`
8. `nonce`
9. `binding`

`signature` is SHA-256/ECDSA over those bytes, encoded as an ASN.1 DER ECDSA signature in Base64. DER is used explicitly on both platforms, including Android Keystore, so provider support for P1363 does not affect interoperability. Signature verification also checks the role, target, nonce/key sizes, response binding, identity hash, enrolled SPKI, and blocked state.

## Encryption

The transcript hash is SHA-256 of the client canonical bytes followed by the server canonical bytes. Each side computes the 32-byte P-256 ECDH shared secret, then HKDF-SHA256 with the transcript hash as salt and UTF-8 `nearside-transfer-v2-keys` as info. The 64-byte output splits into a 32-byte client-to-server AES key followed by a 32-byte server-to-client AES key. Every connection attempt creates fresh ephemeral keys and nonces.

Each encrypted record has a four-byte unsigned big-endian ciphertext length followed by AES-256-GCM ciphertext and its 16-byte tag. Plaintext record size is 1 byte through 1 MiB. Records omit the nonce because it is deterministically four zero bytes followed by the eight-byte unsigned big-endian sequence counter, starting at zero independently in each direction. The associated data is the 32-byte transcript hash, one direction byte (0 for client-to-server, 1 for server-to-client), and that eight-byte sequence counter. Counters cannot reach the signed 64-bit maximum. Invalid sizes, tags, sequence order, or directions terminate the connection.

Decrypted bytes retain Nearside's manifest/ACK/chunk/COMPLETE frame structure. The manifest's sender must match the authenticated identity. Receivers validate bounded manifest/chunk sizes, item counts/indexes/names, byte totals, sequential offsets, and file checksums. Resume checkpoints cover only a contiguous completed prefix and the first partially received file. Every resumed connection authenticates again.

After COMPLETE, the receiver closes its files and checks every actual size and SHA-256 digest. It sends an encrypted ACK with `status=COMPLETED`, the matching transfer ID, and the exact byte total. Senders report success and update cached endpoint metadata only after validating that confirmation.

## Verification

`scripts/verify_secure_transfer.sh` launches the actual Swift and JVM Kotlin engines over local sockets, transfers a 128 KiB file in both directions, and verifies its on-disk bytes and receiver completion confirmation. Pure crypto regression suites additionally cover transcript/identity mismatch, changed signatures, blocked peers, tampering, replay, wrong direction, and record bounds. Physical Android Keystore and network-transition testing remain required on devices.
