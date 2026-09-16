import MacPaperCore
import SwiftUI

/// The panel's content, shared by the notch panel and the menu-bar popover:
/// the preview, the side and pair controls, the generator and its
/// parameters, the finishes and the composition, the actions, the
/// favorites, the footer. While the license restricts the feature, the
/// license card takes the generator's and the actions' place
/// (design/products/macpaper.md).
struct WallpaperPanelView: View {
    @Bindable var model: AppModel
    /// Squared top corners: the notch panel meets the menu bar.
    var attachedToNotch = false
    /// The notch panel follows the width setting; the popover is fixed.
    var width: CGFloat = PanelMetrics.popoverWidth
    /// A slot above the preview for the licensing wiring (the trial pill
    /// or the license badge); nil draws nothing.
    var header: AnyView? = nil
    let showSettings: () -> Void
    let quit: () -> Void
    /// The disclosures' initial state (the preview harness opens them).
    var expandFinishes = false
    var expandFavorites = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsFinishes = false
    @State private var showsFavorites = false

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            if let header { header }
            PreviewCard(model: model, width: width - 2 * Brand.Space.s16)
            if let restriction = model.license.restriction() {
                LicenseCard(restriction: restriction, license: model.license)
            } else {
                SideAndPairRow(model: model)
                SegmentedControl(title: "Generator", selection: $model.generatorKind, choices: GeneratorKind.allCases.map { ($0, $0.title) })
                ParametersView(model: model)
                DisclosureRow(title: "Finishes", detail: finishSummary, isExpanded: $showsFinishes) {
                    FinishEditor(model: model)
                }
                CompositionRow(model: model)
                ActionRow(model: model)
            }
            if let status = model.status {
                StatusText(status: status)
                    .transition(.opacity)
            }
            if !model.favoriteList.isEmpty {
                DisclosureRow(title: "Favorites", detail: "\(model.favoriteList.count)", isExpanded: $showsFavorites) {
                    FavoritesStrip(model: model)
                }
            }
            Footer(model: model, showSettings: showSettings, quit: quit)
        }
        .padding(Brand.Space.s16)
        .frame(width: width)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: model.status)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: model.generatorKind)
        .background(Brand.canvas.opacity(0.001))
        .onAppear {
            if expandFinishes { showsFinishes = true }
            if expandFavorites { showsFavorites = true }
        }
    }

    private var finishSummary: String {
        var parts: [String] = []
        if model.draft.finish.tint != nil { parts.append("tint") }
        if model.draft.finish.duotone != nil { parts.append("duotone") }
        if model.draft.finish.gradientMap != nil { parts.append("map") }
        if model.draft.grain > 0 { parts.append("grain \(Int(model.draft.grain * 100))%") }
        if model.draft.finish.topShade > 0 { parts.append("top shade") }
        return parts.isEmpty ? "none" : parts.joined(separator: " · ")
    }
}

enum PanelMetrics {
    static let popoverWidth: CGFloat = 420
}

// MARK: - Preview

private struct PreviewCard: View {
    let model: AppModel
    /// The card's width: the preview's height follows the display's aspect
    /// from it, so the card never gives way when the panel is squeezed.
    let width: CGFloat

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
            .frame(width: width, height: (width / size.aspectRatio).rounded())
            .overlay { focusOverlay }
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
                if let readability = model.readability, model.previewWallpaper == model.draft {
                    Tag(text: readability.reads ? "Menu bar: reads" : "Menu bar: low contrast", warning: !readability.reads)
                }
            }
            .padding(Brand.Space.s8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previewLabel)
    }

    /// The focal point of a framed image: a ring the user drags.
    @ViewBuilder
    private var focusOverlay: some View {
        if model.framesImage, let focus = model.focus {
            GeometryReader { proxy in
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().fill(.black.opacity(0.25)))
                    .frame(width: 22, height: 22)
                    .shadow(radius: 2)
                    .position(x: focus.x * proxy.size.width, y: focus.y * proxy.size.height)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        model.setFocus(Point(x: value.location.x / proxy.size.width, y: value.location.y / proxy.size.height))
                    })
                    .accessibilityLabel("Focal point")
                    .accessibilityHint("Drag to choose what the crop keeps")
            }
        }
    }

    private var previewLabel: String {
        var parts = ["Preview: \(model.draft.generator.kind.title), seed \(model.draft.seedText), \(model.previewSide.title) side"]
        if let display = model.currentDisplay { parts.append("for \(display.name)") }
        if model.currentApplied == model.draft { parts.append("currently on the desktop") }
        if let readability = model.readability { parts.append(readability.verdict) }
        return parts.joined(separator: ", ")
    }
}

