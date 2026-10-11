import CryptoKit
import Foundation

/// Owns every file the app writes. Layout:
///
///     Application Support/WorkPhotos/
///         Database/          SwiftData store
///         Originals/         original photos, never modified (persistent)
///         Reports/<id>/      generated PDFs + snapshot.json (persistent)
///         Logos/             logos for the profile and brand presets (persistent)
///         Staging/           temporary files of captures/imports in progress
///     Caches/WorkPhotos/     thumbnails and render cache (rebuildable)
///     tmp/WorkPhotos/        exports, previews, backups being written
///
/// Database records store only relative paths. Files in use by a report or backup can be
/// "leased": deleting a leased file is deferred until the lease ends.
final class FileStore: @unchecked Sendable {
    enum Folder: String, CaseIterable {
        case originals = "Originals"
        case reports = "Reports"
        case logos = "Logos"
        case staging = "Staging"
        case database = "Database"
    }

    let root: URL
    let cachesRoot: URL
    let tempRoot: URL

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var leases: [String: Int] = [:]
    private var deferredDeletes: Set<String> = []

    init(root: URL, cachesRoot: URL, tempRoot: URL) {
        self.root = root.standardizedFileURL
        self.cachesRoot = cachesRoot.standardizedFileURL
        self.tempRoot = tempRoot.standardizedFileURL
    }

    static func live() -> FileStore {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return FileStore(root: support.appendingPathComponent("WorkPhotos", isDirectory: true),
                         cachesRoot: caches.appendingPathComponent("WorkPhotos", isDirectory: true),
                         tempRoot: fm.temporaryDirectory.appendingPathComponent("WorkPhotos", isDirectory: true))
    }

    // MARK: Directories

    func prepareDirectories() throws {
        for folder in Folder.allCases {
            try createDirectory(root.appendingPathComponent(folder.rawValue, isDirectory: true))
        }
        try createDirectory(thumbnailsDirectory)
        try createDirectory(renderCacheDirectory)
        try createDirectory(tempRoot)
    }

    private func createDirectory(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
    }

    func directory(_ folder: Folder) -> URL {
        root.appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    var databaseURL: URL { directory(.database).appendingPathComponent("WorkPhotos.store") }
    var thumbnailsDirectory: URL { cachesRoot.appendingPathComponent("Thumbnails", isDirectory: true) }
    var renderCacheDirectory: URL { cachesRoot.appendingPathComponent("RenderCache", isDirectory: true) }

    // MARK: Paths

    /// Resolves a relative path and refuses anything that could escape the data directory.
    func url(forRelative relativePath: String) throws -> URL {
        guard Self.isSafeRelativePath(relativePath) else { throw AppError(.backupUnsafePath) }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw AppError(.backupUnsafePath) }
        return url
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains("\u{0}") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components {
            if component.isEmpty || component == "." || component == ".." { return false }
            if component.contains(":") { return false }
        }
        return true
    }

    static func originalRelativePath(photoID: UUID, format: ImageFormat) -> String {
        "\(Folder.originals.rawValue)/\(photoID.uuidString).\(format.fileExtension)"
    }

    static func reportDirectoryRelativePath(reportID: UUID) -> String {
        "\(Folder.reports.rawValue)/\(reportID.uuidString)"
    }

    static func logoRelativePath(id: UUID) -> String {
        "\(Folder.logos.rawValue)/\(id.uuidString).png"
    }

    func thumbnailURL(for photoID: UUID) -> URL {
        thumbnailsDirectory.appendingPathComponent("\(photoID.uuidString).jpg")
    }

    func newStagingURL(fileExtension: String) -> URL {
        directory(.staging).appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
    }

    func newTempDirectory(named name: String = UUID().uuidString) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try? fileManager.removeItem(at: url)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Writing

    /// Writes via a temporary file and an atomic rename.
    func writeAtomically(_ data: Data, toRelative relativePath: String) throws {
        let destination = try url(forRelative: relativePath)
        try createDirectory(destination.deletingLastPathComponent())
        try ensureSpace(for: Int64(data.count))
        do {
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw AppError.wrap(error, default: .fileWriteFailed)
        }
    }

