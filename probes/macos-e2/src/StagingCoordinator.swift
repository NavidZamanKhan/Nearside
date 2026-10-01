import Foundation
import CryptoKit

public struct JobItem: Codable {
    public let itemId: String
    public let originalName: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let sha256Hex: String
    public let stagedPath: String

    public init(itemId: String, originalName: String, mimeType: String, sizeBytes: Int64, sha256Hex: String, stagedPath: String) {
        self.itemId = itemId
        self.originalName = originalName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.sha256Hex = sha256Hex
        self.stagedPath = stagedPath
    }
}

public enum JobState: String, Codable {
    case staged = "STAGED"
    case claimedByResident = "CLAIMED_BY_RESIDENT"
    case pendingAppLaunch = "PENDING_APP_LAUNCH"
    case completed = "COMPLETED"
    case failed = "FAILED"
}

public struct JobManifest: Codable {
    public let jobId: String
    public let timestamp: Double
    public var state: JobState
    public let items: [JobItem]
    public let totalBytes: Int64
    public let manifestHash: String

    public init(jobId: String, items: [JobItem], state: JobState = .staged) {
        self.jobId = jobId
        self.timestamp = Date().timeIntervalSince1970
        self.state = state
        self.items = items
        self.totalBytes = items.reduce(0) { $0 + $1.sizeBytes }

        var hasher = SHA256()
        for item in items {
            if let data = item.sha256Hex.data(using: .utf8) {
                hasher.update(data: data)
            }
        }
        self.manifestHash = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}

public final class StagingCoordinator {
    public let stagingDirectory: URL

    public init(customStagingDir: URL? = nil) {
        if let customDir = customStagingDir {
            self.stagingDirectory = customDir
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.stagingDirectory = base.appendingPathComponent("com.nearside.probe.e2.staging", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.stagingDirectory, withIntermediateDirectories: true)
    }

    public func cleanStaging() {
        try? FileManager.default.removeItem(at: self.stagingDirectory)
        try? FileManager.default.createDirectory(at: self.stagingDirectory, withIntermediateDirectories: true)
    }

    public func stageFileFromUrl(sourceUrl: URL, originalName: String? = nil) throws -> JobItem {
        let itemId = UUID().uuidString
        let name = originalName ?? sourceUrl.lastPathComponent
        let destinationUrl = stagingDirectory.appendingPathComponent("\(itemId)_\(name)")

        let handle = try FileHandle(forReadingFrom: sourceUrl)
        defer { try? handle.close() }

        FileManager.default.createFile(atPath: destinationUrl.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: destinationUrl)
        defer { try? writeHandle.close() }

        var hasher = SHA256()
        var totalBytes: Int64 = 0
        let chunkSize = 64 * 1024

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            writeHandle.write(chunk)
            totalBytes += Int64(chunk.count)
        }

        let sha256Hex = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()

        return JobItem(
            itemId: itemId,
            originalName: name,
            mimeType: "application/octet-stream",
            sizeBytes: totalBytes,
            sha256Hex: sha256Hex,
            stagedPath: destinationUrl.path
        )
    }

    public func stageData(data: Data, originalName: String, mimeType: String = "text/plain") throws -> JobItem {
        let itemId = UUID().uuidString
        let destinationUrl = stagingDirectory.appendingPathComponent("\(itemId)_\(originalName)")

        try data.write(to: destinationUrl)
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()

        return JobItem(
            itemId: itemId,
            originalName: originalName,
            mimeType: mimeType,
            sizeBytes: Int64(data.count),
            sha256Hex: hash,
            stagedPath: destinationUrl.path
        )
    }

    public func saveManifest(_ manifest: JobManifest) throws -> URL {
        let manifestUrl = stagingDirectory.appendingPathComponent("job_\(manifest.jobId).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestUrl, options: .atomic)
        return manifestUrl
    }

    public func loadManifest(jobId: String) throws -> JobManifest {
        let manifestUrl = stagingDirectory.appendingPathComponent("job_\(jobId).json")
        let data = try Data(contentsOf: manifestUrl)
        return try JSONDecoder().decode(JobManifest.self, from: data)
    }

    public func updateManifestState(jobId: String, newState: JobState) throws {
        var manifest = try loadManifest(jobId: jobId)
        manifest.state = newState
        _ = try saveManifest(manifest)
    }
}
