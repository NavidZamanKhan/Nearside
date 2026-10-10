import Foundation
import Network
import CryptoKit

struct SecureTransferHello: Codable {
    let role: String
    let identity: String
    let target: String
    let spki: String
    let ephemeral: String
    let nonce: String
    let binding: String
    var signature: String
    let version: Int

    func canonical() -> Data {
        var data = Data()
        for field in ["nearside-transfer-v2", "\(version)", role, identity, target, spki, ephemeral, nonce, binding] {
            let value = Data(field.utf8)
            var length = UInt32(value.count).bigEndian
            data.append(Data(bytes: &length, count: 4)); data.append(value)
        }
        return data
    }
}

func secureTransferFailure(_ message: String, cause: Error? = nil) -> NearsideError {
    NearsideError(code: .trustKeyMismatch, operation: "authenticateTransfer", message: message, underlyingError: cause)
}

final class SecureTransferHandshake {
    let identity: DeviceIdentity
    let target: String
    private let ephemeral = P256.KeyAgreement.PrivateKey()
    private let nonce: Data

    init(identity: DeviceIdentity, target: String) {
        self.identity = identity; self.target = target
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        nonce = Data(bytes)
    }

    func hello(role: String, binding: Data = Data()) throws -> SecureTransferHello {
        var hello = SecureTransferHello(role: role, identity: identity.publicIdentity, target: target,
            spki: identity.spkiDer.base64EncodedString(), ephemeral: ephemeral.publicKey.x963Representation.base64EncodedString(),
            nonce: nonce.base64EncodedString(), binding: binding.base64EncodedString(), signature: "", version: 2)
        hello.signature = try identity.privateKey.signature(for: hello.canonical()).derRepresentation.base64EncodedString()
        return hello
    }

    func validate(_ peer: SecureTransferHello, role: String, binding: Data, trustStore: PinnedTrustStore) throws {
        guard peer.version == 2, peer.role == role, peer.identity == target, peer.target == identity.publicIdentity,
              Data(base64Encoded: peer.binding) == binding else { throw secureTransferFailure("Secure handshake identity or transcript mismatch") }
        guard let spki = Data(base64Encoded: peer.spki), (64...1024).contains(spki.count),
              DeviceIdentity.computeIdentity(fromSpki: spki) == peer.identity,
              let nonce = Data(base64Encoded: peer.nonce), nonce.count == 32,
              let point = Data(base64Encoded: peer.ephemeral), point.count == 65, point.first == 4,
              let signature = Data(base64Encoded: peer.signature), (8...80).contains(signature.count) else {
            throw secureTransferFailure("Malformed secure handshake key")
        }
        switch trustStore.validatePeer(presentedSpki: spki) {
        case .success(let identity):
            guard identity == target else { throw secureTransferFailure("Unexpected recipient identity") }
        case .failure(let error):
            switch error {
            case .peerBlocked: throw NearsideError(code: .trustPeerBlocked, operation: "authenticateTransfer", message: "Peer is blocked")
            case .untrustedPeer: throw NearsideError(code: .trustUntrustedPeer, operation: "authenticateTransfer", message: "Peer is not paired")
            default: throw secureTransferFailure("Peer key does not match enrollment", cause: error)
            }
        }
        do {
            let key = try P256.Signing.PublicKey(derRepresentation: spki)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signature)
            guard key.isValidSignature(signature, for: peer.canonical()) else { throw secureTransferFailure("Secure handshake signature failed") }
        } catch { throw secureTransferFailure("Invalid secure handshake signature", cause: error) }
    }

    func records(client: SecureTransferHello, server: SecureTransferHello, isClient: Bool) throws -> SecureTransferRecords {
        let peer = isClient ? server : client
        guard let raw = Data(base64Encoded: peer.ephemeral) else { throw secureTransferFailure("Invalid ephemeral key") }
        let key = try P256.KeyAgreement.PublicKey(x963Representation: raw)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: key)
        let transcript = Data(SHA256.hash(data: client.canonical() + server.canonical()))
        let keys = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
            sharedInfo: Data("nearside-transfer-v2-keys".utf8), outputByteCount: 64).withUnsafeBytes { Data($0) }
        return SecureTransferRecords(clientKey: keys.prefix(32), serverKey: keys.suffix(32), transcript: transcript, isClient: isClient)
    }
}

