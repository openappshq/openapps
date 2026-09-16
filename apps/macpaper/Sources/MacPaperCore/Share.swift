import Compression
import Foundation

/// `macpaper://s/<code>`: the whole document as a link. The code is the
/// document's JSON, deflated (zlib) and base64url-encoded — every knob, the
/// seed, the finishes, the pair and the composition, never an image. A
/// pixelize or dither document carries its image reference; the receiver
/// has no such import, so it renders the background and says so.
public enum ShareCode {
    public static let scheme = "macpaper"
    public static let host = "s"
    /// A code longer than this is refused before inflating.
    public static let maxCodeLength = 8192
    /// A document JSON longer than this is refused after inflating.
    public static let maxDocumentBytes = 64 * 1024

    public enum DecodeError: Error, LocalizedError, Equatable {
        case notALink
        case tooLong
        case corrupt

        public var errorDescription: String? {
            switch self {
            case .notALink: "Not a macPaper link."
            case .tooLong: "The link is too long to be a macPaper document."
            case .corrupt: "The link does not hold a macPaper document."
            }
        }
    }

    public static func encode(_ wallpaper: Wallpaper) throws -> String {
        let json = try wallpaper.jsonData()
        let deflated = compress(json)
        return base64url(deflated)
    }

    public static func url(for wallpaper: Wallpaper) throws -> URL {
        let code = try encode(wallpaper)
        guard let url = URL(string: "\(scheme)://\(host)/\(code)") else { throw DecodeError.corrupt }
        return url
    }

    public static func decode(_ code: String) throws -> Wallpaper {
        guard code.count <= maxCodeLength, let deflated = fromBase64url(code) else { throw DecodeError.tooLong }
        guard let json = decompress(deflated, limit: maxDocumentBytes) else { throw DecodeError.corrupt }
        do {
            return try Wallpaper.fromJSON(json)
        } catch {
            throw DecodeError.corrupt
        }
    }

    /// The document in a `macpaper://s/<code>` link; other links throw `notALink`.
    public static func decode(url: URL) throws -> Wallpaper {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { throw DecodeError.notALink }
        let code = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !code.isEmpty else { throw DecodeError.notALink }
        return try decode(code)
    }

    // MARK: - Bytes

    static func compress(_ data: Data) -> Data {
        data.withUnsafeBytes { source -> Data in
            let capacity = max(64, data.count + data.count / 2 + 64)
            var out = [UInt8](repeating: 0, count: capacity)
            let written = compression_encode_buffer(&out, capacity, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            return Data(out.prefix(written))
        }
    }

    static func decompress(_ data: Data, limit: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        return data.withUnsafeBytes { source -> Data? in
            var out = [UInt8](repeating: 0, count: limit + 1)
            let written = compression_decode_buffer(&out, limit + 1, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            guard written > 0, written <= limit else { return nil }
            return Data(out.prefix(written))
        }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64url(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

/// Documents shuffle must never pick: "Never show this". Kept as the
/// documents' JSON hashes in `never.json`; the documents themselves are
/// not kept, so a favorite that was never-showed is simply gone.
public final class BlocklistStore: @unchecked Sendable {
    private struct File: Codable, Sendable {
        var version = 1
        var hashes: [String]
    }

    private let file: JSONFile<File>
    private let lock = NSLock()
    private var hashes: Set<String>

    public init(fileURL: URL) {
        file = JSONFile(url: fileURL)
        hashes = Set((try? file.load())?.hashes ?? [])
    }

    public var count: Int { lock.withLock { hashes.count } }

    public static func key(for wallpaper: Wallpaper) -> String {
        (try? wallpaper.jsonData())?.sha256Hex ?? ""
    }

    public func contains(_ wallpaper: Wallpaper) -> Bool {
        let key = Self.key(for: wallpaper)
        return lock.withLock { hashes.contains(key) }
    }

    public func add(_ wallpaper: Wallpaper) throws {
        let key = Self.key(for: wallpaper)
        try lock.withLock {
            var next = hashes
            next.insert(key)
            try file.save(File(hashes: next.sorted()))
            hashes = next
        }
    }

    public func removeAll() throws {
        try lock.withLock {
            try file.save(File(hashes: []))
            hashes = []
        }
    }

    /// The documents of `candidates` that are not blocked.
    public func filter(_ candidates: [Wallpaper]) -> [Wallpaper] {
        lock.withLock { candidates.filter { !hashes.contains(Self.key(for: $0)) } }
    }
}
