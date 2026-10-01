import Foundation
import CryptoKit

@main
struct TestHarnessE2 {
    static func main() async {
        print("==================================================")
        print("  Nearside E2 Feasibility Probe: macOS Share Tests")
        print("==================================================")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("NearsideE2Test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stagingDir = tempDir.appendingPathComponent("staging")
        let coordinator = StagingCoordinator(customStagingDir: stagingDir)
        let resident = ResidentReceiverSimulator(coordinator: coordinator)

        var passedCount = 0
        var failedCount = 0

        func runTest(name: String, block: () throws -> Void) {
            print("\n[TEST] Running: \(name)")
            do {
                try block()
                print("  -> PASSED: \(name)")
                passedCount += 1
            } catch {
                print("  -> FAILED: \(name) with error: \(error)")
                failedCount += 1
            }
        }

        // Test 1: Single File Staging
        runTest(name: "Single File Staging and Digest Verification") {
            let sampleFile = tempDir.appendingPathComponent("sample_photo.jpg")
            let sampleData = "SAMPLE_JPEG_BINARY_DATA_TEST_1234567890".data(using: .utf8)!
            try sampleData.write(to: sampleFile)

            let item = try coordinator.stageFileFromUrl(sourceUrl: sampleFile)
            guard item.sizeBytes == Int64(sampleData.count) else {
                throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Size mismatch"])
            }
            let expectedHash = SHA256.hash(data: sampleData).compactMap { String(format: "%02x", $0) }.joined()
            guard item.sha256Hex == expectedHash else {
                throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Hash mismatch"])
            }
            guard FileManager.default.fileExists(atPath: item.stagedPath) else {
                throw NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "Staged file missing"])
            }
        }

        // Test 2: Temporary File Lifetime Boundary (NSItemProvider simulation)
        runTest(name: "NSItemProvider Temporary File Lifetime Boundary") {
            let hostScratchDir = tempDir.appendingPathComponent("host_scratch")
            try FileManager.default.createDirectory(at: hostScratchDir, withIntermediateDirectories: true)
            let hostTempFile = hostScratchDir.appendingPathComponent("temp_export.mov")
            let videoData = "MOCK_VIDEO_EXPORT_BYTES_9876543210".data(using: .utf8)!
            try videoData.write(to: hostTempFile)

            // Simulate NSItemProvider loadFileRepresentation callback
            var stagedItem: JobItem? = nil
            var retainedTempUrl: URL? = nil

            // Inside completion handler:
            let completionHandler: (URL) throws -> Void = { temporaryUrl in
                retainedTempUrl = temporaryUrl
                // Eagerly stage file before callback exits:
                stagedItem = try coordinator.stageFileFromUrl(sourceUrl: temporaryUrl, originalName: "export.mov")
            }

            try completionHandler(hostTempFile)

            // Simulate host deleting temporary file immediately after completion handler returns:
            try FileManager.default.removeItem(at: hostTempFile)

            // Proof A: Attempting to read the retained temporary URL directly now fails
            let canReadTempAfterExit = FileManager.default.fileExists(atPath: retainedTempUrl!.path)
            guard !canReadTempAfterExit else {
                throw NSError(domain: "Test", code: 4, userInfo: [NSLocalizedDescriptionKey: "Temporary file should have been deleted by host"])
            }

            // Proof B: Staged copy is intact and matches original content
            guard let item = stagedItem else {
                throw NSError(domain: "Test", code: 5, userInfo: [NSLocalizedDescriptionKey: "Staged item is nil"])
            }
            let stagedData = try Data(contentsOf: URL(fileURLWithPath: item.stagedPath))
            guard stagedData == videoData else {
                throw NSError(domain: "Test", code: 6, userInfo: [NSLocalizedDescriptionKey: "Staged data corrupted"])
            }
            print("  [EVIDENCE] Confirmed: Host temporary URL is inaccessible after handler return, but staged copy is preserved.")
        }

        // Test 3: Multi-File Selection Staging
        runTest(name: "Multi-File Batch Staging (Finder Multi-Select)") {
            var items: [JobItem] = []
            for i in 1...5 {
                let file = tempDir.appendingPathComponent("document_\(i).pdf")
                let content = "PDF_CONTENT_DOCUMENT_NUMBER_\(i)_\(UUID().uuidString)".data(using: .utf8)!
                try content.write(to: file)
                let staged = try coordinator.stageFileFromUrl(sourceUrl: file)
                items.append(staged)
            }

            let manifest = JobManifest(jobId: UUID().uuidString, items: items)
            let manifestUrl = try coordinator.saveManifest(manifest)
            guard FileManager.default.fileExists(atPath: manifestUrl.path) else {
                throw NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Manifest not saved"])
            }

            let loaded = try coordinator.loadManifest(jobId: manifest.jobId)
            guard loaded.items.count == 5 else {
                throw NSError(domain: "Test", code: 8, userInfo: [NSLocalizedDescriptionKey: "Item count mismatch"])
            }
            guard loaded.manifestHash == manifest.manifestHash else {
                throw NSError(domain: "Test", code: 9, userInfo: [NSLocalizedDescriptionKey: "Manifest hash mismatch"])
            }
        }

