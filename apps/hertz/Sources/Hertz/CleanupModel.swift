import AppKit
import Foundation
import HertzCore
import Observation

/// The Cleanup Scout's state: a user-started scan of known regenerable caches.
/// Read-only by design; removing anything is left to the user in the Finder.
@Observable
final class CleanupModel {
    var scan = CleanupScan()
    var isScanning = false
    var status = "Scan for regenerable caches."

    @ObservationIgnored private let scout = CleanupScout()

    var hasCandidates: Bool {
        !scan.candidates.isEmpty
    }

    func scanNow() {
        guard !isScanning else { return }
        isScanning = true
        status = "Scanning known caches…"

        let scout = scout
        Task {
            let result = await Task.detached {
                scout.scan()
            }.value
            scan = result
            isScanning = false
            status = result.candidates.isEmpty
                ? "No regenerable caches found."
                : "\(Format.bytes(result.totalBytes)) in \(result.candidates.count) cache group\(result.candidates.count == 1 ? "" : "s"), ready to review."
        }
    }

    func copyReport() {
        copyToPasteboard(scout.report(for: scan))
        status = "Cleanup report copied."
    }

    func reveal(_ candidate: CleanupCandidate) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: candidate.path)
        ])
    }
}
