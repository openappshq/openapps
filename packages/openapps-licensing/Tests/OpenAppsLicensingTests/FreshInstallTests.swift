import Foundation
import OpenAppsLicensing
import Testing

/// What the license manager reports as "fresh install", with the licensing fakes.
extension LicensingTests {
    @Test("Fresh install: no license record and no trial record at the first read")
    func freshInstallWhenBothRecordsAreAbsent() {
        trialStore.record = nil
        let manager = makeManager()
        #expect(manager.freshInstall == true)
        #expect(manager.snapshot.freshInstall == true)
        // The provisional trial saved just now does not change the answer.
        #expect(trialStore.record != nil)
        #expect(manager.snapshot.freshInstall == true)
    }

    @Test("Not fresh: a kept trial record (a reinstall) or a license record")
    func notFreshWithAnyRecord() {
        let manager = makeManager() // the default fake trial record: ended long ago
        #expect(manager.freshInstall == false)

        trialStore.record = nil
        store.record = paidRecord(lastSuccessAge: 0)
        let licensed = makeManager()
        #expect(licensed.freshInstall == false)
        #expect(licensed.snapshot.freshInstall == false)
    }

    @Test("Unknown while storage has not answered; decided once it does")
    func freshInstallWaitsForStorage() async {
        trialStore.record = nil
        trialStore.readError = .unavailable("locked")
        let manager = makeManager()
        #expect(manager.freshInstall == nil, "the license record is absent but the trial record is unread")
        trialStore.readError = nil
        await manager.tick()
        #expect(manager.freshInstall == true)

        let locked = MemoryStore()
        locked.failsReads = true
        let other = LicenseManager(
            appID: Self.appID, products: Self.products, client: client, store: locked, journal: journal,
            trialStore: trialStore, registry: registry, device: device, now: { [clock] in clock.now }, uptime: { [clock] in clock.uptime }
        )
        other.load()
        #expect(other.freshInstall == nil, "the license record could not be read")
    }
}