private struct Tag: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text.uppercased())
            .font(Brand.mono(10, medium: true))
            .tracking(0.5)
            .foregroundStyle(warning ? Color.black : .white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(warning ? Brand.warningSolid : Color.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - Side and pair

/// Light / Dark for the side being edited, the pair mode, and the dark
/// side's derive/reset.
private struct SideAndPairRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            SegmentedControl(title: "Side", selection: Binding(get: { model.shownSide }, set: { model.editingSide = $0 }), choices: Side.allCases.map { ($0, $0.title) })
                .frame(width: 130)
            Menu {
                Button("Still") { model.setPair(.still) }
                Button("Light / Dark pair") { model.setPair(.lightDark) }
                Menu("Time of day") {
                    ForEach(PairMode.frameCounts, id: \.self) { frames in
                        Button("\(frames) frames") { model.setPair(.timeOfDay(frames: frames)) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.draft.pair.title).font(Brand.body(12))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Brand.textPrimary)
                .padding(.horizontal, Brand.Space.s8)
                .frame(minHeight: 28)
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.borderSubtle.opacity(0.6), lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Pair: \(model.draft.pair.title)")
            .help("Still, a light/dark pair, or a time-of-day set")
            Spacer(minLength: 0)
            if model.shownSide == .dark {
                if model.draft.hasCustomDark {
                    Button("Derive again") { model.resetDarkSide() }
                        .buttonStyle(LinkButtonStyle())
                        .help("Make the dark side from the light one again")
                } else {
                    Text("derived from light")
                        .font(Brand.mono(10))
                        .foregroundStyle(Brand.textSecondary)
                }
            } else if model.readability?.reads == false, model.draft.finish.topShade == 0 {
                Button("Shade the top") { model.shadeTheTop() }
                    .buttonStyle(LinkButtonStyle())
                    .help("Shade the menu-bar strip so its text reads")
            }
        }
    }
}

// MARK: - Finishes and composition

private struct FinishEditor: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            LabeledSlider(title: "Grain", value: model.binding(\.grain), range: 0...1, format: { "\(Int($0 * 100))%" })
            LabeledSlider(title: "Top shade", value: model.binding(\.finish.topShade), range: 0...1, format: { "\(Int($0 * 100))%" })
            OptionalFinishRow(title: "Tint", isOn: Binding(get: { model.draft.finish.tint != nil }, set: { on in model.setFinish { $0.tint = on ? Tint(color: model.draft.generator.colors.first ?? .black, amount: 0.4) : nil } })) {
                if let tint = model.draft.finish.tint {
                    ColorWell(title: "Tint color", color: Binding(get: { tint.color }, set: { color in model.setFinish { $0.tint = Tint(color: color, amount: tint.amount) } }))
                    Slider(value: Binding(get: { tint.amount }, set: { amount in model.setFinish { $0.tint = Tint(color: tint.color, amount: amount) } }), in: 0...1) { Text("Tint amount") }
                        .labelsHidden()
                        .tint(Brand.accentSolid)
                    Text("\(Int(tint.amount * 100))%").font(Brand.mono(11)).foregroundStyle(Brand.textSecondary).frame(width: 44, alignment: .trailing)
                }
            }
            OptionalFinishRow(title: "Duotone", isOn: Binding(get: { model.draft.finish.duotone != nil }, set: { on in model.setFinish { $0.duotone = on ? Duotone(shadow: RGBAColor(hex: 0x242B55), highlight: RGBAColor(hex: 0xFFD528)) : nil } })) {
                if let duotone = model.draft.finish.duotone {
                    Text("Shadow").font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
                    ColorWell(title: "Shadow", color: Binding(get: { duotone.shadow }, set: { color in model.setFinish { $0.duotone = Duotone(shadow: color, highlight: duotone.highlight) } }))
                    Text("Highlight").font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
                    ColorWell(title: "Highlight", color: Binding(get: { duotone.highlight }, set: { color in model.setFinish { $0.duotone = Duotone(shadow: duotone.shadow, highlight: color) } }))
                }
            }
            OptionalFinishRow(title: "Gradient map", isOn: Binding(get: { model.draft.finish.gradientMap != nil }, set: { on in model.setFinish { $0.gradientMap = on ? [ColorStop(position: 0, color: RGBAColor(hex: 0x163A29)), ColorStop(position: 1, color: RGBAColor(hex: 0xFFF1EA))] : nil } })) {
                if let map = model.draft.finish.gradientMap {
                    ColorRow(title: "", colors: Binding(
                        get: { map.map(\.color) },
                        set: { colors in
                            let count = max(colors.count, 1)
                            model.setFinish { $0.gradientMap = colors.enumerated().map { i, color in ColorStop(position: count == 1 ? 0 : Double(i) / Double(count - 1), color: color) } }
                        }
                    ), range: GradientParameters.stopRange, labelWidth: 0)
                }
            }
        }
    }
}

