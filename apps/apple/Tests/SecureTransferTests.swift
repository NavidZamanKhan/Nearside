import Foundation
import CryptoKit

@main
struct SecureTransferTests {
    static func main() throws {
        let first = DeviceIdentity()
        let second = DeviceIdentity()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let trust = PinnedTrustStore(customStorageURL: path)
        trust.enroll(identity: first.publicIdentity, name: "Client", platform: "android", publicKey: first.publicKey)
        trust.enroll(identity: second.publicIdentity, name: "Server", platform: "macos", publicKey: second.publicKey)
        let client = SecureTransferHandshake(identity: first, target: second.publicIdentity)
        let server = SecureTransferHandshake(identity: second, target: first.publicIdentity)
        let clientHello = try client.hello(role: "client")
        try server.validate(clientHello, role: "client", binding: Data(), trustStore: trust)
        let binding = Data(SHA256.hash(data: clientHello.canonical()))
        let serverHello = try server.hello(role: "server", binding: binding)
        try client.validate(serverHello, role: "server", binding: binding, trustStore: trust)
        let send = try client.records(client: clientHello, server: serverHello, isClient: true)
        let receive = try server.records(client: clientHello, server: serverHello, isClient: false)
        let plain = Data("secret filename and bytes".utf8)
        let encrypted = try send.seal(plain)
        precondition(encrypted != plain)
        let decoded = try receive.open(encrypted)
        let response = try send.open(receive.seal(plain))
        precondition(decoded == plain)
        precondition(response == plain)
        expectFailure { _ = try receive.open(encrypted) }
        var altered = try send.seal(plain)
        altered[0] ^= 1
        expectFailure { _ = try receive.open(altered) }
        expectFailure { _ = try send.open(altered) }
        expectFailure { _ = try receive.open(Data(repeating: 0, count: 16)) }
        expectFailure { _ = try send.seal(Data(repeating: 0, count: SecureTransferRecords.maxRecord + 1)) }
        var invalid = serverHello
        invalid.signature = Data(repeating: 0, count: 64).base64EncodedString()
        expectFailure { try client.validate(invalid, role: "server", binding: binding, trustStore: trust) }
        expectFailure { try client.validate(serverHello, role: "client", binding: binding, trustStore: trust) }
        trust.block(identity: second.publicIdentity)
        expectFailure { try client.validate(serverHello, role: "server", binding: binding, trustStore: trust) }
        print("SecureTransferTests: handshake, directional encryption, replay/tamper/blocked-peer rejection passed")
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected secure transfer rejection") } catch {}
    }
}
