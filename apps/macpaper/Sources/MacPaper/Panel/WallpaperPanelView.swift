import MacPaperCore
import SwiftUI

/// The column: an icon rail on the left and, beside it, the section it
/// points at. One column, wherever it opens from (the notch, the menu-bar
/// item). Dark in both appearances and opaque (`PanelTheme`): it hangs
/// from the notch, so it is a piece of the same black, and no wallpaper
/// reaches a label. Every change reaches the desktop on its own (live
/// apply), so there is no Apply: the header says where changes land, the
/// rail carries Shuffle and Collapse, the footer the seed. While the
/// license restricts the feature, the license card takes the place of
/// the sections that make wallpapers; Library and History still browse
/// (design/products/macpaper.md, "The panel").
///
/// Given a height, the column is that tall and the section scrolls inside
/// it while the header, the preview, the rail and the footer stay put;
/// the natural height (what the content would take unscrolled) is
/// reported through `onNaturalHeight` so the window can follow the
/// content up to the display's cap.
struct WallpaperPanelView: View {
    @Bindable var model: AppModel
    /// The column's width, from the setting and the widest control.
    var width: CGFloat = PanelMetrics.width(for: .regular)
    /// The column's height; nil sizes to the content (the harness, and
    /// the measurement the window takes before it shows).
    var height: CGFloat? = nil
    /// A slot in the header for the licensing wiring (the trial pill or
    /// the license badge); nil draws nothing.
    var header: AnyView? = nil
    let showSettings: () -> Void
    let quit: () -> Void
    /// Collapse: closes the panel.
    var dismiss: () -> Void = {}
    /// The height the content would take unscrolled, as it lays out.
    var onNaturalHeight: ((CGFloat) -> Void)? = nil
    @Environment(\.previewRendering) private var previewRendering
    @Environment(\.previewScrollOffset) private var previewScrollOffset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The drop target is AppKit-backed: `ImageRenderer` cannot draw a
        // view that carries one, so the harness leaves it off.
        if previewRendering {
            column
        } else {
            column.onDrop(of: [.fileURL], isTargeted: nil) { providers in
                // A `.macpaper` file dropped anywhere on the column is imported.
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == RecipeDocument.fileExtension else { return }
                    Task { @MainActor in model.importRecipe(at: url) }
                }
                return true
            }
        }
    }

    private var column: some View {
        HStack(alignment: .top, spacing: 0) {
            PanelRail(model: model, dismiss: dismiss)
                .frame(width: PanelLayout.railWidth)
                .frame(maxHeight: .infinity)
            Rectangle().fill(Brand.Panel.hairline).frame(width: 1)
            pane
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .frame(width: width)
        .frame(height: height, alignment: .top)
        .background(Brand.Panel.ground)
        .environment(\.colorScheme, .dark)
        .animation(Motion.standard(reduceMotion: reduceMotion), value: model.status)
        .onPreferenceChange(SectionMetrics.self) { metrics in
            // Delivered on the main thread; the closure is only nominally
            // nonisolated.
            MainActor.assumeIsolated { report(metrics) }
        }
    }

    /// What the content would take unscrolled: the column less the
    /// section's viewport, plus the section's own height.
    private func report(_ metrics: SectionMetrics) {
        guard let height, let onNaturalHeight, metrics.viewport > 0 else { return }
        onNaturalHeight((height - metrics.viewport + metrics.content).rounded(.up))
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(model: model)
                .padding(.horizontal, PanelLayout.paneInset)
                .padding(.top, Brand.Space.s12)
            if let header {
                // The licensing slot: the trial pill on its own line under the title.
                header
                    .padding(.horizontal, PanelLayout.paneInset)
                    .padding(.bottom, Brand.Space.s4)
            }
            PreviewCard(model: model, width: PanelLayout.paneWidth(columnWidth: width))
                .padding(.horizontal, PanelLayout.paneInset)
                .padding(.top, Brand.Space.s8)
            // The section takes what is left (the scroll view, or the
            // harness's clipped stack, is the one flexible row); the status
            // line, the update row and the footer sit under it.
            sectionBody
            if let status = model.status {
                StatusText(status: status)
                    .padding(.horizontal, PanelLayout.paneInset)
                    .padding(.bottom, Brand.Space.s8)
                    .transition(.opacity)
            }
            UpdateHintRow(updates: model.updates)
                .padding(.horizontal, PanelLayout.paneInset)
            Footer(model: model, showSettings: showSettings, quit: quit)
                .padding(.horizontal, PanelLayout.paneInset)
                .padding(.bottom, Brand.Space.s12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The section, scrolling when taller than the column (the harness
    /// draws no scroll view: a plain stack, clipped by the column, shown
    /// scrolled by `previewScrollOffset`). Its own height and its
    /// viewport's are reported for `onNaturalHeight`.
    @ViewBuilder
    private var sectionBody: some View {
        let content = SectionContent(model: model, width: PanelLayout.paneWidth(columnWidth: width))
            .padding(.horizontal, PanelLayout.paneInset)
            .padding(.vertical, Brand.Space.s12)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SectionMetrics.self, value: SectionMetrics(content: proxy.size.height, viewport: 0))
            })
        if height == nil {
            content
        } else if previewRendering {
            // No scroll view under `ImageRenderer`: the overflow is clipped, the footer stays.
            Color.clear
                .overlay(alignment: .top) { content.offset(y: -previewScrollOffset) }
                .clipped()
        } else {
            ScrollView(.vertical, showsIndicators: false) { content }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SectionMetrics.self, value: SectionMetrics(content: 0, viewport: proxy.size.height))
                })
        }
    }
}

