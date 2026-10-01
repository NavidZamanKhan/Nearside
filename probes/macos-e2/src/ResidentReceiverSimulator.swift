import Foundation
import CryptoKit

public struct JobAcknowledgment: Codable {
    public let jobId: String
    public let ackTimestamp: Double
    public let verifiedItems: Int
    public let totalVerifiedBytes: Int64
    public let residentProcessId: Int32
    public let status: String

    public init(jobId: String, verifiedItems: Int, totalVerifiedBytes: Int64, status: String = "SUCCESS") {
        self.jobId = jobId
        self.ackTimestamp = Date().timeIntervalSince1970
        self.verifiedItems = verifiedItems
        self.totalVerifiedBytes = totalVerifiedBytes
        self.residentProcessId = ProcessInfo.processInfo.processIdentifier
        self.status = status
    }
}

public final class ResidentReceiverSimulator {
    public let coordinator: StagingCoordinator
    private var isRunning: Bool = false

    public init(coordinator: StagingCoordinator) {
        self.coordinator = coordinator
    }

    public func start() {
        isRunning = true
    }

    public func stop() {
        isRunning = false
    }

    public func isResidentActive() -> Bool {
        return isRunning
    }

    public func processPendingJobs() throws -> [JobAcknowledgment] {
        guard isRunning else {
            return []
        }

        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: coordinator.stagingDirectory, includingPropertiesForKeys: nil)
        var acks: [JobAcknowledgment] = []

        for fileUrl in contents where fileUrl.lastPathComponent.hasPrefix("job_") && fileUrl.pathExtension == "json" {
            let jobId = fileUrl.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "job_", with: "")
            let ackFile = coordinator.stagingDirectory.appendingPathComponent("job_\(jobId).ack")

            if fileManager.fileExists(atPath: ackFile.path) {
                continue
            }

            let manifest = try coordinator.loadManifest(jobId: jobId)
            if manifest.state == .staged {
                let ack = try claimAndVerify(manifest: manifest)
                acks.append(ack)
            }
        }

        return acks
    }

    public func claimAndVerify(manifest: JobManifest) throws -> JobAcknowledgment {
        guard isRunning else {
            throw NSError(domain: "ResidentReceiver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Resident process is not active"])
        }

        try coordinator.updateManifestState(jobId: manifest.jobId, newState: .claimedByResident)

        var verifiedCount = 0
        var verifiedBytes: Int64 = 0

        for item in manifest.items {
            let itemUrl = URL(fileURLWithPath: item.stagedPath)
            guard FileManager.default.fileExists(atPath: itemUrl.path) else {
                throw NSError(domain: "ResidentReceiver", code: 2, userInfo: [NSLocalizedDescriptionKey: "Staged file missing at \(item.stagedPath)"])
            }

            let handle = try FileHandle(forReadingFrom: itemUrl)
            defer { try? handle.close() }

            var hasher = SHA256()
            var count: Int64 = 0
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                count += Int64(chunk.count)
            }

            let computedHash = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()

            guard count == item.sizeBytes else {
                throw NSError(domain: "ResidentReceiver", code: 3, userInfo: [NSLocalizedDescriptionKey: "Byte size mismatch for \(item.originalName): expected \(item.sizeBytes), got \(count)"])
            }

            guard computedHash == item.sha256Hex else {
                throw NSError(domain: "ResidentReceiver", code: 4, userInfo: [NSLocalizedDescriptionKey: "SHA256 mismatch for \(item.originalName)"])
            }

            verifiedCount += 1
            verifiedBytes += count
        }

        let ack = JobAcknowledgment(
            jobId: manifest.jobId,
            verifiedItems: verifiedCount,
            totalVerifiedBytes: verifiedBytes,
            status: "CLAIMED_AND_VERIFIED"
        )

        let ackUrl = coordinator.stagingDirectory.appendingPathComponent("job_\(manifest.jobId).ack")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let ackData = try encoder.encode(ack)
        try ackData.write(to: ackUrl, options: .atomic)

        try coordinator.updateManifestState(jobId: manifest.jobId, newState: .completed)

        return ack
    }
}
