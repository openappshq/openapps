import MacPaperCore
import SwiftUI

/// The panel's content, shared by the notch panel and the menu-bar popover:
/// the preview, the generator and its parameters, the actions, the footer.
/// While the license restricts the feature, the license card takes the
/// generator's and the actions' place (design/products/macpaper.md).
struct WallpaperPanelView: View {
    @Bindable var model: AppModel
    /// Squared top corners: the notch panel meets the menu bar.
    var attachedToNotch = false
    /// The notch panel follows the width setting; the popover is fixed.
    var width: CGFloat = PanelMetrics.popoverWidth
    let showSettings: () -> Void
    let quit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            // The trial pill while there is something to say (official
            // builds, not simply licensed): asked on every body.
            if let badge = model.license.badge() {
                HStack {
                    Spacer()
                    LicensePill(label: badge, action: model.license.openLicense)
                }
            }
            PreviewCard(model: model)
            if let restriction = model.license.restriction() {
                LicenseCard(restriction: restriction, license: model.license)
            } else {
                GeneratorPicker(model: model)
                ParametersView(model: model)
                GrainSlider(model: model)
                ActionRow(model: model)
            }
            if let status = model.status {
                StatusText(status: status)
                    .transition(.opacity)
            }
            UpdateHintRow(updates: model.updates)
            Footer(model: model, showSettings: showSettings, quit: quit)
        }
        .padding(Brand.Space.s16)
        .frame(width: width)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: model.status)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: model.generatorKind)
        .background(Brand.canvas.opacity(0.001))
    }
}

enum PanelMetrics {
    static let popoverWidth: CGFloat = 420
}

// MARK: - Preview

private struct PreviewCard: View {
    let model: AppModel

    var body: some View {
        let size = model.previewSize
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = model.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Brand.surface
                }
            }
            .aspectRatio(size.aspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.borderSubtle.opacity(0.6), lineWidth: 1))
            HStack(spacing: Brand.Space.s8) {
                if let display = model.currentDisplay, model.displaysDiffer || model.displays.count > 1 {
                    Tag(text: display.name)
                }
                if model.currentApplied == model.draft {
                    Tag(text: "On the desktop")
                } else if model.previewWallpaper != model.draft {
                    Tag(text: "Rendering…")
                }
            }
            .padding(Brand.Space.s8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previewLabel)
    }

    private var previewLabel: String {
        var parts = ["Preview: \(model.draft.generator.kind.title), seed \(model.draft.seedText)"]
        if let display = model.currentDisplay { parts.append("for \(display.name)") }
        if model.currentApplied == model.draft { parts.append("currently on the desktop") }
        return parts.joined(separator: ", ")
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Brand.mono(10, medium: true))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - Generator

private struct GeneratorPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        SegmentedControl(title: "Generator", selection: $model.generatorKind, choices: GeneratorKind.allCases.map { ($0, $0.title) })
    }
}

private struct GrainSlider: View {
    @Bindable var model: AppModel

    var body: some View {
        LabeledSlider(title: "Grain", value: $model.draft.grain, range: 0...1, format: { "\(Int($0 * 100))%" })
    }
}

// MARK: - Actions

