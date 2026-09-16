import MacPaperCore
import SwiftUI

/// Export: PNG, SVG, the HEIC pair and the phone pair, at the display's
/// pixel size; then Copy link, Remix and Never show this.
struct ExportSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ExportKind.allCases, id: \.self) { kind in
                ExportRow(kind: kind, model: model)
                Rectangle().fill(Brand.Panel.hairline).frame(height: 1)
            }
            Text("Files land in \(model.preferences.exportFolder.path(percentEncoded: false)); a folder that is gone or read-only asks where instead.")
                .font(Brand.body(11))
                .foregroundStyle(Brand.Panel.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Brand.Space.s12)
            PanelMonoLabel("Share")
                .padding(.top, Brand.Space.s8)
            ActionRow(title: "Copy link", detail: "The whole document as macpaper://s/…, never an image.", symbol: "link") { model.shareLink() }
            ActionRow(title: "Remix", detail: "A new seed on the same document.", symbol: "dice") { model.remix() }
            ActionRow(title: "Never show this", detail: "Shuffle never picks it again; also dropped from the library.", symbol: "eye.slash") { model.neverShowThis() }
        }
        .disabled(!model.canAct)
    }
}

private struct ExportRow: View {
    let kind: ExportKind
    let model: AppModel

    var body: some View {
        HStack(spacing: Brand.Space.s12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                    .font(Brand.body(13, weight: 600))
                    .foregroundStyle(Brand.Panel.textPrimary)
                Text(detail)
                    .font(Brand.body(11))
                    .foregroundStyle(Brand.Panel.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Brand.Space.s8)
            Button("Export") { model.export(kind) }
                .buttonStyle(PanelSecondaryButtonStyle())
                .disabled(model.isExporting)
                .accessibilityLabel("Export as \(kind.title)")
        }
        .frame(minHeight: PanelLayout.listRowHeight)
    }

    private var detail: String {
        let size = model.currentContext.size
        switch kind {
        case .png: return "A still at \(size.width)×\(size.height), the display's pixels."
        case .svg: return "Vector where the generator is; an embedded PNG otherwise."
        case .heicPair: return "The light and dark sides in one file macOS switches by itself."
        case .phonePair: return "The desktop still and a \(PhoneCanvas.size.width)×\(PhoneCanvas.size.height) portrait for AirDrop."
        }
    }
}

private struct ActionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Brand.Space.s12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Brand.Panel.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Brand.Panel.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Brand.body(13, weight: 600))
                        .foregroundStyle(Brand.Panel.textPrimary)
                    Text(detail)
                        .font(Brand.body(11))
                        .foregroundStyle(Brand.Panel.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
