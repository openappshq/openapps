import CryptoKit
import Foundation

/// The file primitives the store's transactions are built on. Every
/// check is made through a file descriptor (`O_NOFOLLOW`, `fstat`) so the
/// entry inspected is the entry acted on; content identity is a streaming
/// SHA-256 over the **whole** file whatever the read cap; replacements are
/// an exclusive create or a `renamex_np(RENAME_SWAP)` whose displaced file
/// is checked afterwards; the only removal is `unlinkat` of a verified
/// file. Nothing here knows notes.
nonisolated enum NoteFile {
    /// What identifies a file's contents and the inode holding them.
    struct Identity: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: Int
        var modified: Date
        /// SHA-256 over every byte of the file.
        var hash: Data

        var sameInode: (dev_t, ino_t) { (device, inode) }
    }

    enum Entry {
        case absent
        case notRegular
        /// Open for reading: the caller closes it.
        case file(fd: Int32, stat: stat)
    }

    struct Contents {
        var identity: Identity
        /// The first `cap` bytes, decoded; nil when they are not UTF-8.
        var text: String?
        /// The file was longer than `cap`.
        var truncated: Bool
    }

    enum Failure: Error {
        case posix(Int32, String)
        case exists
    }

    static func error(_ what: String) -> Failure { .posix(errno, what) }

    // MARK: - Reading

    /// Opens the entry at the path without following a symbolic link.
    static func open(_ url: URL) -> Entry {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .absent
            default: return .notRegular
            }
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            return .notRegular
        }
        return .file(fd: fd, stat: info)
    }

    /// Streams the whole file through SHA-256, keeping the first `cap`
    /// bytes as text. Reads to EOF, not to the size the stat reported.
    static func read(fd: Int32, stat info: stat, cap: Int) -> Contents? {
        var hasher = SHA256()
        var kept = Data()
        var total = 0
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        lseek(fd, 0, SEEK_SET)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, chunkSize) }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            chunk.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            if kept.count < cap {
                kept.append(contentsOf: chunk[0..<min(count, cap - kept.count)])
            }
            total += count
        }
        let identity = Identity(device: info.st_dev, inode: info.st_ino, size: total, modified: Self.date(info.st_mtimespec), hash: Data(hasher.finalize()))
        let truncated = total > cap
        return Contents(identity: identity, text: decode(kept, truncated: truncated), truncated: truncated)
    }

    static func close(_ fd: Int32) {
        Darwin.close(fd)
    }

    static func date(_ spec: timespec) -> Date {
        Date(timeIntervalSince1970: Double(spec.tv_sec) + Double(spec.tv_nsec) / 1_000_000_000)
    }

    /// UTF-8, or nil; a truncated read drops a split character at the end.
    static func decode(_ data: Data, truncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard truncated else { return nil }
        var bytes = data
        for _ in 0..<3 where !bytes.isEmpty {
            bytes.removeLast()
            if let text = String(data: bytes, encoding: .utf8) { return text }
        }
        return nil
    }

    static func hash(_ contents: String) -> Data {
        hash(Data(contents.utf8))
    }

    static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // MARK: - Writing

    /// Creates the file, refusing an existing one (`Failure.exists`), and
    /// writes the contents through the new descriptor.
    static func createExclusively(_ url: URL, contents: String) throws -> Identity {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            if errno == EEXIST { throw Failure.exists }
            throw error("create \(url.lastPathComponent)")
        }
        defer { Darwin.close(fd) }
        return try writeAll(fd, contents: contents, name: url.lastPathComponent)
    }

    /// A hidden temporary file beside the target, exclusively created, with
    /// the contents written; the caller swaps or removes it.
    static func writeTemporary(beside url: URL, contents: String) throws -> (url: URL, identity: Identity) {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: false)
        let identity = try createExclusively(temporary, contents: contents)
        return (temporary, identity)
    }

    private static func writeAll(_ fd: Int32, contents: String, name: String) throws -> Identity {
        let data = Data(contents.utf8)
        var offset = 0
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            while offset < data.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw error("write \(name)")
                }
                offset += written
            }
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw error("stat \(name)") }
        return Identity(device: info.st_dev, inode: info.st_ino, size: data.count, modified: date(info.st_mtimespec), hash: hash(contents))
    }

    /// Exchanges the two paths in one step; both must exist.
    static func swap(_ a: URL, _ b: URL) throws {
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else { throw error("swap \(a.lastPathComponent)") }
    }

    /// Renames without ever replacing an existing destination.
    static func moveExclusively(_ from: URL, to: URL) throws {
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw Failure.exists }
            throw error("move \(from.lastPathComponent)")
        }
    }

    /// The identity of the entry at a path if it is a regular file.
    static func identity(at url: URL) -> (dev_t, ino_t)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return (info.st_dev, info.st_ino)
    }

    /// Removes the name from its directory, relative to the directory's
    /// own descriptor and never recursively (`unlinkat` without
    /// `AT_REMOVEDIR` refuses a directory). Returns whether the file the
    /// caller holds open is the one that was unlinked (its link count
    /// dropped to zero).
    static func unlink(_ url: URL, verified fd: Int32) throws -> Bool {
        let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw error("open folder") }
        defer { Darwin.close(directory) }
        guard unlinkat(directory, url.lastPathComponent, 0) == 0 else { throw error("unlink \(url.lastPathComponent)") }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return false }
        return info.st_nlink == 0
    }

    /// Removes a temporary file of ours by name; nothing else ever uses
    /// these names.
    static func removeTemporary(_ url: URL) {
        Darwin.unlink(url.path)
    }
}