private struct ActionRow: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Button("Shuffle") { model.shuffle() }
                .secondaryAction()
                .disabled(!model.canAct)
                .help("A random wallpaper, applied now")
            applyButton
            Button {
                model.toggleFavorite()
            } label: {
                Image(systemName: model.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.isFavorite ? Brand.accentText : Brand.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isFavorite ? "Remove from favorites" : "Add to favorites")
            .help(model.isFavorite ? "Remove from favorites" : "Add to favorites")
            Menu {
                ForEach(WallpaperExport.Format.allCases, id: \.self) { format in
                    Button("Export as \(format.title)") { model.export(format) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(!model.canAct || model.isExporting)
            .accessibilityLabel("Export")
            .help("Export as PNG or SVG")
        }
    }

    /// One button while every display gets the same document; a split
    /// choice (this display · all displays) otherwise.
    @ViewBuilder
    private var applyButton: some View {
        if model.preferences.sameOnAllDisplays || model.displays.count < 2 {
            Button(model.isApplying ? "Applying…" : "Apply") { model.apply() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.canAct)
                .keyboardShortcut(.defaultAction)
        } else {
            HStack(spacing: 1) {
                Button(model.isApplying ? "Applying…" : "Apply") { model.apply() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .help("Apply to \(model.currentDisplay?.name ?? "this display")")
                Menu {
                    Button("This display (\(model.currentDisplay?.name ?? "current"))") { model.apply() }
                    Button("All displays") { model.apply(.allDisplays) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Brand.accentOn)
                        .frame(width: 24, height: 32)
                        .background(Brand.accentSolid, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("Apply to which display")
            }
            .disabled(!model.canAct)
        }
    }
}

private struct StatusText: View {
    let status: StatusLine

    var body: some View {
        HStack(alignment: .top, spacing: Brand.Space.s8) {
            Image(systemName: status.tone == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(status.tone == .error ? Brand.dangerSolid : Brand.successSolid)
            Text(status.text)
                .font(Brand.body(12))
                .foregroundStyle(status.tone == .error ? Brand.dangerSolid : Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Footer

private struct Footer: View {
    let model: AppModel
    let showSettings: () -> Void
    let quit: () -> Void
    @State private var seedText = ""
    @State private var editingSeed = false
    @FocusState private var seedFocused: Bool

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            MonoLabel("Seed")
            if editingSeed {
                TextField("Seed", text: $seedText)
                    .textFieldStyle(.plain)
                    .font(Brand.mono(11))
                    .frame(width: 130)
                    .focused($seedFocused)
                    .onSubmit { commitSeed() }
                    .onExitCommand { editingSeed = false }
                    .accessibilityLabel("Seed")
            } else {
                Button {
                    seedText = model.draft.seedText
                    editingSeed = true
                    seedFocused = true
                } label: {
                    Text(model.draft.seedText)
                        .font(Brand.mono(11))
                        .foregroundStyle(Brand.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Seed \(model.draft.seedText); activate to edit")
                .help("Click to type a seed")
            }
            Button {
                model.reseed()
            } label: {
                Image(systemName: "dice")
            }
            .buttonStyle(CardActionStyle())
            .disabled(model.license.restriction() != nil)
            .accessibilityLabel("New seed")
            .help("New seed")
            Spacer()
            Button("Settings…", action: showSettings)
                .buttonStyle(LinkButtonStyle())
                .keyboardShortcut(",", modifiers: .command)
            Button("Quit", action: quit)
                .buttonStyle(LinkButtonStyle())
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func commitSeed() {
        if model.setSeed(seedText) {
            editingSeed = false
        } else {
            model.show("A seed is a whole number up to 18446744073709551615.", tone: .error)
        }
    }
}

// MARK: - License card

/// The feature is off: the state in LICENSING.md's words and a way out,
/// never a price. The actions go through `LicenseStatus`, which the
/// official build binds to the license controller (LicensingLaunch.swift).
struct LicenseCard: View {
    let restriction: LicenseRestriction
    let license: LicenseStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            MonoLabel("License")
            Text(restriction.title)
                .font(Brand.display(20))
                .foregroundStyle(Brand.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(restriction.detail)
                .font(Brand.body(13))
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Brand.Space.s8) {
                ForEach(Array(restriction.actions.enumerated()), id: \.offset) { index, action in
                    // The website states the price; the button never does.
                    let title = action == .buy && !license.canBuy ? "Buy a license — coming soon" : action.title
                    if index == 0 {
                        Button(title) { license.perform(action) }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(action == .buy && !license.canBuy)
                    } else {
                        Button(title) { license.perform(action) }
                            .secondaryAction()
                            .disabled(action == .buy && !license.canBuy)
                    }
                }
            }
            .disabled(license.isBusy)
        }
        .padding(Brand.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Brand.Radius.control)
        .accessibilityElement(children: .contain)
    }
}
