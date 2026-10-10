import Foundation
import CryptoKit
import Security

@main
struct MacShareHandoffTests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("NearsideShareTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = root.appendingPathComponent("provider")
        let extensionRoot = root.appendingPathComponent("extension")
        let hostRoot = root.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        let source = provider.appendingPathComponent("photo.txt")
        try Data("first".utf8).write(to: source)
        let staging = try MacShareHandoff.makeDirectory(in: extensionRoot)
        let first = try MacShareHandoff.stage(source, in: staging)
        try Data("second".utf8).write(to: source)
        let second = try MacShareHandoff.stage(source, in: staging)
        check(first != second, "Duplicate provider filenames remain separate files")
        try FileManager.default.removeItem(at: provider)
        check(try Data(contentsOf: first) == Data("first".utf8), "Staging survives provider callback/lifetime end")
        let requestURL = try MacShareHandoff.writeRequest(files: [first, second], in: staging)
        check(!MacShareHandoff.isAcknowledged(requestURL: requestURL), "Launch alone does not acknowledge file ownership")
        let imported = try MacShareHandoff.importRequest(at: requestURL, into: hostRoot)
        try MacShareHandoff.acknowledge(imported, requestURL: requestURL)
        check(MacShareHandoff.isAcknowledged(requestURL: requestURL), "Host acknowledges only after copying all files")
        try FileManager.default.removeItem(at: staging)
        check(try Data(contentsOf: imported.files[0]) == Data("first".utf8), "Host copy survives extension cleanup")
        check(try Data(contentsOf: imported.files[1]) == Data("second".utf8), "Host preserves every staged file")
        let mode = try FileManager.default.attributesOfItem(atPath: imported.directory.path)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o700, "Private staging directory permissions")

        let invalidStaging = try MacShareHandoff.makeDirectory(in: extensionRoot)
        let regular = try MacShareHandoff.stage(data: Data("payload".utf8), name: "safe.txt", in: invalidStaging)
        let invalidURL = invalidStaging.appendingPathComponent(MacShareHandoff.requestName)
        func write(_ names: [String], age: TimeInterval = 0, version: Int = 1) throws {
            let request = MacShareRequest(version: version, id: UUID().uuidString,
                createdAt: Date().addingTimeInterval(-age), filenames: names)
            try JSONEncoder().encode(request).write(to: invalidURL)
        }
        try write(["../outside.txt"])
        rejects(.protocolPathTraversalRejected, "Reject traversal before importing") {
            _ = try MacShareHandoff.importRequest(at: invalidURL, into: hostRoot)
        }
        try write(["bad\u{0}name.txt"])
        rejects(.protocolPathTraversalRejected, "Reject control characters in request paths") {
            _ = try MacShareHandoff.importRequest(at: invalidURL, into: hostRoot)
        }
        rejects(.protocolPathTraversalRejected, "Generated content cannot escape staging directory") {
            _ = try MacShareHandoff.stage(data: Data(), name: "../escape.txt", in: invalidStaging)
        }
        let link = invalidStaging.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        try write(["link.txt"])
        rejects(.protocolPathTraversalRejected, "Reject symbolic-link files") {
            _ = try MacShareHandoff.importRequest(at: invalidURL, into: hostRoot)
        }
        try write(["safe.txt"], age: MacShareHandoff.maximumAge + 1)
        rejects(.protocolDecodeFailed, "Reject expired handoffs") {
            _ = try MacShareHandoff.importRequest(at: invalidURL, into: hostRoot)
        }
        try write(["safe.txt", "safe.txt"])
        rejects(.protocolDecodeFailed, "Reject duplicate file references") {
            _ = try MacShareHandoff.importRequest(at: invalidURL, into: hostRoot)
        }
        try write(["safe.txt"], version: 2)
        rejects(.protocolDecodeFailed, "Reject unsupported handoff versions") {
            _ = try MacShareHandoff.importRequest(at: invalidURL, into: hostRoot)
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: hostRoot.path).count
        try write(["safe.txt", "missing.txt"])
        do {
            _ = try MacShareHandoff.importRequest(at: invalidURL, into: hostRoot)
            fatalError("Missing shared file was accepted")
        } catch { }
        check(try FileManager.default.contentsOfDirectory(atPath: hostRoot.path).count == before,
            "Partial import failure leaves no host files")
        do {
            _ = try MacShareHandoff.stage(root.appendingPathComponent("missing"), in: invalidStaging)
            fatalError("Inaccessible source was returned as a fallback")
        } catch { }
        let native = NSError(domain: NSCocoaErrorDomain, code: 257,
            userInfo: [NSFilePathErrorKey: "/private/secret/file.txt"])
        let diagnostic = MacShareHandoff.failure(.storageReadFailed, "Shared item unavailable", cause: native)
        check(!diagnostic.description.contains("secret"), "Diagnostics preserve native code without private file paths")
        MacShareHandoff.removeExpiredRequests(in: extensionRoot, now: Date().addingTimeInterval(MacShareHandoff.maximumAge + 60),
            excluding: [invalidStaging.standardizedFileURL])
        check(FileManager.default.fileExists(atPath: invalidStaging.path), "Active handoff directories are retained even after expiry")
        MacShareHandoff.removeExpiredRequests(in: extensionRoot, now: Date().addingTimeInterval(MacShareHandoff.maximumAge + 60))
        check(!FileManager.default.fileExists(atPath: invalidStaging.path), "Abandoned extension files expire safely")
        try testIdentityPersistence()
        print("All macOS share handoff tests passed")
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }
    static func rejects(_ code: NearsideErrorCode, _ message: String, body: () throws -> Void) {
        do { try body(); fatalError(message) }
        catch let error as NearsideError { check(error.code == code, message) }
        catch { fatalError("Unexpected error: \(error)") }
    }

    static func testIdentityPersistence() throws {
        let existing = P256.Signing.PrivateKey()
        let identity = try DeviceIdentity.loadOrCreatePersistent(readKey: { (errSecSuccess, existing.rawRepresentation) },
            addKey: { _ in fatalError("Existing identity must not be overwritten") })
        check(identity.publicIdentity == DeviceIdentity(privateKey: existing).publicIdentity,
            "Host reloads the exact enrolled identity")
        var writes = 0
        rejects(.trustStorageFailed, "Denied Keychain access fails closed without replacing the identity") {
            _ = try DeviceIdentity.loadOrCreatePersistent(readKey: { (errSecAuthFailed, nil) },
                addKey: { _ in writes += 1; return errSecSuccess })
        }
        check(writes == 0, "Keychain read failures never create or delete keys")
        rejects(.trustStorageFailed, "Invalid stored keys are preserved rather than replaced") {
            _ = try DeviceIdentity.loadOrCreatePersistent(readKey: { (errSecSuccess, Data([1, 2])) },
                addKey: { _ in fatalError("Corrupt key must not be overwritten") })
        }
        rejects(.trustStorageFailed, "Failed key persistence never returns an ephemeral identity") {
            _ = try DeviceIdentity.loadOrCreatePersistent(readKey: { (errSecItemNotFound, nil) },
                addKey: { _ in errSecInteractionNotAllowed })
        }
        var persisted: Data?
        let created = try DeviceIdentity.loadOrCreatePersistent(readKey: { (errSecItemNotFound, nil) },
            addKey: { persisted = $0; return errSecSuccess })
        check(persisted == created.privateKey.rawRepresentation, "New identity is returned only after persistence succeeds")
        var reads = 0
        let raced = try DeviceIdentity.loadOrCreatePersistent(readKey: {
            reads += 1
            return reads == 1 ? (errSecItemNotFound, nil) : (errSecSuccess, existing.rawRepresentation)
        }, addKey: { _ in errSecDuplicateItem })
        check(raced.publicIdentity == identity.publicIdentity, "Concurrent creation reloads the winning persisted key")
    }
}
