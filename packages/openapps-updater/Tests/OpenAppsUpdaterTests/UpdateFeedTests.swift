import CryptoKit
import Foundation
import OpenAppsUpdater
import Testing

/// A signed feed as the apps' make-appcast scripts write it, with a throwaway key.
struct SignedFeedFixture {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    func sign(_ data: Data) -> String {
        try! key.signature(for: data).base64EncodedString()
    }

    func appcast(version: String = "1.0.1", build: Int? = nil, zip: Data = Data("zip".utf8)) -> String {
        let semantic = UpdateVersion(version)!
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:openapps="https://openapps.space/xml-namespaces/releases">
            <channel>
                <title>App</title>
                <item>
                    <title>App \(version)</title>
                    <openapps:app>app</openapps:app>
                    <openapps:channel>stable</openapps:channel>
                    <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
                    <sparkle:version>\(build ?? semantic.buildNumber)</sparkle:version>
                    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                    <openapps:publishedAt>2026-09-15T10:00:00Z</openapps:publishedAt>
                    <pubDate>Tue, 15 Sep 2026 10:00:00 +0000</pubDate>
                    <description><![CDATA[Notes & <b>things</b>]]></description>
                    <openapps:sha256>\(UpdateSignature.sha256Hex(zip))</openapps:sha256>
                    <enclosure url="https://example.test/releases/app-v\(version)/App-\(version).zip" length="\(zip.count)" type="application/octet-stream" sparkle:edSignature="\(sign(zip))"/>
                </item>
            </channel>
        </rss>

        """
    }

    /// The exact trailer `sign_update` appends to an XML feed.
    func signed(_ xml: String, with signer: Curve25519.Signing.PrivateKey? = nil) -> Data {
        let body = Data(xml.utf8)
        let signature = try! (signer ?? key).signature(for: body).base64EncodedString()
        return body + Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(body.count)\n-->\n".utf8)
    }
}

@Suite struct UpdateFeedTests {
    let fixture = SignedFeedFixture()

    @Test func aSignedFeedParsesEveryField() throws {
        let zip = Data("the zip".utf8)
        let feed = try UpdateFeed.verifiedAndParsed(fixture.signed(fixture.appcast(zip: zip)), publicKey: fixture.publicKey)
        let item = try #require(feed.items.first)
        #expect(feed.items.count == 1)
        #expect(item.app == "app")
        #expect(item.channel == "stable")
        #expect(item.version == UpdateVersion("1.0.1"))
        #expect(item.build == 1_000_001)
        #expect(item.minimumMacOS == OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
        #expect(item.publishedAt == "2026-09-15T10:00:00Z")
        #expect(item.notes == "Notes & <b>things</b>")
        #expect(item.url.absoluteString == "https://example.test/releases/app-v1.0.1/App-1.0.1.zip")
        #expect(item.length == zip.count)
        #expect(item.sha256 == UpdateSignature.sha256Hex(zip))
        #expect(UpdateSignature.verify(zip, signature: item.signature, publicKey: fixture.publicKey))
        #expect(!UpdateSignature.verify(zip + Data([0]), signature: item.signature, publicKey: fixture.publicKey))
    }

    @Test func anUnsignedFeedIsRefused() {
        #expect(throws: UpdateFeedError.unsigned) {
            try UpdateFeed.verifiedAndParsed(Data(fixture.appcast().utf8), publicKey: fixture.publicKey)
        }
    }

    @Test func aFeedSignedWithAnotherKeyIsRefused() {
        let other = Curve25519.Signing.PrivateKey()
        #expect(throws: UpdateFeedError.badSignature) {
            try UpdateFeed.verifiedAndParsed(fixture.signed(fixture.appcast(), with: other), publicKey: fixture.publicKey)
        }
        #expect(throws: UpdateFeedError.badSignature) {
            try UpdateFeed.verifiedAndParsed(fixture.signed(fixture.appcast()), publicKey: other.publicKey.rawRepresentation.base64EncodedString())
        }
    }

    @Test func aModifiedFeedIsRefused() {
        let text = String(decoding: fixture.signed(fixture.appcast()), as: UTF8.self)
            .replacingOccurrences(of: "<openapps:channel>stable", with: "<openapps:channel>beta  ")
        #expect(throws: UpdateFeedError.badSignature) {
            try UpdateFeed.verifiedAndParsed(Data(text.utf8), publicKey: fixture.publicKey)
        }
    }

    @Test func nothingAfterTheSignedBytesCounts() {
        // An item appended after the signature comment is neither signed nor parsed.
        let smuggled = fixture.signed(fixture.appcast()) + Data(fixture.appcast(version: "9.9.9").utf8)
        #expect(throws: UpdateFeedError.badSignature) {
            try UpdateFeed.verifiedAndParsed(smuggled, publicKey: fixture.publicKey)
        }
    }

    @Test func aTrailerWithABogusLengthIsRefused() {
        let body = Data(fixture.appcast().utf8)
        for length in ["-1", "0", "\(body.count + 1)", "9223372036854775807", "x"] {
            let feed = body + Data("<!-- sparkle-signatures:\nedSignature: \(fixture.sign(body))\nlength: \(length)\n-->\n".utf8)
            #expect(throws: UpdateFeedError.self, "length \(length)") {
                try UpdateFeed.verifiedAndParsed(feed, publicKey: fixture.publicKey)
            }
        }
    }

    @Test func anItemMissingAFieldMakesTheFeedMalformed() {
        let xml = fixture.appcast().replacingOccurrences(of: "openapps:sha256>", with: "openapps:sha255>")
        #expect(throws: UpdateFeedError.malformed("item without openapps:sha256")) {
            try UpdateFeed.verifiedAndParsed(fixture.signed(xml), publicKey: fixture.publicKey)
        }
        let noEnclosure = fixture.appcast().replacingOccurrences(of: "<enclosure ", with: "<enclosure-x ")
        #expect(throws: UpdateFeedError.malformed("item without an enclosure")) {
            try UpdateFeed.verifiedAndParsed(fixture.signed(noEnclosure), publicKey: fixture.publicKey)
        }
        let badVersion = fixture.appcast().replacingOccurrences(of: "<sparkle:shortVersionString>1.0.1", with: "<sparkle:shortVersionString>1.0")
        #expect(throws: UpdateFeedError.malformed("version")) {
            try UpdateFeed.verifiedAndParsed(fixture.signed(badVersion), publicKey: fixture.publicKey)
        }
    }

    @Test func notXMLIsMalformed() {
        #expect(throws: UpdateFeedError.self) {
            try UpdateFeed.verifiedAndParsed(fixture.signed("<rss><channel><item>"), publicKey: fixture.publicKey)
        }
    }

    @Test func fileDigestsMatchInMemoryOnes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openapps-updater-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try data.write(to: url)
        #expect(try UpdateSignature.sha256Hex(fileAt: url) == UpdateSignature.sha256Hex(data))
    }
}
