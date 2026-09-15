import AppKit
import HertzCore
import SwiftUI

/// Read-only scan of known regenerable developer caches, then a confirmed
/// clean. Nothing is removed without the inline confirmation.
struct CleanupCard: View {
    let model: CleanupModel
    @State private var confirming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    confirming = false
                    model.scanNow()
                }
                .buttonStyle(LinkButtonStyle())
                .disabled(model.isScanning || model.isCleaning)
                if model.hasCandidates {
                    Button("Clean…") {
                        withAnimation(Motion.standard(reduceMotion: reduceMotion)) { confirming = true }
                    }
                    .buttonStyle(LinkButtonStyle())
                    .disabled(model.isCleaning || model.isScanning || confirming)
                }
            }

            if confirming {
                ConfirmPanel(count: model.scan.candidates.count, bytes: model.scan.totalBytes) {
                    withAnimation(Motion.standard(reduceMotion: reduceMotion)) { confirming = false }
                    model.cleanSafeCandidates()
                } cancel: {
                    withAnimation(Motion.standard(reduceMotion: reduceMotion)) { confirming = false }
                }
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
                DetailLine("Known caches under your home folder only; protected paths are refused.")
            } else {
                VStack(alignment: .leading, spacing: Brand.Space.s4) {
                    ForEach(visible) { candidate in
                        CleanupRow(candidate: candidate) { model.reveal(candidate) }
                    }
                }
                if model.scan.candidates.count > visible.count {
                    Note("+\(model.scan.candidates.count - visible.count) more in the report")
                }
            }
        }
    }
}

private struct ConfirmPanel: View {
    let count: Int
    let bytes: UInt64
    let clean: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            Text("Clean \(count) cache group\(count == 1 ? "" : "s"), \(Format.bytes(bytes))?")
                .font(Brand.body(13, weight: 600))
                .foregroundStyle(Brand.textPrimary)
            Text("Only the listed regenerable cache contents are removed. Documents, preferences, app support and system paths are never touched.")
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Brand.Space.s8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Clean Caches", action: clean)
                    .buttonStyle(DestructiveButtonStyle())
            }
        }
        .padding(Brand.Space.s12)
        .background(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).fill(Brand.dangerSubtle))
    }
}

private struct CleanupRow: View {
    let candidate: CleanupCandidate
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Image(systemName: "checkmark.shield")
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