/// The section's laid-out height and its viewport's, each reported by
/// the view that knows it; the two reports combine.
private struct SectionMetrics: SwiftUI.PreferenceKey, Equatable, Sendable {
    var content: CGFloat = 0
    var viewport: CGFloat = 0

    static let defaultValue = SectionMetrics()

    static func reduce(value: inout SectionMetrics, nextValue: () -> SectionMetrics) {
        let next = nextValue()
        if next.content > 0 { value.content = next.content }
        if next.viewport > 0 { value.viewport = next.viewport }
    }
}

extension EnvironmentValues {
    /// How far the harness shows the section scrolled, in points; the
    /// live column scrolls for real.
    @Entry var previewScrollOffset: CGFloat = 0
}

/// The column's widths: the setting, or wider when a segmented control
/// needs it to keep every label on one line; and its natural height.
enum PanelMetrics {
    /// The height the column takes unscrolled, measured off-screen: what
    /// the window opens at (up to the display's cap) and what the harness
    /// draws.
    static func naturalHeight(of content: PanelContent) -> CGFloat {
        var content = content
        content.height = nil
        let hosting = NSHostingView(rootView: content.environment(\.previewRendering, true))
        hosting.appearance = NSAppearance(named: .darkAqua)
        return hosting.fittingSize.height.rounded(.up)
    }

    /// The widest segmented controls the pane draws, measured in the
    /// segment font.
    static var controlWidths: [CGFloat] {
        [
            LabelMeasure.segmentedWidth(Composition.allCases.map(\.title)),
            LabelMeasure.segmentedWidth(GradientKind.allCases.map(\.title)),
            LabelMeasure.segmentedWidth(PatternKind.allCases.map(\.title)),
            LabelMeasure.segmentedWidth(ImageFit.allCases.map(\.title)),
            LabelMeasure.segmentedWidth(ColorInterpolation.allCases.map(\.title)),
            LabelMeasure.segmentedWidth(PairChoice.allCases.map(\.title)),
            LabelMeasure.segmentedWidth(BaseKind.allCases.map(\.title)),
            LabelMeasure.segmentedWidth(Side.allCases.map(\.title)),
            LabelMeasure.segmentedWidth(FieldFamily.allCases.map(\.title)),
        ] + FieldFamily.allCases.flatMap(\.knobs).compactMap { knob -> CGFloat? in
            if case .choice(let titles) = knob.style { LabelMeasure.segmentedWidth(titles) } else { nil }
        }
    }

    static func width(for setting: PanelWidth) -> CGFloat {
        PanelLayout.columnWidth(setting: setting, controlWidths: controlWidths)
    }
}

// MARK: - Header

/// The section's title, where changes land, and the licensing slot.
private struct PanelHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            Text(model.panelSection.title)
                .font(Brand.display(18))
                .foregroundStyle(Brand.Panel.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Brand.Space.s8)
            ReachMenu(model: model)
        }
        .frame(height: PanelLayout.headerHeight)
    }
}

