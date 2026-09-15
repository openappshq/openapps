import Foundation
import OpenAppsUpdater
import Testing

/// Real bundles, signed with `codesign`, in a temporary folder.
struct SignedBundles {
    let folder: AppFolder

    init() throws {
        folder = try AppFolder()
    }

    /// An ad-hoc signed bundle whose executable is a copy of `/usr/bin/true`;
    /// the marker goes into Info.plist, which the signature seals, so every
    /// distinct marker gives a distinct code hash.
    func bundle(_ name: String, identifier: String, marker: Int, requirement: String? = nil) throws -> URL {
        let bundle = folder.url.appendingPathComponent(name, isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executableURL = macOS.appendingPathComponent("App")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executableURL)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "App", "CFBundlePackageType": "APPL",
                                    "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "1000001", "TestMarker": marker]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        var arguments = ["--force", "--sign", "-", "--identifier", identifier]
        if let requirement { arguments += ["-r=designated => \(requirement)"] }
        arguments.append(bundle.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Injected("codesign failed: " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        return bundle
    }
}

@Suite struct CodeSignatureTests {
    @Test func aBundleSatisfiesItsOwnRequirementAndNotAnotherBundles() throws {
        let bundles = try SignedBundles()
        defer { bundles.folder.remove() }
        let installed = try bundles.bundle("Installed.app", identifier: "test.app", marker: 1)
        let other = try bundles.bundle("Other.app", identifier: "test.app", marker: 2)
        let requirement = try CodeSignature.designatedRequirement(of: installed)
        // Ad-hoc: the requirement names the code hash, so only this exact code satisfies it.
        #expect(requirement.contains("cdhash H\""))
        try CodeSignature.verify(installed, satisfies: requirement)
        // Same identifier, different code: an ad-hoc requirement names the code hash.
        #expect(throws: CodeSignature.Failure.self) {
            try CodeSignature.verify(other, satisfies: requirement)
        }
    }

    @Test func aCopiedRequirementStringDoesNotMakeABundleSatisfyIt() throws {
        let bundles = try SignedBundles()
        defer { bundles.folder.remove() }
        let installed = try bundles.bundle("Installed.app", identifier: "test.app", marker: 1)
        let requirement = try CodeSignature.designatedRequirement(of: installed)
        // Re-signed with the installed app's requirement text: `codesign -d -r-`
        // prints the same line for both, and a text comparison would pass.
        let forged = try bundles.bundle("Forged.app", identifier: "test.app", marker: 3, requirement: requirement)
        #expect(try CodeSignature.designatedRequirement(of: forged) == requirement)
        let error = #expect(throws: CodeSignature.Failure.self) {
            try CodeSignature.verify(forged, satisfies: requirement)
        }
        guard case .doesNotSatisfyRequirement? = error else {
            Issue.record("expected the requirement to fail, got \(String(describing: error))")
            return
        }
    }

    @Test func aTamperedBundleIsInvalid() throws {
        let bundles = try SignedBundles()
        defer { bundles.folder.remove() }
        let installed = try bundles.bundle("Installed.app", identifier: "test.app", marker: 1)
        let requirement = try CodeSignature.designatedRequirement(of: installed)
        let tampered = try bundles.bundle("Tampered.app", identifier: "test.app", marker: 1)
        try CodeSignature.verify(tampered, satisfies: requirement) // identical code: passes
        // Info.plist is sealed by the signature; changing it after signing breaks it.
        let plist = tampered.appendingPathComponent("Contents/Info.plist")
        try (try Data(contentsOf: plist) + Data("\n".utf8)).write(to: plist)
        #expect(throws: CodeSignature.Failure.self) {
            try CodeSignature.verify(tampered, satisfies: requirement)
        }
    }

    @Test func anUnsignedBundleHasNoRequirement() throws {
        let folder = try AppFolder()
        defer { folder.remove() }
        let app = try folder.bundle(marker: "unsigned")
        #expect(throws: CodeSignature.Failure.self) {
            try CodeSignature.designatedRequirement(of: app)
        }
    }
}