/// A finish with an on/off checkbox and its controls beside it while on.
private struct OptionalFinishRow<Controls: View>: View {
    let title: String
    @Binding var isOn: Bool
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Toggle(isOn: $isOn) {
                Text(title).font(Brand.body(12)).foregroundStyle(Brand.textSecondary)
            }
            .toggleStyle(.checkbox)
            .frame(width: 110, alignment: .leading)
            if isOn { controls() }
            Spacer(minLength: 0)
        }
    }
}

private struct CompositionRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Text("Notch")
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 64, alignment: .leading)
            SegmentedControl(title: "Composition", selection: model.binding(\.composition), choices: Composition.allCases.map { ($0, $0.title) })
        }
        .help("How the wallpaper composes around the notch of the display it is applied to")
    }
}

/// A collapsible row with a summary of what is inside.
struct DisclosureRow<Content: View>: View {
    let title: String
    let detail: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: Brand.Space.s8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(Brand.textSecondary)
                    Text(title).font(Brand.body(12, weight: 600)).foregroundStyle(Brand.textPrimary)
                    Text(detail).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary).lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(detail)")
            .accessibilityAddTraits(isExpanded ? [.isSelected] : [])
            if isExpanded { content() }
        }
    }
}

// MARK: - Actions

private struct ActionRow: View {
    let model: AppModel

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
                Section("Export") {
                    ForEach(ExportKind.allCases, id: \.self) { kind in
                        Button("Export as \(kind.title)") { model.export(kind) }
                    }
                }
                Section("Share") {
                    Button("Copy link") { model.shareLink() }
                    Button("Remix (new seed)") { model.remix() }
                }
                Section {
                    Button("Never show this") { model.neverShowThis() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(!model.canAct || model.isExporting)
            .accessibilityLabel("More: export, share, never show")
            .help("Export, share, remix, never show")
        }
    }

    /// Apply, and a menu beside it: this display · all displays (while
    /// displays keep their own), every Space (kept) · this Space only.
    @ViewBuilder
    private var applyButton: some View {
        HStack(spacing: 1) {
            Button(model.isApplying ? "Applying…" : "Apply") { model.apply() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .help(model.preferences.sameOnAllDisplays ? "Apply to every display, every Space" : "Apply to \(model.currentDisplay?.name ?? "this display")")
            Menu {
                if !model.preferences.sameOnAllDisplays, model.displays.count > 1 {
                    Button("This display (\(model.currentDisplay?.name ?? "current"))") { model.apply() }
                    Button("All displays") { model.apply(ApplyTarget(scope: .allDisplays)) }
                    Divider()
                }
                Button("Every Space (kept)") { model.apply() }
                Button("This Space only") { model.apply(ApplyTarget(thisSpaceOnly: true)) }
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
            .accessibilityLabel("Apply to which display or Space")
        }
        .disabled(!model.canAct)
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

// MARK: - Favorites

/// The favorites as small renders: click loads one, the x removes it.
private struct FavoritesStrip: View {
    let model: AppModel
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        if previewRendering {
            // `ImageRenderer` draws no scroll view: the first few, in a row.
            HStack(spacing: Brand.Space.s8) {
                ForEach(model.favoriteList.prefix(4)) { favorite in
                    FavoriteThumbnail(model: model, favorite: favorite)
                }
            }
            .frame(height: 64)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Brand.Space.s8) {
                    ForEach(model.favoriteList) { favorite in
                        FavoriteThumbnail(model: model, favorite: favorite)
                    }
                }
            }
            .frame(height: 64)
        }
    }
}

private struct FavoriteThumbnail: View {
    let model: AppModel
    let favorite: Favorite
    @State private var image: CGImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                model.load(favorite)
            } label: {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                    } else {
                        Brand.surface
                    }
                }
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.small + 2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.Radius.small + 2, style: .continuous).strokeBorder(favorite.wallpaper == model.draft ? Brand.accentSolid : Brand.borderSubtle.opacity(0.6), lineWidth: favorite.wallpaper == model.draft ? 2 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Favorite: \(favorite.wallpaper.generator.kind.title), seed \(favorite.wallpaper.seedText)")
            .help("Load this favorite")
            Button {
                model.removeFavorite(favorite)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(3)
            .accessibilityLabel("Remove from favorites")
        }
        .task(id: favorite.id) {
            let renderer = model.renderer
            let wallpaper = favorite.wallpaper
            image = await Task.detached(priority: .utility) {
                renderer.render(wallpaper, side: .light, context: RenderContext(size: PixelSize(width: 192, height: 120), menuBarStrip: 4)).cgImage
            }.value
        }
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
/// never a price. Wired to the controller by the licensing ticket.
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
                    if index == 0 {
                        Button(action.title) { license.perform(action) }
                            .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button(action.title) { license.perform(action) }
                            .secondaryAction()
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
