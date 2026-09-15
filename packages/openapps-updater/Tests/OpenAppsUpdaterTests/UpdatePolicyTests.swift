import Foundation
import OpenAppsUpdater
import Testing

@Suite struct UpdatePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func freshInstallNeverChecksOnItsOwn() {
        #expect(UpdatePolicy.automaticChecksByDefault == false)
        #expect(UpdatePolicy.automaticDownloadsByDefault == false)
        #expect(!UpdatePolicy.isAutomaticCheckDue(
            automaticChecks: UpdatePolicy.automaticChecksByDefault, location: .updatable, lastCheck: nil, now: now))
    }

    @Test func automaticChecksRunWhenNeverCheckedOrADayHasPassed() {
        #expect(UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .updatable, lastCheck: nil, now: now))
        #expect(UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .updatable, lastCheck: now.addingTimeInterval(-86_400), now: now))
        #expect(!UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .updatable, lastCheck: now.addingTimeInterval(-86_399), now: now))
    }

    @Test func aLastCheckInTheFutureIsDue() {
        #expect(UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .updatable, lastCheck: now.addingTimeInterval(3_600), now: now))
    }

    @Test func turnedOffOrNotUpdatableNeverChecks() {
        let old = now.addingTimeInterval(-10 * 86_400)
        #expect(!UpdatePolicy.isAutomaticCheckDue(automaticChecks: false, location: .updatable, lastCheck: old, now: now))
        #expect(!UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .translocated, lastCheck: old, now: now))
        #expect(!UpdatePolicy.isAutomaticCheckDue(automaticChecks: true, location: .readOnly, lastCheck: nil, now: now))
    }

    @Test func retriesOnceAfterAnHourThenWaitsForTheDailyCheck() {
        #expect(UpdatePolicy.retryDelay(consecutiveFailures: 0) == nil)
        #expect(UpdatePolicy.retryDelay(consecutiveFailures: 1) == 3_600)
        #expect(UpdatePolicy.retryDelay(consecutiveFailures: 2) == nil)
        #expect(UpdatePolicy.retryDelay(consecutiveFailures: 7) == nil)
    }

    @Test func classifiesLocations() {
        #expect(UpdateLocation.classify(bundlePath: "/Users/a/Applications/App.app", volumeIsReadOnly: false, containerIsWritable: true) == .updatable)
        #expect(UpdateLocation.classify(
            bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/App.app", volumeIsReadOnly: true, containerIsWritable: false) == .translocated)
        #expect(UpdateLocation.classify(bundlePath: "/Volumes/App/App.app", volumeIsReadOnly: true, containerIsWritable: false) == .readOnly)
        #expect(UpdateLocation.classify(bundlePath: "/Applications/App.app", volumeIsReadOnly: false, containerIsWritable: false) == .readOnly)
    }

    @Test func onlyHTTPSOrTheLoopbackForTestsIsAllowed() {
        #expect(UpdatePolicy.allows(downloadURL: URL(string: "https://github.com/x.zip")!, insecureLoopback: false))
        #expect(!UpdatePolicy.allows(downloadURL: URL(string: "http://github.com/x.zip")!, insecureLoopback: true))
        #expect(!UpdatePolicy.allows(downloadURL: URL(string: "http://127.0.0.1:8000/x.zip")!, insecureLoopback: false))
        #expect(UpdatePolicy.allows(downloadURL: URL(string: "http://127.0.0.1:8000/x.zip")!, insecureLoopback: true))
        #expect(!UpdatePolicy.allows(downloadURL: URL(string: "http://localhost:8000/x.zip")!, insecureLoopback: true))
        #expect(!UpdatePolicy.allows(downloadURL: URL(string: "file:///x.zip")!, insecureLoopback: true))
    }

    // MARK: - Versions

    @Test func buildNumbersFollowReleaseOrder() {
        #expect(UpdateVersion("2.0.0")!.buildNumber == 2_000_000)
        #expect(UpdateVersion("1.9.1")!.buildNumber == 1_009_001)
        #expect(UpdateVersion("1.9.1")!.buildNumber < UpdateVersion("2.0.0")!.buildNumber)
        #expect(UpdateVersion("1.10.0")! > UpdateVersion("1.9.9")!)
        #expect(UpdateVersion("1.10.0")!.buildNumber > UpdateVersion("1.9.9")!.buildNumber)
        #expect(UpdateVersion("1.0") == nil)
        #expect(UpdateVersion("1.0.0.0") == nil)
        #expect(UpdateVersion("v1.0.0") == nil)
        #expect(UpdateVersion("1.1000.0") == nil)
        #expect(UpdateVersion("1..0") == nil)
    }

    func item(version: String, build: Int? = nil, app: String = "app", channel: String = "stable", macOS: String = "14.0") -> UpdateFeedItem {
        let semantic = UpdateVersion(version)!
        return UpdateFeedItem(
            app: app, channel: channel, version: semantic, build: build ?? semantic.buildNumber,
            minimumMacOS: OperatingSystemVersion(parsing: macOS)!, publishedAt: "2026-09-15T10:00:00Z", notes: "",
            url: URL(string: "https://example.test/App-\(version).zip")!,
            length: 1, sha256: String(repeating: "0", count: 64), signature: "sig")
    }

    private func offers(_ item: UpdateFeedItem, current: String, macOS: String = "15.1.0") -> Bool {
        let version = UpdateVersion(current)!
        return UpdatePolicy.offers(item, app: "app", channel: "stable", currentVersion: version,
                                   currentBuild: version.buildNumber, macOSVersion: OperatingSystemVersion(parsing: macOS)!)
    }

    @Test func onlyAStrictlyNewerReleaseIsOffered() {
        #expect(offers(item(version: "1.0.1"), current: "1.0.0"))
        #expect(offers(item(version: "2.0.0"), current: "1.9.9"))
        #expect(!offers(item(version: "1.0.0"), current: "1.0.0"))
        // A back-port from a later commit: lower version, never offered to 2.0.0.
        #expect(!offers(item(version: "1.9.1"), current: "2.0.0"))
        // A newer version whose build number was not derived from it is not trusted.
        #expect(!offers(item(version: "1.0.1", build: 5), current: "1.0.0"))
        #expect(!offers(item(version: "1.0.1", build: 2_000_000), current: "1.0.0"))
    }

    @Test func otherAppsChannelsAndNewerMacOSAreNotOffered() {
        #expect(!offers(item(version: "1.0.1", app: "other"), current: "1.0.0"))
        #expect(!offers(item(version: "1.0.1", channel: "beta"), current: "1.0.0"))
        #expect(!offers(item(version: "1.0.1", macOS: "16.0"), current: "1.0.0", macOS: "15.1.0"))
        #expect(offers(item(version: "1.0.1", macOS: "15.1"), current: "1.0.0", macOS: "15.1.0"))
    }

    @Test func consentToInstallOnQuitFollowsTheToggle() {
        #expect(UpdatePolicy.mayInstallOnQuit(consent: .automatic, automaticDownloads: true))
        #expect(!UpdatePolicy.mayInstallOnQuit(consent: .automatic, automaticDownloads: false))
        #expect(UpdatePolicy.mayInstallOnQuit(consent: .manual, automaticDownloads: false))
    }
}
