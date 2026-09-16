import AppKit
import OpenNotesCore
import SwiftUI

/// Where the notes live: On this Mac / iCloud Drive / Other folder…, the
/// same three rows in Settings → General and the guide's files step
/// (design/products/opennotes.md, "Storage"). iCloud Drive is offered
/// only while it is reachable; otherwise its row says what to do. The
/// choice is asked at the click (`AppModel.setStorage`, the license) and
/// "Other folder…" opens the chooser, so a cancelled panel changes
/// nothing.
struct StorageChoiceView: View {
    let current: StorageChoice
    let iCloudAvailable: Bool
    /// The folder in use, under the selected row.
    let folderPath: String
    /// The folder cannot be found: said under the selected row.
    let folderMissing: Bool
    let readOnly: Bool
    /// What the last switch copied, under the rows, until the next switch.
    var notice: String?
    let onChoose: (StorageChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            ForEach(StorageChoice.allCases, id: \.self) { choice in
                row(choice)
            }
            if let notice {
                Text(notice)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notes folder")
    }

    private func row(_ choice: StorageChoice) -> some View {
        let selected = choice == current
        let enabled = !readOnly && (choice != .iCloudDrive || iCloudAvailable)
        return Button {
            guard enabled, choice != current || choice == .other else { return }
            onChoose(choice)
        } label: {
            HStack(alignment: .top, spacing: Brand.Space.s8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(selected ? Brand.accentSolid : Brand.textSecondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(Brand.body(14))
                        .foregroundStyle(enabled ? Brand.textPrimary : Brand.textSecondary)
                    if let detail = detail(for: choice, selected: selected) {
                        Text(detail)
                            .font(Brand.body(12))
                            .foregroundStyle(Brand.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(enabled ? "" : (readOnly ? "Changing the folder waits for a license" : ICloudDrive.unavailableNotice))
    }

    private func detail(for choice: StorageChoice, selected: Bool) -> String? {
        if choice == .iCloudDrive, !iCloudAvailable { return ICloudDrive.unavailableNotice }
        guard selected else {
            switch choice {
            case .thisMac: return "~/Documents/OpenNotes"
            case .iCloudDrive: return "iCloud Drive › OpenNotes, on every Mac signed in to this iCloud"
            case .other: return "Any folder, an Obsidian vault included"
            }
        }
        var text = folderPath
        if folderMissing { text += " — can’t find this folder; nothing is read or written until it is back or another is chosen." }
        return text
    }
}

/// The open panel for "Other folder…", shared by Settings and the guide.
/// Nothing is moved: the folder is read as it is.
enum FolderChooser {
    @MainActor static func present(current: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = current
        panel.prompt = "Use this folder"
        panel.message = "Notes are read from and written to this folder as .md files. The notes you have are copied there; files are never moved."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// One line under All Notes' list about iCloud, while the folder is
/// iCloud's: "In iCloud Drive · up to date". Nothing otherwise.
struct StorageStatusRow: View {
    let line: String

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Image(systemName: "icloud")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Brand.textSecondary)
            Text(line)
                .font(Brand.mono(11))
                .foregroundStyle(Brand.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
