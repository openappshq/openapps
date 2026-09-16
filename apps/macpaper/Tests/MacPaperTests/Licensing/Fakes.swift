import Foundation
@testable import MacPaper
import MacPaperCore
import OpenAppsLicensing

/// In-memory stand-ins for the package's protocols, the shape of the ones
/// its own tests use: a Dodo client and trial registry that answer what the
/// test says, record stores that can fail, a device with a fixed UUID and
/// a clock the test moves. Nothing here touches the disk or the network.
final class FakeClock: @unchecked Sendable {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400
    var now = FakeClock.start
    /// The monotonic clock: moves forward with `advance`, never back.
    var uptime: TimeInterval = 1_000
    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        uptime += max(0, seconds)
    }
}

final class FakeClient: LicenseClient, @unchecked Sendable {
    enum Call: Equatable { case activate(key: String, name: String), validate(instance: String), deactivate(instance: String) }
    var calls: [Call] = []
    var activation: ActivationResult = .unreachable
    var validation: ValidationResult = .unreachable
    var deactivation: DeactivationResult = .deactivated

    func activate(licenseKey: String, name: String) async -> ActivationResult {
        calls.append(.activate(key: licenseKey, name: name))
        return activation
    }

    func validate(licenseKey: String, instanceID: String) async -> ValidationResult {
        calls.append(.validate(instance: instanceID))
        return validation
    }

    func deactivate(licenseKey: String, instanceID: String) async -> DeactivationResult {
        calls.append(.deactivate(instance: instanceID))
        return deactivation
    }
}

final class MemoryStore: LicenseStore, @unchecked Sendable {
    var record: LicenseRecord?
    var pendingCleanups: [PendingCleanup] = []
    var failsWrites = false
    func loadRecord() throws(LicenseStoreError) -> LicenseRecord? { record }
    func saveRecord(_ record: LicenseRecord) throws(LicenseStoreError) {
        if failsWrites { throw .unavailable("denied") }
        self.record = record
    }
    func clearRecord() throws(LicenseStoreError) {
        if failsWrites { throw .unavailable("denied") }
        record = nil
    }
    func loadPendingCleanups() throws(LicenseStoreError) -> [PendingCleanup] { pendingCleanups }
    func savePendingCleanups(_ cleanups: [PendingCleanup]) throws(LicenseStoreError) {
        if failsWrites { throw .unavailable("denied") }
        pendingCleanups = cleanups
    }
}

final class MemoryJournal: InvalidationJournal, @unchecked Sendable {
    var entries: [String: JournalEntry] = [:]
    func entry(instanceID: String) throws(LicenseStoreError) -> JournalEntry? { entries[instanceID] }
    func record(instanceID: String, entry: JournalEntry) -> Bool {
        if let existing = entries[instanceID], existing.seq >= entry.seq { return true }
        entries[instanceID] = entry
        return true
    }
    func clear(instanceID: String, upTo seq: UInt64) -> Bool {
        if let existing = entries[instanceID], existing.seq > seq { return true }
        entries[instanceID] = nil
        return true
    }
    func replaceUnreadable(instanceID: String, with entry: JournalEntry?) -> Bool { true }
}

/// The trial record as the store holds it: absent, readable, or failing.
final class MemoryTrialStore: TrialStore, @unchecked Sendable {
    var record: TrialRecord?
    var readError: LicenseStoreError?
    var failsWrites = false
    private(set) var saves: [TrialRecord] = []
    func loadTrial() throws(LicenseStoreError) -> TrialRecord? {
        if let readError { throw readError }
        return record
    }
    func saveTrial(_ trial: TrialRecord) throws(LicenseStoreError) {
        if failsWrites { throw .unavailable("denied") }
        saves.append(trial)
        record = trial
    }
}

final class FakeRegistry: TrialRegistryClient, @unchecked Sendable {
    var devices: [String] = []
    var result: TrialRegistrationResult = .unreachable
    func register(device: String) async -> TrialRegistrationResult {
        devices.append(device)
        return result
    }
}

final class FakeDevice: DeviceIdentity, @unchecked Sendable {
    var uuid: String? = "00000000-1111-2222-3333-444444444444"
    func hardwareUUID() -> String? { uuid }
}

/// A license state a test moves by hand, for sources bound to `LicenseStatus`.
final class StateBox: @unchecked Sendable {
    var state: LicenseState
    init(_ state: LicenseState) { self.state = state }
}

/// The latest snapshot the manager published, as the app's controller
/// keeps it: the projection to the current clocks happens where it is read.
final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot = LicenseSnapshot()
    var snapshot: LicenseSnapshot {
        get { lock.withLock { _snapshot } }
        set { lock.withLock { _snapshot = newValue } }
    }
}