/// Every display · this display · this Space only: where every change
/// lands. "Same on all displays" leaves the display choice out.
private struct ReachMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        let choices = ApplyReach.available(sameOnAllDisplays: model.preferences.sameOnAllDisplays, displayCount: model.displays.count)
        Menu {
            ForEach(choices, id: \.self) { reach in
                Button {
                    model.reach = reach
                } label: {
                    Label(reach.title, systemImage: reach.symbolName)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.reach.symbolName).font(.system(size: 10, weight: .semibold))
                Text(model.reach.title).font(Brand.body(12, weight: 600)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Brand.Panel.textPrimary)
            .padding(.horizontal, Brand.Space.s8)
            .frame(height: 26)
            .background(Brand.Panel.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.Panel.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Changes land on: \(model.reach.title)")
        .help("Where every change lands: every display, this display, or this Space only")
        .onChange(of: choices) { _, next in
            if !next.contains(model.reach) { model.reach = next[0] }
        }
    }
}

// MARK: - Sections

private struct SectionContent: View {
    @Bindable var model: AppModel
    let width: CGFloat

    var body: some View {
        if let restriction = model.license.restriction(), model.panelSection.makesWallpapers {
            LicenseCard(restriction: restriction, license: model.license)
        } else {
            switch model.panelSection {
            case .library: LibrarySection(model: model)
            case .generators: GeneratorsSection(model: model)
            case .palette: PaletteSection(model: model, width: width)
            case .parameters: ParametersSection(model: model)
            case .effects: EffectsSection(model: model)
            case .export: ExportSection(model: model)
            case .history: HistorySection(model: model)
            }
        }
    }
}

extension PanelSection {
    /// The sections the license card replaces while restricted; Library
    /// and History browse, which is never gated.
    var makesWallpapers: Bool {
        switch self {
        case .library, .history: false
        case .generators, .palette, .parameters, .effects, .export: true
        }
    }
}

// MARK: - Preview

/// The current wallpaper in the display's aspect, capped in height, with
/// its tags: the display's name when there is more than one, "on the
/// desktop" while the draft is what the display shows, the menu-bar
/// readability verdict, and the focal point for a framed image.
private struct PreviewCard: View {
    let model: AppModel
    let width: CGFloat
    private let maximumHeight: CGFloat = 200

    var body: some View {
        let size = model.previewSize
        let natural = (width / size.aspectRatio).rounded()
        let height = min(natural, maximumHeight)
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = model.preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Brand.Panel.surface
                }
            }
            .frame(width: width, height: height)
            .overlay { focusOverlay }
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            // The tags on one line where they fit, the display's name on its
            // own line where they do not; never truncated.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Brand.Space.s8) { displayTag; stateTags }
                VStack(alignment: .leading, spacing: Brand.Space.s4) {
                    displayTag
                    HStack(spacing: Brand.Space.s8) { stateTags }
                }
            }
            .padding(Brand.Space.s8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(previewLabel)
    }

    @ViewBuilder
    private var displayTag: some View {
        if let display = model.currentDisplay, model.displaysDiffer || model.displays.count > 1 {
            Tag(text: display.name)
        }
    }

    @ViewBuilder
    private var stateTags: some View {
        if model.currentApplied == model.draft {
            Tag(text: "On the desktop")
        } else if model.previewWallpaper != model.draft || model.isApplying {
            Tag(text: "Rendering…")
        }
        if let readability = model.readability, model.previewWallpaper == model.draft {
            Tag(text: readability.reads ? "Menu bar: reads" : "Menu bar: low contrast", warning: !readability.reads)
        }
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
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(warning ? Color.black : .white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(warning ? Brand.warningSolid : Color.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - Status and footer

private struct StatusText: View {
    let status: StatusLine

    var body: some View {
        HStack(alignment: .top, spacing: Brand.Space.s8) {
            Image(systemName: status.tone == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(status.tone == .error ? Brand.Panel.danger : Brand.Panel.success)
            Text(status.text)
                .font(Brand.body(12))
                .foregroundStyle(status.tone == .error ? Brand.Panel.danger : Brand.Panel.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The quiet footer: the seed (click to type one, a die for a new one,
/// a pin so Shuffle keeps it), Settings… and Quit.
private struct Footer: View {
    let model: AppModel
    let showSettings: () -> Void
    let quit: () -> Void
    @State private var seedText = ""
    @State private var editingSeed = false
    @FocusState private var seedFocused: Bool

    var body: some View {
        HStack(spacing: Brand.Space.s8) {
            PanelMonoLabel("Seed")
            if editingSeed {
                TextField("Seed", text: $seedText)
                    .textFieldStyle(.plain)
                    .font(Brand.mono(12))
                    .foregroundStyle(Brand.Panel.textPrimary)
                    .frame(width: 140)
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
                        .font(Brand.mono(12))
                        .foregroundStyle(Brand.Panel.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140)
                        .fixedSize()
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
            .buttonStyle(PanelIconButtonStyle())
            .disabled(model.license.restriction() != nil)
            .accessibilityLabel("New seed")
            .help("New seed")
            PinButton(pin: .seed, model: model)
            Spacer()
            Button("Settings…", action: showSettings)
                .buttonStyle(PanelLinkButtonStyle())
                .keyboardShortcut(",", modifiers: .command)
            Button("Quit", action: quit)
                .buttonStyle(PanelLinkButtonStyle())
                .keyboardShortcut("q", modifiers: .command)
        }
        .frame(height: 32)
    }

    private func commitSeed() {
        switch model.setSeed(seedText) {
        case .set:
            editingSeed = false
        case .notANumber:
            model.show("A seed is a whole number up to 18446744073709551615.", tone: .error)
        case .refused:
            // The model's status line says why; the field stays.
            break
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
            PanelMonoLabel("License")
            Text(restriction.title)
                .font(Brand.display(20))
                .foregroundStyle(Brand.Panel.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(restriction.detail)
                .font(Brand.body(13))
                .foregroundStyle(Brand.Panel.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Brand.Space.s8) {
                ForEach(Array(restriction.actions.enumerated()), id: \.offset) { index, action in
                    // The website states the price; the button never does.
                    let title = action == .buy && !license.canBuy ? "Buy a license — coming soon" : action.title
                    if index == 0 {
                        Button(title) { license.perform(action) }
                            .buttonStyle(PanelPrimaryButtonStyle())
                            .disabled(action == .buy && !license.canBuy)
                    } else {
                        Button(title) { license.perform(action) }
                            .buttonStyle(PanelSecondaryButtonStyle())
                            .disabled(action == .buy && !license.canBuy)
                    }
                }
            }
            .disabled(license.isBusy)
        }
        .padding(Brand.Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Panel.surface, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.Panel.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
