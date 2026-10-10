import Foundation

/// An untrusted document handoff, never an instruction to send. Only the host can
/// select a pinned recipient and confirm a transfer with its enrolled identity.
public struct MacShareRequest: Codable {
    public let version: Int
    public let id: String
    public let createdAt: Date
    public let filenames: [String]
}

public struct ImportedMacShare {
    public let request: MacShareRequest
    public let directory: URL
    public let files: [URL]
}

public enum MacShareHandoff {
    public static let requestName = "request.nearshare"
    public static let acknowledgmentName = "imported.json"
    public static let maximumAge: TimeInterval = 24 * 60 * 60

    public static func makeDirectory(in root: URL, id: String = UUID().uuidString) throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Copies while the provider/security-scoped resource is still valid. Never
    /// returns the inaccessible source as a fallback when copying fails.
    public static func stage(_ source: URL, in directory: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw failure(.storageReadFailed, "Only regular files can be shared. Select files inside the folder.")
        }
        let target = uniqueURL(name: source.lastPathComponent, in: directory)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: target)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError as NSError? {
            try? FileManager.default.removeItem(at: target)
            throw failure(.storageReadFailed, "Could not copy a shared file. Check access and try again.", cause: error)
        }
        return target
    }

    public static func stage(data: Data, name: String, in directory: URL) throws -> URL {
        guard isSafeFilename(name) else {
            throw failure(.protocolPathTraversalRejected, "Unsafe staged filename.")
        }
        let target = uniqueURL(name: name, in: directory)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    public static func writeRequest(files: [URL], in directory: URL, now: Date = Date()) throws -> URL {
        guard !files.isEmpty, files.count <= 256,
              files.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL }) else {
            throw failure(.protocolDecodeFailed, "The share request has no valid staged files.")
        }
        let request = MacShareRequest(version: 1, id: UUID().uuidString, createdAt: now,
            filenames: files.map(\.lastPathComponent))
        let url = directory.appendingPathComponent(requestName)
        try JSONEncoder().encode(request).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Import is completed before acknowledging, so extension termination cannot
    /// invalidate the host's files. Paths and symlinks are rejected before reading.
    public static func importRequest(at url: URL, into root: URL, now: Date = Date()) throws -> ImportedMacShare {
        guard url.isFileURL, url.lastPathComponent == requestName else {
            throw failure(.protocolDecodeFailed, "This is not a Nearside share request.")
        }
        try requireRegularFile(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 256 * 1024 else {
            throw failure(.protocolDecodeFailed, "The share request is too large or empty.")
        }
        let request = try JSONDecoder().decode(MacShareRequest.self, from: Data(contentsOf: url))
        guard request.version == 1, UUID(uuidString: request.id) != nil,
              now.timeIntervalSince(request.createdAt) >= -60,
              now.timeIntervalSince(request.createdAt) <= maximumAge,
              !request.filenames.isEmpty, request.filenames.count <= 256,
              Set(request.filenames).count == request.filenames.count else {
            throw failure(.protocolDecodeFailed, "The share request is invalid or expired.", id: request.id)
        }
        let sourceDirectory = url.deletingLastPathComponent()
        guard sourceDirectory.standardizedFileURL == sourceDirectory.resolvingSymlinksInPath().standardizedFileURL else {
            throw failure(.protocolPathTraversalRejected, "Share request directory is a symbolic link.", id: request.id)
        }
        let sources = try request.filenames.map { name -> URL in
            guard isSafeFilename(name),
                  name != requestName, name != acknowledgmentName else {
                throw failure(.protocolPathTraversalRejected, "Unsafe path in share request.", id: request.id)
            }
            let source = sourceDirectory.appendingPathComponent(name)
            try requireRegularFile(source)
            return source
        }
        let directory = try makeDirectory(in: root)
        do {
            let files = try sources.map { try stage($0, in: directory) }
            return ImportedMacShare(request: request, directory: directory, files: files)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public static func acknowledge(_ imported: ImportedMacShare, requestURL: URL) throws {
        let url = requestURL.deletingLastPathComponent().appendingPathComponent(acknowledgmentName)
        try JSONEncoder().encode(["id": imported.request.id]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func isAcknowledged(requestURL: URL) -> Bool {
        guard let request = try? JSONDecoder().decode(MacShareRequest.self, from: Data(contentsOf: requestURL)),
              let acknowledgment = try? JSONDecoder().decode([String: String].self,
                from: Data(contentsOf: requestURL.deletingLastPathComponent().appendingPathComponent(acknowledgmentName))) else {
            return false
        }
        return acknowledgment["id"] == request.id
    }

    public static func removeExpiredRequests(in root: URL, now: Date = Date(), excluding: Set<URL> = []) {
        guard let children = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for directory in children {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  !excluding.contains(directory.standardizedFileURL),
                  let values = try? directory.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let created = values.creationDate, now.timeIntervalSince(created) > maximumAge else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    public static func failure(_ code: NearsideErrorCode, _ message: String,
                               id: String? = nil, cause: Error? = nil) -> NearsideError {
        // File-system NSError.userInfo can contain a private path. Preserve the
        // native domain/code without logging userInfo or the shared file's name.
        let safeCause = cause.map { error -> NSError in
            let native = error as NSError
            return NSError(domain: native.domain, code: native.code)
        }
        return NearsideError(code: code, operation: "macShareHandoff", message: message,
            underlyingError: safeCause, correlationId: id)
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw failure(.protocolPathTraversalRejected, "Share request contains a symbolic link or unsupported file.")
        }
    }

    private static func isSafeFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func uniqueURL(name: String, in directory: URL) -> URL {
        let safeName = name.isEmpty ? "shared_file" : name
        let base = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(safeName)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) || candidate.lastPathComponent == requestName || candidate.lastPathComponent == acknowledgmentName {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}
