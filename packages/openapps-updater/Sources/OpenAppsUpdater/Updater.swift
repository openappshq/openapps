import AppKit
import Foundation
import os

/// What an app injects into the updater: its identity, feed and key.
public struct UpdaterConfiguration: @unchecked Sendable {
    /// The app id in the feed (`openapps:app`), e.g. `openreaction`.
    public var appID: String
    /// The name shown to the user, e.g. `OpenReaction`.
    public var appName: String
    public var bundleURL: URL
    public var currentVersion: UpdateVersion
    public var currentBuild: Int
    public var feedURL: URL
    /// The Ed25519 public update key, base64.
    public var publicKey: String
    public var channel: String
    /// Local update tests only: allow an `http://127.0.0.1` feed and zip.
    public var allowsInsecureLoopback: Bool
    /// Where the two toggles and the last-check date live.
    public var defaults: UserDefaults

    public init(appID: String, appName: String, bundleURL: URL, currentVersion: UpdateVersion, currentBuild: Int,
                feedURL: URL, publicKey: String, channel: String = "stable", allowsInsecureLoopback: Bool = false,
                defaults: UserDefaults = .standard) {
        self.appID = appID
        self.appName = appName
        self.bundleURL = bundleURL
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.feedURL = feedURL
        self.publicKey = publicKey
        self.channel = channel
        self.allowsInsecureLoopback = allowsInsecureLoopback
        self.defaults = defaults
    }

    /// Reads the app's own Info.plist: `CFBundleShortVersionString`,
    /// `CFBundleVersion`, and the feed and key under `feedKey`/`publicKeyKey`.
    /// Nil when anything is missing or malformed — an official build without
    /// a pinned key has no updater rather than a permissive one.
    public init?(bundle: Bundle, appID: String, appName: String, feedKey: String = "SUFeedURL", publicKeyKey: String = "SUPublicEDKey",
                 allowsInsecureLoopback: Bool = false, defaults: UserDefaults = .standard) {
        guard let info = bundle.infoDictionary,
              let versionString = info["CFBundleShortVersionString"] as? String, let version = UpdateVersion(versionString),
              let buildString = info["CFBundleVersion"] as? String, let build = Int(buildString),
              let feedString = info[feedKey] as? String, let feed = URL(string: feedString),
              UpdatePolicy.allows(downloadURL: feed, insecureLoopback: allowsInsecureLoopback),
              let key = info[publicKeyKey] as? String, Data(base64Encoded: key)?.count == 32
        else { return nil }
        self.init(appID: appID, appName: appName, bundleURL: bundle.bundleURL, currentVersion: version, currentBuild: build,
                  feedURL: feed, publicKey: key, allowsInsecureLoopback: allowsInsecureLoopback, defaults: defaults)
    }
}

/// A verified update, unpacked next to the app and ready to be swapped in.
public struct StagedUpdate: Equatable, Sendable {
    public let item: UpdateFeedItem
    public let bundleURL: URL
    public let consent: UpdateConsent
}

public enum UpdaterError: Error, Equatable, LocalizedError {
    case notUpdatable
    case badResponse(Int)
    case insecureURL
    case wrongLength(expected: Int, actual: Int)
    case wrongDigest
    case badZipSignature
    case unpackFailed(String)
    case notOneBundle
    case wrongVersion(String)
    case cancelled
    /// The bundle on disk is already this new or newer (installed by something else meanwhile).
    case alreadyInstalled(String)
    case installedBundleUnreadable
    case quitInstallTimedOut
    /// The running code carries no designated requirement (an unsigned build): no update can be trusted against it.
    case runningCodeUnsigned

    public var errorDescription: String? {
        switch self {
        case .notUpdatable: "This copy can't update itself. Move it to Applications."
        case .badResponse(let code): "The server answered \(code)."
        case .insecureURL: "The update isn't served over https."
        case .wrongLength(let expected, let actual): "The download is \(actual) bytes, not the \(expected) announced."
        case .wrongDigest: "The download doesn't match the announced checksum."
        case .badZipSignature: "The download's signature does not match the update key."
        case .unpackFailed(let what): "The download couldn't be unpacked: \(what)"
        case .notOneBundle: "The download doesn't contain exactly the app."
        case .wrongVersion(let what): "The downloaded app is \(what), not the announced version."
        case .cancelled: "The update was cancelled."
        case .alreadyInstalled(let version): "Version \(version) is already installed."
        case .installedBundleUnreadable: "The installed app's version couldn't be read."
        case .quitInstallTimedOut: "Installing on quit took too long and was skipped."
        case .runningCodeUnsigned: "This copy of the app is not signed, so no update can be verified against it."
        }
    }
}