final class SecureTransferRecords {
    static let maxRecord = 1024 * 1024
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let transcript: Data
    private let isClient: Bool
    private var sendSequence: UInt64 = 0
    private var receiveSequence: UInt64 = 0

    init(clientKey: Data, serverKey: Data, transcript: Data, isClient: Bool) {
        self.sendKey = SymmetricKey(data: isClient ? clientKey : serverKey)
        self.receiveKey = SymmetricKey(data: isClient ? serverKey : clientKey)
        self.transcript = transcript; self.isClient = isClient
    }

    private func context(sequence: UInt64, direction: UInt8) throws -> (AES.GCM.Nonce, Data) {
        guard sequence < UInt64(Int64.max) else { throw secureTransferFailure("Secure record sequence exhausted") }
        var big = sequence.bigEndian
        let data = Data(bytes: &big, count: 8)
        return (try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + data), transcript + Data([direction]) + data)
    }

    func seal(_ plaintext: Data) throws -> Data {
        guard (1...Self.maxRecord).contains(plaintext.count) else { throw secureTransferFailure("Invalid encrypted record size") }
        let (nonce, aad) = try context(sequence: sendSequence, direction: isClient ? 0 : 1)
        let sealed = try AES.GCM.seal(plaintext, using: sendKey, nonce: nonce, authenticating: aad)
        sendSequence += 1
        var output = Data()
        output.append(sealed.ciphertext); output.append(sealed.tag)
        return output
    }

    func open(_ encrypted: Data) throws -> Data {
        guard (17...Self.maxRecord + 16).contains(encrypted.count) else { throw secureTransferFailure("Invalid encrypted record size") }
        do {
            let (nonce, aad) = try context(sequence: receiveSequence, direction: isClient ? 1 : 0)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
            let data = try AES.GCM.open(box, using: receiveKey, authenticating: aad)
            receiveSequence += 1
            return data
        } catch { throw secureTransferFailure("Encrypted record authentication failed", cause: error) }
    }
}

/** Small stream adapter: decrypt complete bounded records before exposing framed transfer bytes. */
final class SecureTransferConnection {
    enum SendCompletion { case contentProcessed((Error?) -> Void) }
    let connection: NWConnection
    let peerIdentity: String
    private let records: SecureTransferRecords
    private var buffered = Data()

    init(connection: NWConnection, peerIdentity: String, records: SecureTransferRecords) {
        self.connection = connection; self.peerIdentity = peerIdentity; self.records = records
    }

