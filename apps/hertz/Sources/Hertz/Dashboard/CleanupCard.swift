import AppKit
import HertzCore
import SwiftUI

/// A read-only scan of known regenerable developer caches: what they are,
/// how big, and a way to reveal each in the Finder. Hertz removes nothing.
struct CleanupCard: View {
    let model: CleanupModel

    private var visible: [CleanupCandidate] {
        Array(model.scan.candidates.prefix(6))
    }

    var body: some View {
        Card {
            CardHeader("Cleanup scout") {
                if model.hasCandidates {
                    Button {
                        model.copyReport()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(CardActionStyle())
                    .help("Copy the cleanup report")
                    .accessibilityLabel("Copy the cleanup report")
                }
                Button(model.hasCandidates ? "Rescan" : "Scan") {
                    model.scanNow()
                }
                .buttonStyle(LinkButtonStyle())
                .disabled(model.isScanning)
            }

            HStack(alignment: .firstTextBaseline, spacing: Brand.Space.s8) {
                if model.hasCandidates {
                    Text(Format.bytes(model.scan.totalBytes))
                        .font(Brand.mono(15, medium: true))
                        .foregroundStyle(Brand.textPrimary)
                }
                Text(model.status)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if visible.isEmpty {
                DetailLine("Read-only: known caches under your home folder, sizes only.")
            } else {
                VStack(alignment: .leading, spacing: Brand.Space.s4) {
                    ForEach(visible) { candidate in
                        CleanupRow(candidate: candidate) { model.reveal(candidate) }
                    }
                }
                if model.scan.candidates.count > visible.count {
                    Note("+\(model.scan.candidates.count - visible.count) more in the report")
                }
                DetailLine("Hertz never deletes; reveal a folder and decide in the Finder.")
            }
        }
    }
}

private struct CleanupRow: View {
    let candidate: CleanupCandidate
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Image(systemName: "folder")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(candidate.title)
                        .font(Brand.body(13))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(candidate.category.uppercased())
                        .font(Brand.mono(9, medium: true))
                        .foregroundStyle(Brand.textSecondary)
                }
                Text(candidate.reason)
                    .font(Brand.body(11))
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Brand.Space.s8)
            Text(Format.bytes(candidate.bytes))
                .font(Brand.mono(12, medium: true))
                .foregroundStyle(Brand.textPrimary)
            Button(action: reveal) {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(CardActionStyle())
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(candidate.title) in Finder")
        }
        .frame(height: 24)
    }
}