/// The in-app updater (RELEASES.md, "In-app updater"). Everything runs on the
/// main actor; the network and unpacking happen in cancellable tasks.
///
/// - Without a stored preference both toggles read off: the feed is
///   contacted only for `checkNow()`. The app owns the fresh-install
///   default (RELEASES.md: automatic checks on, decided once) and writes it
///   through `setChecksAutomatically(_:)`.
/// - With "check automatically" on: a check on launch when a day has passed,
///   every 24 hours while running, on wake when overdue, and one retry an
///   hour after a failure.
/// - With "install automatically" on as well, a found update is downloaded,
///   verified (length, SHA-256, Ed25519, code signature satisfying the
///   installed app's designated requirement, version) and staged next to the
///   app. Turning either toggle off cancels a download in flight and
///   discards what is staged; the quit path re-checks the toggle.
/// - Staged with automatic consent: installed on the next quit, or at once
///   from "Update ready — Restart". A manual install (`checkNow()` →
///   `installAvailable()`) downloads, stages and restarts immediately.
/// - The swap is atomic; the staged bundle is re-evaluated against the
///   designated requirement right before it.
@MainActor
@Observable
public final class Updater {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(UpdateFeedItem)
        case downloading(UpdateFeedItem)
        case staged(StagedUpdate)
        case failed(String)
    }

    public let configuration: UpdaterConfiguration
    public let location: UpdateLocation
    public private(set) var checksAutomatically: Bool
    public private(set) var installsAutomatically: Bool
    public private(set) var lastCheck: Date?
    public private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    /// Set once the staged update has been swapped in; the running process is the old version until it relaunches.
    public private(set) var installed = false
    /// A previous copy kept next to the app after an interrupted update (RELEASES.md): shown in Settings until discarded.
    public private(set) var preservedBackup: URL?
    /// Set by "Restart to Update": the quit path installs, then reopens the app.
    public private(set) var wantsRelaunch = false
    /// The identity every update must satisfy, taken from the running code at
    /// launch — never re-read from disk later.
    @ObservationIgnored private let trustedRequirement: String?

    /// Test and diagnostics hooks.
    @ObservationIgnored public var onPhaseChange: ((Phase) -> Void)?
    @ObservationIgnored public var onStaged: ((StagedUpdate) -> Void)?
    @ObservationIgnored public var onCheckFinished: (((any Error)?) -> Void)?
    /// What the quit path did: the install outcome and whether a reopen was arranged.
    @ObservationIgnored public var onQuitFinished: ((InstallOutcome, Bool) -> Void)?

    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var schedule: Timer?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// `start()` ran in an updatable location: the recovery is done and the schedule may check.
    @ObservationIgnored private var started = false
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let log: Logger

    private enum Key {
        static let checks = "OpenAppsUpdater.checkAutomatically"
        static let installs = "OpenAppsUpdater.installAutomatically"
        static let lastCheck = "OpenAppsUpdater.lastCheck"
    }

    public init(configuration: UpdaterConfiguration) {
        self.configuration = configuration
        location = UpdateLocation.current(bundleURL: configuration.bundleURL)
        let defaults = configuration.defaults
        checksAutomatically = defaults.object(forKey: Key.checks) as? Bool ?? UpdatePolicy.automaticChecksByDefault
        installsAutomatically = defaults.object(forKey: Key.installs) as? Bool ?? UpdatePolicy.automaticDownloadsByDefault
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 15 * 60
        session = URLSession(configuration: sessionConfiguration)
        log = Logger(subsystem: Bundle.main.bundleIdentifier ?? configuration.appID, category: "updates")
        trustedRequirement = try? CodeSignature.designatedRequirementOfRunningCode()
    }

    /// Recovers an interrupted swap, then starts the schedule if the user
    /// turned it on. Makes no request on its own unless a check is due.
    public func start() {
        switch UpdateSwap.recover(app: configuration.bundleURL) {
        case .nothing:
            break
        case .cleaned:
            log.notice("Cleaned up after an earlier update")
        case .backupPreserved(let backup):
            // Never removed on its own: the user decides once the installed app works.
            preservedBackup = backup
            log.error("A bundle of uncertain provenance is preserved at \(backup.path, privacy: .public) after an interrupted update")
        }
        guard location == .updatable else {
            log.notice("Updates are off: the app runs from a \(String(describing: self.location), privacy: .public) location")
            return
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        started = true
        reschedule()
        checkIfDue()
    }

    public var isAvailable: Bool { location == .updatable }

    // MARK: - Settings

    /// Turning checks on after `start()` (from Settings, or an app's
    /// fresh-install default once it has resolved) also runs the launch
    /// check `start()` skipped, if one is due; the schedule carries on from
    /// there. Turning them off cancels the automatic work in flight.
    public func setChecksAutomatically(_ enabled: Bool) {
        checksAutomatically = enabled
        configuration.defaults.set(enabled, forKey: Key.checks)
        if !enabled {
            // Downloading on its own only makes sense while checking on its own.
            setInstallsAutomatically(false)
        }
        reschedule()
        if enabled, started { checkIfDue() }
    }

    public func setInstallsAutomatically(_ enabled: Bool) {
        installsAutomatically = enabled
        configuration.defaults.set(enabled, forKey: Key.installs)
        if !enabled { withdrawAutomaticWork() }
    }

    /// Turning the toggle off revokes everything the schedule started: a
    /// check or download in flight is cancelled and a staged automatic
    /// update is discarded, so nothing installs on quit.
    private func withdrawAutomaticWork() {
        switch phase {
        case .checking where currentConsent == .automatic:
            work?.cancel()
            work = nil
            log.notice("Cancelled the automatic update check")
            phase = .idle
        case .downloading(let item) where currentConsent == .automatic:
            work?.cancel()
            work = nil
            log.notice("Cancelled the automatic download of \(item.version.description, privacy: .public)")
            discardStaging()
            phase = .idle
        case .staged(let staged) where staged.consent == .automatic:
            log.notice("Discarded the staged automatic update \(staged.item.version.description, privacy: .public)")
            discardStaging()
            phase = .idle
        default:
            break
        }
    }

    @ObservationIgnored private var currentConsent: UpdateConsent = .automatic

    /// Removes what this updater staged. A preserved bundle of uncertain
    /// provenance is never touched here; only the user's discard removes it.
    private func discardStaging() {
        guard UpdateSwap.preservedBackup(for: configuration.bundleURL) == nil else { return }
        try? FileManager.default.removeItem(at: UpdateSwap.stagingDirectory(for: configuration.bundleURL))
        try? FileManager.default.removeItem(at: UpdateSwap.stateLocation(for: configuration.bundleURL))
    }

    // MARK: - Checking

    /// "Check now": always allowed, never installs by itself. Ends in
    /// `.available`, `.upToDate` or `.failed`. A staged update is kept as it
    /// is; it installs on quit or on Restart.
    public func checkNow() {
        guard isAvailable, !isBusy else { return }
        if case .staged = phase { return }
        run(consent: .manual, install: false)
    }

    /// Installs the update `checkNow()` found: downloads, stages, swaps and
    /// relaunches. The user's explicit consent, independent of the toggles.
    public func installAvailable() {
        guard case .available(let item) = phase, !isBusy else { return }
        currentConsent = .manual
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let staged = try await stage(item, consent: .manual)
                phase = .staged(staged)
                onStaged?(staged)
                restartToUpdate()
            } catch where Self.isCancellation(error) {
                discardStaging()
                phase = .idle
            } catch {
                discardStaging()
                phase = .failed(error.localizedDescription)
            }
            work = nil
        }
    }

    /// A cancelled task surfaces as `CancellationError` from our own checks
    /// or as `URLError.cancelled` from URLSession.
    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    private var isBusy: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }

    private func checkIfDue() {
        guard !isBusy else { return }
        if case .staged = phase { return }
        guard UpdatePolicy.isAutomaticCheckDue(
            automaticChecks: checksAutomatically, location: location, lastCheck: lastCheck, now: Date()) else { return }
        run(consent: .automatic, install: installsAutomatically)
    }

    private func reschedule() {
        schedule?.invalidate()
        schedule = nil
        retry?.cancel()
        retry = nil
        guard checksAutomatically, location == .updatable else { return }
        let timer = Timer(timeInterval: UpdatePolicy.checkInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.checkIfDue() } }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        schedule = timer
    }

    private func run(consent: UpdateConsent, install: Bool) {
        currentConsent = consent
        phase = .checking
        work = Task { [weak self] in
            guard let self else { return }
            var failure: (any Error)?
            do {
                let item = try await check()
                recordCheck()
                guard let item else {
                    phase = .upToDate
                    onCheckFinished?(nil)
                    work = nil
                    return
                }
                if install, installsAutomatically, consent == .automatic {
                    let staged = try await stage(item, consent: .automatic)
                    // The toggle may have gone off while unpacking; then the work was cancelled above.
                    guard installsAutomatically else { throw CancellationError() }
                    phase = .staged(staged)
                    onStaged?(staged)
                } else {
                    phase = .available(item)
                }
            } catch where Self.isCancellation(error) {
                discardStaging()
                phase = .idle
            } catch {
                failure = error
                discardStaging()
                phase = .failed(error.localizedDescription)
                log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            }
            if consent == .automatic {
                if failure != nil { consecutiveFailures += 1; scheduleRetry() } else { consecutiveFailures = 0 }
            }
            onCheckFinished?(failure)
            work = nil
        }
    }

    private func recordCheck() {
        lastCheck = Date()
        configuration.defaults.set(lastCheck, forKey: Key.lastCheck)
    }

    private func scheduleRetry() {
        retry?.cancel()
        guard let delay = UpdatePolicy.retryDelay(consecutiveFailures: consecutiveFailures) else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, checksAutomatically, !isBusy else { return }
            run(consent: .automatic, install: installsAutomatically)
        }
    }

    /// A plain GET of the feed; nothing about this Mac travels with it.
    private func check() async throws -> UpdateFeedItem? {
        var request = URLRequest(url: configuration.feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdaterError.badResponse(http.statusCode) }
        let feed = try UpdateFeed.verifiedAndParsed(data, publicKey: configuration.publicKey)
        let macOS = ProcessInfo.processInfo.operatingSystemVersion
        return feed.items
            .filter { UpdatePolicy.offers($0, app: configuration.appID, channel: configuration.channel,
                                          currentVersion: configuration.currentVersion, currentBuild: configuration.currentBuild, macOSVersion: macOS) }
            .max { $0.version < $1.version }
    }

    // MARK: - Staging

    /// Downloads and verifies the zip, unpacks it next to the app and
    /// verifies the bundle inside. Every step checks for cancellation.
    private func stage(_ item: UpdateFeedItem, consent: UpdateConsent) async throws -> StagedUpdate {
        phase = .downloading(item)
        guard UpdatePolicy.allows(downloadURL: item.url, insecureLoopback: configuration.allowsInsecureLoopback) else { throw UpdaterError.insecureURL }
        let app = configuration.bundleURL
        let staging = try UpdateSwap.prepareStagingDirectory(for: app)
        let zip = staging.appendingPathComponent("update.zip")
        let (downloaded, response) = try await session.download(for: URLRequest(url: item.url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdaterError.badResponse(http.statusCode) }
        try FileManager.default.moveItem(at: downloaded, to: zip)
        try Task.checkCancellation()

        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? -1
        guard size == item.length else { throw UpdaterError.wrongLength(expected: item.length, actual: size) }
        guard try UpdateSignature.sha256Hex(fileAt: zip) == item.sha256 else { throw UpdaterError.wrongDigest }
        let bytes = try Data(contentsOf: zip, options: .mappedIfSafe)
        guard UpdateSignature.verify(bytes, signature: item.signature, publicKey: configuration.publicKey) else { throw UpdaterError.badZipSignature }
        try Task.checkCancellation()

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try await Self.unzip(zip, into: unpacked)
        try FileManager.default.removeItem(at: zip)
        try Task.checkCancellation()
        let entries = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil, options: [])
        guard entries.count == 1, entries[0].lastPathComponent == app.lastPathComponent else { throw UpdaterError.notOneBundle }
        let bundle = entries[0]
        try Self.verify(bundle, satisfying: trustedRequirement, expecting: item)
        return StagedUpdate(item: item, bundleURL: bundle, consent: consent)
    }

    /// `ditto -x -k`, bounded: a stuck unpack fails the update rather than hanging it.
    private static func unzip(_ zip: URL, into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { process in
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        continuation.resume(throwing: UpdaterError.unpackFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: UpdaterError.unpackFailed(error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// The staged bundle must be validly signed, satisfy the running app's
    /// designated requirement (evaluated, not compared as text), and be the
    /// announced version and build.
    nonisolated static func verify(_ bundle: URL, satisfying requirement: String?, expecting item: UpdateFeedItem) throws {
        guard let requirement else { throw UpdaterError.runningCodeUnsigned }
        try CodeSignature.verify(bundle, satisfies: requirement)
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String
        else { throw UpdaterError.wrongVersion("unreadable") }
        guard version == item.version.description, build == String(item.build) else {
            throw UpdaterError.wrongVersion("\(version) (\(build))")
        }
    }

    /// The user has decided the installed app works: the preserved backup goes.
    public func discardPreservedBackup() {
        do {
            try UpdateSwap.discardPreservedBackup(for: configuration.bundleURL)
            preservedBackup = nil
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Installing

    public enum InstallOutcome: Equatable, Sendable {
        /// The staged update is in place; the running process is the old version until it relaunches.
        case installed
        /// Nothing was staged, consent was withdrawn, or the deadline passed before the commit point.
        case skipped
        case failed(String)
    }

    /// Installs the staged update if its consent still holds. Called from
    /// the quit path. The verification and the exchange run off the main
    /// thread; the main thread waits up to `deadline`, then cooperates with
    /// the worker: before the commit point the install is abandoned with
    /// nothing changed, after it (the exchange itself, one syscall, and the
    /// bounded bookkeeping) the wait continues to completion, so the process
    /// never exits in the middle of a swap.
    public func installStagedIfAllowed(deadline: TimeInterval = 10) -> InstallOutcome {
        guard !installed, case .staged(let staged) = phase,
              UpdatePolicy.mayInstallOnQuit(consent: staged.consent, automaticDownloads: installsAutomatically) else { return .skipped }
        let bundleURL = configuration.bundleURL
        let requirement = trustedRequirement
        let transaction = InstallTransaction()
        DispatchQueue.global(qos: .userInitiated).async {
            transaction.finish(Result { try Self.install(staged, at: bundleURL, satisfying: requirement, transaction: transaction) })
        }
        var result = transaction.wait(timeout: deadline)
        if result == nil {
            if transaction.abortUnlessCommitted() {
                log.error("Installing \(staged.item.version.description, privacy: .public) on quit exceeded \(deadline, privacy: .public)s before the commit point; abandoned, nothing changed")
                return .skipped
            }
            // Past the commit point: the exchange is one syscall; wait it out.
            result = transaction.wait(timeout: nil)
        }
        switch result {
        case .success?:
            installed = true
            phase = .idle
            log.notice("Installed \(staged.item.version.description, privacy: .public) on quit")
            return .installed
        case .failure(let error)?:
            log.error("Installing \(staged.item.version.description, privacy: .public) on quit failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        case nil:
            return .skipped
        }
    }

    /// "Update ready — Restart": asks the app to quit. The app's quit path
    /// drains what it must, calls `finishQuit()`, which installs and reopens.
    public func restartToUpdate() {
        guard !installed, case .staged = phase else { return }
        wantsRelaunch = true
        Self.terminateFromTheRunLoop()
    }

    /// `terminate:` must not be called from inside a main-queue block (a
    /// Task continuation, `DispatchQueue.main.async`): AppKit waits for the
    /// delegate's deferred reply in a nested run loop that cannot re-enter
    /// the main queue, and the reply never comes. Scheduling it on the run
    /// loop itself avoids that.
    public static func terminateFromTheRunLoop(after delay: TimeInterval = 0) {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: delay)
    }

    /// The last step of the app's quit path: installs a staged update whose
    /// consent holds and, after "Restart to Update", reopens the app.
    /// Returns whether the quit may proceed; after a failed restart install
    /// it must not, so the user sees why.
    public func finishQuit() async -> Bool {
        let relaunch = wantsRelaunch
        wantsRelaunch = false
        let outcome = installStagedIfAllowed(deadline: relaunch ? 60 : 10)
        guard relaunch else {
            onQuitFinished?(outcome, false)
            return true
        }
        switch outcome {
        case .installed:
            var reopening = true
            do {
                try Self.reopenAfterExit(configuration.bundleURL)
            } catch {
                reopening = false
                log.error("Installed; could not arrange to reopen the app: \(error.localizedDescription, privacy: .public)")
            }
            onQuitFinished?(outcome, reopening)
            return true
        case .skipped:
            phase = .failed("The update could not be installed in time. Try again.")
            onQuitFinished?(outcome, false)
            return false
        case .failed(let message):
            phase = .failed(message)
            onQuitFinished?(outcome, false)
            return false
        }
    }

    /// Opens the (now updated) bundle once this process has exited. A
    /// running app that prohibits multiple instances cannot open a second
    /// copy of itself — Launch Services hands back the running one — so a
    /// small detached shell waits for this process to go, then `open`s the
    /// app. It gives up after a minute.
    nonisolated private static func reopenAfterExit(_ bundleURL: URL) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            #"""
            i=0
            while kill -0 "$1" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
            exec /usr/bin/open "$2"
            """#,
            "reopen", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path,
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    /// The install proper, safe off the main actor: the bundle on disk must
    /// still be older than the update (something else may have updated it
    /// meanwhile), the staged bundle is re-evaluated against the running
    /// app's identity, then — past the commit point — the two are exchanged
    /// atomically.
    nonisolated private static func install(_ staged: StagedUpdate, at bundleURL: URL, satisfying requirement: String?,
                                            transaction: InstallTransaction) throws {
        let onDisk = try installedVersion(of: bundleURL)
        guard UpdatePolicy.mayReplace(installedVersion: onDisk.version, installedBuild: onDisk.build, with: staged.item) else {
            throw UpdaterError.alreadyInstalled(onDisk.version.description)
        }
        try verify(staged.bundleURL, satisfying: requirement, expecting: staged.item)
        guard transaction.commit() else { throw CancellationError() }
        try UpdateSwap.swap(app: bundleURL, staged: staged.bundleURL)
    }

    nonisolated private static func installedVersion(of bundleURL: URL) throws -> (version: UpdateVersion, build: Int) {
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let versionString = info["CFBundleShortVersionString"] as? String, let version = UpdateVersion(versionString),
              let buildString = info["CFBundleVersion"] as? String, let build = Int(buildString)
        else { throw UpdaterError.installedBundleUnreadable }
        return (version, build)
    }
}

/// The hand-off between the quit path and the install worker: a commit
/// point the worker passes only if no abort was requested, and a result
/// the waiter reads once the worker is done.
final class InstallTransaction: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var aborted = false
    private var committed = false
    private var result: Result<Void, any Error>?

    /// Worker: passes the commit point unless an abort was requested first.
    func commit() -> Bool {
        lock.withLock {
            guard !aborted else { return false }
            committed = true
            return true
        }
    }

    /// Waiter: requests an abort; false if the worker already committed.
    func abortUnlessCommitted() -> Bool {
        lock.withLock {
            guard !committed else { return false }
            aborted = true
            return true
        }
    }

    func finish(_ value: Result<Void, any Error>) {
        lock.withLock { result = value }
        done.signal()
    }

    /// Waits for the worker; nil on timeout.
    func wait(timeout: TimeInterval?) -> Result<Void, any Error>? {
        if let timeout {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        } else {
            done.wait()
        }
        return lock.withLock { result }
    }
}
