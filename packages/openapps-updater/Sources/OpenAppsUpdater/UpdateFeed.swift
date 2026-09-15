import CryptoKit
import Foundation

/// One release announced by the update feed (RELEASES.md, "Update feed"):
/// a Sparkle-format appcast item with every field the contract requires.
public struct UpdateFeedItem: Equatable, Sendable {
    public var app: String
    public var channel: String
    public var version: UpdateVersion
    public var build: Int
    public var minimumMacOS: OperatingSystemVersion
    public var publishedAt: String
    public var notes: String
    public var url: URL
    public var length: Int
    public var sha256: String
    /// Ed25519 signature of the zip, base64.
    public var signature: String

    public init(app: String, channel: String, version: UpdateVersion, build: Int, minimumMacOS: OperatingSystemVersion,
                publishedAt: String, notes: String, url: URL, length: Int, sha256: String, signature: String) {
        self.app = app
        self.channel = channel
        self.version = version
        self.build = build
        self.minimumMacOS = minimumMacOS
        self.publishedAt = publishedAt
        self.notes = notes
        self.url = url
        self.length = length
        self.sha256 = sha256
        self.signature = signature
    }
}

public enum UpdateFeedError: Error, Equatable, LocalizedError {
    case unsigned
    case badSignature
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unsigned: "The update feed is not signed."
        case .badSignature: "The update feed's signature does not match the update key."
        case .malformed(let what): "The update feed is malformed: \(what)."
        }
    }
}

/// The signed appcast. Nothing in it is trusted before the feed signature
/// verifies with the public key compiled into the app.
public struct UpdateFeed: Equatable, Sendable {
    public var items: [UpdateFeedItem]

    /// Verifies the feed signature Sparkle's `sign_update` (and the apps'
    /// signing scripts) append — `<!-- sparkle-signatures: edSignature: …
    /// length: … -->`, an Ed25519 signature over the first `length` bytes —
    /// then parses the items from exactly those bytes.
    public static func verifiedAndParsed(_ data: Data, publicKey: String) throws -> UpdateFeed {
        guard let (signature, length) = trailingSignature(in: data) else { throw UpdateFeedError.unsigned }
        // The trailer is untrusted until verified: its length must describe a real prefix.
        guard length >= 0, length <= data.count else { throw UpdateFeedError.badSignature }
        let signed = Data(data.prefix(length))
        // The trailer must be the signature comment itself: nothing may hide after the signed bytes.
        let trailer = String(decoding: data.dropFirst(length), as: UTF8.self)
        guard trailer.contains("sparkle-signatures:"), !trailer.contains("<item"), !trailer.contains("<enclosure") else {
            throw UpdateFeedError.badSignature
        }
        guard UpdateSignature.verify(signed, signature: signature, publicKey: publicKey) else {
            throw UpdateFeedError.badSignature
        }
        return try parse(signed)
    }

    /// The signature comment at the end of a signed feed.
    static func trailingSignature(in data: Data) -> (signature: String, length: Int)? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<!-- sparkle-signatures:", options: .backwards) else { return nil }
        var signature: String?
        var length: Int?
        for line in text[start.lowerBound...].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("edSignature:") {
                signature = trimmed.dropFirst("edSignature:".count).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("length:") {
                length = Int(trimmed.dropFirst("length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let signature, let length else { return nil }
        return (signature, length)
    }

    /// Parses the unsigned XML. Every field is required; an item missing one
    /// makes the feed malformed rather than silently offering less.
    public static func parse(_ data: Data) throws -> UpdateFeed {
        let parser = AppcastParser()
        try parser.parse(data)
        return UpdateFeed(items: parser.items)
    }
}

/// Ed25519 (Sparkle EdDSA) verification with the app's public update key.
public enum UpdateSignature {
    public static func verify(_ data: Data, signature: String, publicKey: String) -> Bool {
        guard let keyBytes = Data(base64Encoded: publicKey), keyBytes.count == 32,
              let signatureBytes = Data(base64Encoded: signature), signatureBytes.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else { return false }
        return key.isValidSignature(signatureBytes, for: data)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The SHA-256 of a file, streamed.
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class AppcastParser: NSObject, XMLParserDelegate {
    private(set) var items: [UpdateFeedItem] = []
    private var current: [String: String]?
    private var enclosure: [String: String]?
    private var text = ""
    private var failure: UpdateFeedError?

    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        if let failure { throw failure }
        guard ok else { throw UpdateFeedError.malformed(parser.parserError?.localizedDescription ?? "not XML") }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        switch elementName {
        case "item":
            guard current == nil else { return fail("nested item", parser) }
            current = [:]
            enclosure = nil
        case "enclosure":
            guard current != nil else { return fail("enclosure outside an item", parser) }
            guard enclosure == nil else { return fail("more than one enclosure", parser) }
            enclosure = attributes
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "item" {
            guard let fields = current else { return }
            current = nil
            do {
                items.append(try Self.item(fields, enclosure: enclosure))
            } catch let error as UpdateFeedError {
                fail(error, parser)
            } catch {
                fail("item", parser)
            }
            return
        }
        guard current != nil, elementName != "enclosure" else { return }
        current?[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fail(_ what: String, _ parser: XMLParser) {
        fail(.malformed(what), parser)
    }

    private func fail(_ error: UpdateFeedError, _ parser: XMLParser) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    private static func item(_ fields: [String: String], enclosure: [String: String]?) throws -> UpdateFeedItem {
        func field(_ name: String) throws -> String {
            guard let value = fields[name], !value.isEmpty else { throw UpdateFeedError.malformed("item without \(name)") }
            return value
        }
        guard let enclosure else { throw UpdateFeedError.malformed("item without an enclosure") }
        func attribute(_ name: String) throws -> String {
            guard let value = enclosure[name], !value.isEmpty else { throw UpdateFeedError.malformed("enclosure without \(name)") }
            return value
        }
        guard let version = UpdateVersion(try field("sparkle:shortVersionString")) else { throw UpdateFeedError.malformed("version") }
        guard let build = Int(try field("sparkle:version")), build > 0 else { throw UpdateFeedError.malformed("build") }
        guard let minimum = OperatingSystemVersion(parsing: try field("sparkle:minimumSystemVersion")) else { throw UpdateFeedError.malformed("minimum macOS") }
        guard let url = URL(string: try attribute("url")), url.host != nil else { throw UpdateFeedError.malformed("url") }
        guard let length = Int(try attribute("length")), length > 0 else { throw UpdateFeedError.malformed("length") }
        let sha256 = try field("openapps:sha256")
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw UpdateFeedError.malformed("sha256") }
        return UpdateFeedItem(
            app: try field("openapps:app"),
            channel: try field("openapps:channel"),
            version: version,
            build: build,
            minimumMacOS: minimum,
            publishedAt: try field("openapps:publishedAt"),
            notes: fields["description"] ?? "",
            url: url,
            length: length,
            sha256: sha256,
            signature: try attribute("sparkle:edSignature")
        )
    }
}