    func send(content: Data?, completion: SendCompletion) {
        guard case let .contentProcessed(callback) = completion else { return }
        do {
            guard let data = content, !data.isEmpty else { callback(secureTransferFailure("Empty encrypted record")); return }
            var output = Data()
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + SecureTransferRecords.maxRecord)
                let sealed = try records.seal(data.subdata(in: offset..<end))
                var size = UInt32(sealed.count).bigEndian
                output.append(Data(bytes: &size, count: 4)); output.append(sealed); offset = end
            }
            connection.send(content: output, completion: .contentProcessed { callback($0) })
        } catch { callback(error) }
    }

    func receive(minimumIncompleteLength: Int, maximumLength: Int,
        completion: @escaping (Data?, NWConnection.ContentContext?, Bool, Error?) -> Void) {
        guard minimumIncompleteLength >= 0, maximumLength >= minimumIncompleteLength,
              maximumLength <= SecureTransferRecords.maxRecord else { completion(nil, nil, false, secureTransferFailure("Invalid encrypted read size")); return }
        func deliver() {
            if buffered.count >= minimumIncompleteLength {
                let count = min(buffered.count, maximumLength)
                let data = Data(buffered.prefix(count)); buffered.removeFirst(count)
                completion(data, nil, false, nil)
                return
            }
            Self.readExact(connection: connection, size: 4) { result in
                do {
                    let header = try result.get()
                    let size = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
                    guard (17...SecureTransferRecords.maxRecord + 16).contains(size) else { throw secureTransferFailure("Invalid encrypted record size") }
                    Self.readExact(connection: self.connection, size: size) { result in
                        do {
                            self.buffered.append(try self.records.open(result.get()))
                            guard self.buffered.count <= 2 * SecureTransferRecords.maxRecord else { throw secureTransferFailure("Encrypted receive buffer exceeded") }
                            deliver()
                        } catch { completion(nil, nil, false, error) }
                    }
                } catch { completion(nil, nil, false, error) }
            }
        }
        deliver()
    }

    func cancel() { connection.cancel() }

    static func readExact(connection: NWConnection, size: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        guard size > 0 else { completion(.success(Data())); return }
        var accumulated = Data()
        func read() {
            let remaining = size - accumulated.count
            connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining) { data, _, closed, error in
                if let error = error { completion(.failure(error)); return }
                if let data = data { accumulated.append(data) }
                if accumulated.count == size { completion(.success(accumulated)) }
                else if closed || data?.isEmpty != false { completion(.failure(NearsideError(code: .connectionClosed, operation: "readSecureRecord", message: "Connection closed during secure record"))) }
                else { read() }
            }
        }
        read()
    }

    private static func writeHello(connection: NWConnection, hello: SecureTransferHello, type: UInt8, completion: @escaping (Error?) -> Void) {
        do {
            let data = try JSONEncoder().encode(hello)
            guard (1...16384).contains(data.count) else { throw secureTransferFailure("Invalid secure handshake size") }
            var packet = Data(); var magic = TransferChunk.magic.bigEndian; var size = UInt32(data.count).bigEndian
            packet.append(Data(bytes: &magic, count: 4)); packet.append(type); packet.append(Data(bytes: &size, count: 4)); packet.append(data)
            connection.send(content: packet, completion: .contentProcessed { completion($0) })
        } catch { completion(error) }
    }

    static func client(connection: NWConnection, identity: DeviceIdentity, target: String, trustStore: PinnedTrustStore,
        completion: @escaping (Result<SecureTransferConnection, Error>) -> Void) {
        do {
            let handshake = SecureTransferHandshake(identity: identity, target: target)
            let client = try handshake.hello(role: "client")
            writeHello(connection: connection, hello: client, type: 0x20) { error in
                if let error = error { completion(.failure(error)); return }
                readExact(connection: connection, size: 9) { result in
                    do {
                        let header = try result.get()
                        guard header.prefix(4).withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }).bigEndian == TransferChunk.magic,
                              header[4] == 0x21 else { throw secureTransferFailure("Secure transfer handshake required") }
                        let size = Int(header.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
                        guard (1...16384).contains(size) else { throw secureTransferFailure("Invalid secure handshake size") }
                        readExact(connection: connection, size: size) { result in
                            do {
                                let server = try JSONDecoder().decode(SecureTransferHello.self, from: result.get())
                                try handshake.validate(server, role: "server", binding: Data(SHA256.hash(data: client.canonical())), trustStore: trustStore)
                                let records = try handshake.records(client: client, server: server, isClient: true)
                                completion(.success(SecureTransferConnection(connection: connection, peerIdentity: target, records: records)))
                            } catch { completion(.failure(error)) }
                        }
                    } catch { completion(.failure(error)) }
                }
            }
        } catch { completion(.failure(error)) }
    }

    static func server(connection: NWConnection, helloLength: Int, identity: DeviceIdentity, trustStore: PinnedTrustStore,
        completion: @escaping (Result<SecureTransferConnection, Error>) -> Void) {
        guard (1...16384).contains(helloLength) else { completion(.failure(secureTransferFailure("Invalid secure handshake size"))); return }
        readExact(connection: connection, size: helloLength) { result in
            do {
                let client = try JSONDecoder().decode(SecureTransferHello.self, from: result.get())
                let handshake = SecureTransferHandshake(identity: identity, target: client.identity)
                try handshake.validate(client, role: "client", binding: Data(), trustStore: trustStore)
                let server = try handshake.hello(role: "server", binding: Data(SHA256.hash(data: client.canonical())))
                let records = try handshake.records(client: client, server: server, isClient: false)
                writeHello(connection: connection, hello: server, type: 0x21) { error in
                    if let error = error { completion(.failure(error)); return }
                    completion(.success(SecureTransferConnection(connection: connection, peerIdentity: client.identity, records: records)))
                }
            } catch { completion(.failure(error)) }
        }
    }
}
