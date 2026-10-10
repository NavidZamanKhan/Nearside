import Foundation
import Network

/// Test-only out-of-band QR exchange uses temporary files instead of a physical camera.
@main
struct CrossPlatformTransferHarness {
    private final class InboundResults {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var results: [Result<TransferRecord, Error>] = []

        func append(_ result: Result<TransferRecord, Error>) {
            lock.lock(); results.append(result); lock.unlock()
            ready.signal()
        }

        func next() throws -> Result<TransferRecord, Error> {
            guard ready.wait(timeout: .now() + 30) == .success else {
                throw HarnessError.failed("Swift inbound operation timed out")
            }
            lock.lock(); defer { lock.unlock() }
            return results.removeFirst()
        }
    }

    private enum HarnessError: Error { case failed(String) }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw HarnessError.failed(message) }
    }

    private static func waitForFile(_ url: URL, timeout: TimeInterval = 90) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else { throw HarnessError.failed("Kotlin harness phase timed out") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let identity = DeviceIdentity()
        let trustURL = directory.appendingPathComponent("swift_trust.json")
        let trust = PinnedTrustStore(customStorageURL: trustURL)
        try require(trust.allEnrolledPeers().isEmpty, "Swift harness must start without any peer pins")
        let incoming = directory.appendingPathComponent("swift_received")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let engine = TransferEngine()
        let listener = try NWListener(using: .tcp, on: .any)
        let listenReady = DispatchSemaphore(value: 0)
        let inbound = InboundResults()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: listenReady.signal()
            case .failed: print("Swift harness listener failed"); exit(1)
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            engine.handleInboundConnection(connection: connection, trustStore: trust, deviceIdentity: identity,
                destinationFolder: incoming, onProgress: { _, _ in }, onComplete: inbound.append)
        }
        listener.start(queue: DispatchQueue(label: "nearside.interop.listener"))
        defer { listener.cancel() }
        guard listenReady.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else {
            throw HarnessError.failed("Swift harness listener did not start")
        }

        let qr = QRPairingPayload(hostIdentity: identity.publicIdentity, hostName: "Swift harness", ip: "127.0.0.1", port: Int(port))
        QRPairingSessions.shared.register(qr, expectedClientIdentity: DeviceIdentity().publicIdentity)
        defer { QRPairingSessions.shared.unregister(qr.sessionId) }
        let sender: [String: Any] = ["identity": identity.publicIdentity, "spki": identity.spkiDer.base64EncodedString(),
            "port": Int(port), "qrUri": qr.toURI()]
        try JSONSerialization.data(withJSONObject: sender).write(to: directory.appendingPathComponent("sender.json"), options: .atomic)

        let serverPath = directory.appendingPathComponent("server.json")
        try waitForFile(serverPath)
        guard let server = try JSONSerialization.jsonObject(with: Data(contentsOf: serverPath)) as? [String: Any],
              let peer = server["identity"] as? String, let encodedSpki = server["spki"] as? String,
              let spki = Data(base64Encoded: encodedSpki), let peerPort = server["port"] as? Int,
              let peerUri = server["qrUri"] as? String, let peerQR = QRPairingPayload.fromURI(peerUri) else {
            throw HarnessError.failed("Kotlin harness endpoint or QR is malformed")
        }
        try require(DeviceIdentity.computeIdentity(fromSpki: spki) == peer, "Kotlin identity does not match its public key")
        try peerQR.validateSelectedHost(peer, localIdentity: identity.publicIdentity)

        let rejected = try inbound.next()
        guard case .failure(let rejection) = rejected,
              (rejection as? NearsideError)?.code == .pairingVerificationFailed else {
            throw HarnessError.failed("A request from a different selected target was not rejected")
        }
        try require(trust.allEnrolledPeers().isEmpty, "Rejected target unexpectedly established trust")
        QRPairingSessions.shared.register(qr, expectedClientIdentity: peer)
        try Data().write(to: directory.appendingPathComponent("swift_pairing_ready"), options: .atomic)

        let pairRecord = try inbound.next().get()
        try require(pairRecord.filename == "Pairing Handshake" && pairRecord.fileCount == 0,
            "Swift receiver did not complete the QR handshake")
        try waitForFile(directory.appendingPathComponent("android_first_pairing"), timeout: 30)
        try require(!QRPairingSessions.shared.consume(qr.sessionId), "Successful Swift QR session was not consumed")
        let pinnedPeer = try trust.validatePeer(presentedSpki: spki).get()
        try require(pinnedPeer == peer, "Swift did not pin the authenticated Kotlin public key")
        let persistedTrust = PinnedTrustStore(customStorageURL: trustURL)
        let persistedPeer = try persistedTrust.validatePeer(presentedSpki: spki).get()
        try require(persistedPeer == peer, "Swift QR enrollment did not persist its exact pin")

        let paired = DispatchSemaphore(value: 0)
        var pairResult: Result<PairResponseFrame, Error>?
        engine.initiatePairing(to: "127.0.0.1", port: UInt16(peerPort), deviceIdentity: identity,
            deviceName: "Swift harness", trustStore: trust, qrPayload: peerQR) { result in
                pairResult = result; paired.signal()
            }
        try require(paired.wait(timeout: .now() + 30) == .success, "Swift QR client timed out")
        guard let response = try pairResult?.get() else { throw HarnessError.failed("Swift QR client returned no response") }
        try require(response.status == "ACCEPTED" && response.serverId == peer && response.qrSessionId == peerQR.sessionId,
            "Swift QR client did not verify final acceptance from the selected identity")
        try waitForFile(directory.appendingPathComponent("android_reverse_pairing"), timeout: 30)
        try require(trust.canTransfer(identity: peer), "Swift peer remains unavailable for authenticated transfer")

        let file = directory.appendingPathComponent("interop.bin")
        let expected = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
        try expected.write(to: file)
        let device = NearsideDevice(id: peer, name: "Kotlin harness", platform: .android,
            fingerprint: peer, ipAddress: "127.0.0.1", port: UInt16(peerPort))
        let sent = DispatchSemaphore(value: 0)
        var sendResult: Result<TransferRecord, Error>?
        engine.sendFiles(files: [file], to: device, senderId: identity.publicIdentity, trustStore: trust, deviceIdentity: identity,
            onProgress: { _, _, _ in }, completion: { result in sendResult = result; sent.signal() })
        try require(sent.wait(timeout: .now() + 30) == .success, "Swift sender timed out")
        guard let sentRecord = try sendResult?.get() else { throw HarnessError.failed("Swift sender returned no result") }
        try require(sentRecord.status == .completed && sentRecord.progress == 1,
            "Swift sender did not receive the encrypted final completion acknowledgement")
        let receivedRecord = try inbound.next().get()
        try require(receivedRecord.fileCount == 1 && receivedRecord.status == .completed,
            "Swift receiver did not verify the Kotlin transfer")
        let bytes = try Data(contentsOf: incoming.appendingPathComponent("interop.bin"))
        try require(bytes == expected, "Kotlin-to-Swift on-disk content mismatch")
        print("CrossPlatformTransferHarness: rejected a mismatched selected target; mutual QR enrollment persisted in both directions; encrypted transfers verified")
    }
}