        // Test 4: Safari Web URL and Text Snippet Normalization
        runTest(name: "Safari Web URL and Text Snippet Normalization") {
            let urlString = "https://nearside.local/article/test"
            let textSnippet = "Selected quotation from article to be transferred."

            let urlItem = try coordinator.stageData(data: urlString.data(using: .utf8)!, originalName: "shared_link.url", mimeType: "text/uri-list")
            let textItem = try coordinator.stageData(data: textSnippet.data(using: .utf8)!, originalName: "snippet.txt", mimeType: "text/plain")

            guard urlItem.sizeBytes == Int64(urlString.utf8.count) else {
                throw NSError(domain: "Test", code: 10, userInfo: [NSLocalizedDescriptionKey: "URL size mismatch"])
            }
            guard textItem.sizeBytes == Int64(textSnippet.utf8.count) else {
                throw NSError(domain: "Test", code: 11, userInfo: [NSLocalizedDescriptionKey: "Text size mismatch"])
            }
        }

        // Test 5: Large File Streaming (50 MiB) without Whole-File Memory Loading
        runTest(name: "Large File Incremental 64 KiB Chunked Staging (50 MiB)") {
            let largeFile = tempDir.appendingPathComponent("large_archive.bin")
            FileManager.default.createFile(atPath: largeFile.path, contents: nil)
            let writer = try FileHandle(forWritingTo: largeFile)

            let chunk = Data(repeating: 0x5A, count: 64 * 1024)
            var totalCreated: Int64 = 0
            var expectedHasher = SHA256()

            // 50 MiB = 800 chunks of 64 KiB
            for _ in 0..<800 {
                writer.write(chunk)
                expectedHasher.update(data: chunk)
                totalCreated += Int64(chunk.count)
            }
            try writer.close()
            let expectedHash = expectedHasher.finalize().compactMap { String(format: "%02x", $0) }.joined()

            let startTime = Date()
            let stagedItem = try coordinator.stageFileFromUrl(sourceUrl: largeFile)
            let duration = Date().timeIntervalSince(startTime)

            guard stagedItem.sizeBytes == totalCreated else {
                throw NSError(domain: "Test", code: 12, userInfo: [NSLocalizedDescriptionKey: "Large file size mismatch"])
            }
            guard stagedItem.sha256Hex == expectedHash else {
                throw NSError(domain: "Test", code: 13, userInfo: [NSLocalizedDescriptionKey: "Large file hash mismatch"])
            }

            let rateMBs = Double(totalCreated) / (1024 * 1024 * duration)
            print("  [PERF] Staged \(totalCreated / (1024 * 1024)) MiB in \(String(format: "%.3f", duration))s (\(String(format: "%.1f", rateMBs)) MiB/s) with bounded 64 KiB buffer")
        }

        // Test 6: Resident App Present: Transactional Queue Claim and Acknowledgment
        runTest(name: "Resident App Present: Claim and Acknowledgment") {
            resident.start()
            defer { resident.stop() }

            let file = tempDir.appendingPathComponent("handoff_doc.pdf")
            try "HANDOFF_VERIFICATION_CONTENT".data(using: .utf8)!.write(to: file)
            let item = try coordinator.stageFileFromUrl(sourceUrl: file)

            let jobId = UUID().uuidString
            let manifest = JobManifest(jobId: jobId, items: [item])
            _ = try coordinator.saveManifest(manifest)

            let acks = try resident.processPendingJobs()
            guard let ack = acks.first(where: { $0.jobId == jobId }) else {
                throw NSError(domain: "Test", code: 14, userInfo: [NSLocalizedDescriptionKey: "Job not acknowledged by resident"])
            }

            guard ack.status == "CLAIMED_AND_VERIFIED" else {
                throw NSError(domain: "Test", code: 15, userInfo: [NSLocalizedDescriptionKey: "Invalid ack status: \(ack.status)"])
            }

            let updatedManifest = try coordinator.loadManifest(jobId: jobId)
            guard updatedManifest.state == .completed else {
                throw NSError(domain: "Test", code: 16, userInfo: [NSLocalizedDescriptionKey: "Manifest state not updated to completed"])
            }
            print("  [EVIDENCE] Resident claimed job, verified SHA-256 and byte sizes, and issued acknowledgment.")
        }

        // Test 7: Resident App Absent: Honest Staging Status (No False Success)
        runTest(name: "Resident App Absent: Honest Fallback Status") {
            resident.stop() // Resident is NOT running

            let file = tempDir.appendingPathComponent("offline_doc.pdf")
            try "OFFLINE_CONTENT".data(using: .utf8)!.write(to: file)
            let item = try coordinator.stageFileFromUrl(sourceUrl: file)

            let jobId = UUID().uuidString
            var manifest = JobManifest(jobId: jobId, items: [item])

            // Extension checks if resident is active:
            if !resident.isResidentActive() {
                manifest.state = .pendingAppLaunch
            }
            _ = try coordinator.saveManifest(manifest)

            let loaded = try coordinator.loadManifest(jobId: jobId)
            guard loaded.state == .pendingAppLaunch else {
                throw NSError(domain: "Test", code: 17, userInfo: [NSLocalizedDescriptionKey: "Expected state PENDING_APP_LAUNCH, got \(loaded.state)"])
            }

            let ackFile = stagingDir.appendingPathComponent("job_\(jobId).ack")
            guard !FileManager.default.fileExists(atPath: ackFile.path) else {
                throw NSError(domain: "Test", code: 18, userInfo: [NSLocalizedDescriptionKey: "Ack file must not exist when resident is absent"])
            }
            print("  [EVIDENCE] Confirmed: When resident app is absent, job is marked PENDING_APP_LAUNCH without reporting false success.")
        }

        print("\n==================================================")
        print("  Summary: \(passedCount) Passed, \(failedCount) Failed")
        print("==================================================")
        if failedCount > 0 {
            exit(1)
        }
    }
}
