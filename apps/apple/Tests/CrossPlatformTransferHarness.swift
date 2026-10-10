import Foundation
import Network
import CryptoKit

@main
struct CrossPlatformTransferHarness {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let identity = DeviceIdentity()
        let trust = PinnedTrustStore(customStorageURL: directory.appendingPathComponent("swift_trust.json"))
        let incoming = directory.appendingPathComponent("swift_received")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let engine = TransferEngine()
        let listener = try NWListener(using: .tcp, on: .any)
        let listenReady = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        var receiveResult: Result<TransferRecord, Error>?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: listenReady.signal()
            case .failed(let error): print("Listener failed: \(error)"); exit(1)
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            engine.handleInboundConnection(connection: connection, trustStore: trust, deviceIdentity: identity,
                destinationFolder: incoming, onProgress: { _, _ in }, onComplete: { result in
                    receiveResult = result; received.signal()
                })
        }
        listener.start(queue: DispatchQueue(label: "nearside.interop.listener"))
        guard listenReady.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else { fatalError("Listener did not start") }
        let sender: [String: Any] = ["identity": identity.publicIdentity, "spki": identity.spkiDer.base64EncodedString(), "port": Int(port)]
        try JSONSerialization.data(withJSONObject: sender).write(to: directory.appendingPathComponent("sender.json"), options: .atomic)
        let serverPath = directory.appendingPathComponent("server.json")
        let deadline = Date().addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: serverPath.path) {
            guard Date() < deadline else { fatalError("Kotlin harness did not publish endpoint") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let server = try JSONSerialization.jsonObject(with: Data(contentsOf: serverPath)) as! [String: Any]
        let peer = server["identity"] as! String
        let spki = Data(base64Encoded: server["spki"] as! String)!
        precondition(DeviceIdentity.computeIdentity(fromSpki: spki) == peer)
        trust.enroll(identity: peer, name: "Kotlin harness", platform: "android", publicKey: try P256.Signing.PublicKey(derRepresentation: spki))
        let file = directory.appendingPathComponent("interop.bin")
        let expected = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
        try expected.write(to: file)
        let device = NearsideDevice(id: peer, name: "Kotlin harness", platform: .android,
            fingerprint: peer, ipAddress: "127.0.0.1", port: UInt16(server["port"] as! Int))
        let sent = DispatchSemaphore(value: 0)
        var sendResult: Result<TransferRecord, Error>?
        engine.sendFiles(files: [file], to: device, senderId: identity.publicIdentity, trustStore: trust, deviceIdentity: identity,
            onProgress: { _, _, _ in }, completion: { result in sendResult = result; sent.signal() })
        guard sent.wait(timeout: .now() + 30) == .success else { fatalError("Swift sender timed out") }
        _ = try sendResult!.get()
        guard received.wait(timeout: .now() + 30) == .success else { fatalError("Swift receiver timed out") }
        _ = try receiveResult!.get()
        let bytes = try Data(contentsOf: incoming.appendingPathComponent("interop.bin"))
        precondition(bytes == expected)
        listener.cancel()
        print("CrossPlatformTransferHarness: both directions authenticated, encrypted, and checksum verified")
    }
}