    /// Moves a finished file (on the same volume) into the store with an atomic rename.
    func moveIntoStore(from source: URL, toRelative relativePath: String) throws {
        let destination = try url(forRelative: relativePath)
        try createDirectory(destination.deletingLastPathComponent())
        guard !fileManager.fileExists(atPath: destination.path) else { throw AppError(.fileWriteFailed) }
        do {
            try fileManager.moveItem(at: source, to: destination)
            try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                           ofItemAtPath: destination.path)
        } catch {
            throw AppError.wrap(error, default: .fileWriteFailed)
        }
    }

    /// Copies a file into the store (copy to staging, then atomic rename).
    func copyIntoStore(from source: URL, toRelative relativePath: String) throws {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        try ensureSpace(for: size)
        let staged = newStagingURL(fileExtension: "part")
        do {
            try fileManager.copyItem(at: source, to: staged)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw AppError.wrap(error, default: .fileWriteFailed)
        }
        do {
            try moveIntoStore(from: staged, toRelative: relativePath)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    func fileExists(relative relativePath: String) -> Bool {
        guard let url = try? url(forRelative: relativePath) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func fileSize(relative relativePath: String) -> Int64? {
        guard let url = try? url(forRelative: relativePath),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    // MARK: Deleting (lease-aware)

    /// Deletes a file or directory. If it is leased by a running report/backup, deletion waits for the lease to end.
    func removeItem(relative relativePath: String) {
        lock.lock()
        if leases[relativePath, default: 0] > 0 {
            deferredDeletes.insert(relativePath)
            lock.unlock()
            return
        }
        lock.unlock()
        if let url = try? url(forRelative: relativePath) {
            try? fileManager.removeItem(at: url)
        }
    }

    func removeThumbnail(for photoID: UUID) {
        try? fileManager.removeItem(at: thumbnailURL(for: photoID))
    }

    struct Lease: Hashable {
        fileprivate let id = UUID()
        fileprivate let paths: [String]
    }

    /// Keeps files from being deleted while a long operation reads them.
    func lease(_ relativePaths: [String]) -> Lease {
        lock.lock()
        defer { lock.unlock() }
        for path in relativePaths { leases[path, default: 0] += 1 }
        return Lease(paths: relativePaths)
    }

    func endLease(_ lease: Lease) {
        lock.lock()
        var toDelete: [String] = []
        for path in lease.paths {
            let count = leases[path, default: 0] - 1
            if count <= 0 {
                leases[path] = nil
                if deferredDeletes.remove(path) != nil { toDelete.append(path) }
            } else {
                leases[path] = count
            }
        }
        lock.unlock()
        for path in toDelete { removeItem(relative: path) }
    }

    func isLeased(_ relativePath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return leases[relativePath, default: 0] > 0
    }

    // MARK: Space

    func availableCapacity() -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Keeps a safety margin so the database and the system can still write.
    static let safetyMargin: Int64 = 50 * 1024 * 1024

    func ensureSpace(for bytes: Int64) throws {
        guard let available = availableCapacity() else { return }
        if available < bytes + Self.safetyMargin {
            throw AppError(.insufficientStorage)
        }
    }

    func size(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            }
        }
        return total
    }

    func size(of folder: Folder) -> Int64 { size(of: directory(folder)) }
    var cacheSize: Int64 { size(of: cachesRoot) + size(of: tempRoot) }

    /// Lists files of a folder as relative paths (e.g. "Originals/<id>.heic").
    func relativeFiles(in folder: Folder) -> [String] {
        let base = directory(folder)
        guard let names = try? fileManager.contentsOfDirectory(atPath: base.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.map { "\(folder.rawValue)/\($0)" }
    }

    // MARK: Cleanup

    /// Clears thumbnails, render cache and temporary exports. Never touches Originals, Reports or Logos.
    func clearCaches() {
        try? fileManager.removeItem(at: cachesRoot)
        if let names = try? fileManager.contentsOfDirectory(atPath: tempRoot.path) {
            for name in names { try? fileManager.removeItem(at: tempRoot.appendingPathComponent(name)) }
        }
        try? prepareDirectories()
    }

    /// Removes leftover files of interrupted captures/imports.
    func clearStaging() {
        let staging = directory(.staging)
        if let names = try? fileManager.contentsOfDirectory(atPath: staging.path) {
            for name in names { try? fileManager.removeItem(at: staging.appendingPathComponent(name)) }
        }
    }

    /// "Delete all local data": removes every file this app created (database is removed by the caller).
    func deleteAllUserFiles() {
        for folder in Folder.allCases where folder != .database {
            try? fileManager.removeItem(at: directory(folder))
        }
        try? fileManager.removeItem(at: cachesRoot)
        try? fileManager.removeItem(at: tempRoot)
        try? prepareDirectories()
    }

    // MARK: Hashing

    /// Streaming SHA-256 (hex). Used for duplicate hints and backup integrity — not proof of authenticity.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ByteFormatting {
    static func string(_ bytes: Int64) -> String {
        bytes.formatted(ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false,
                                             includesActualByteCount: false, locale: AppLanguage.current.formattingLocale))
    }
}
