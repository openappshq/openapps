import AppKit
import OpenNotesCore
import SwiftUI

/// The colour menu: the presets as swatches in a grid, and Custom…, which
/// opens the system colour panel (`NoteColorPanel`). The open note's
/// footer and Settings → Notes both show it, in a popover.
struct ColorChooser: View {
    let selected: NoteColor?
    var readOnly = false
    /// A "Random" row above the swatches (Settings' new-note colour).
    var offersRandom = false
    var randomSelected = false
    var onPick: (NoteColor) -> Void
    var onRandom: () -> Void = {}
    var onCustom: () -> Void

    static let columns = 7

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s12) {
            if offersRandom {
                Button(action: onRandom) {
                    HStack(spacing: Brand.Space.s8) {
                        randomSwatch
                        Text("Random").font(Brand.body(13, weight: randomSelected ? 600 : 400)).foregroundStyle(Brand.textPrimary)
                        Spacer()
                        if randomSelected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.accentText) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(readOnly)
                .accessibilityLabel("Random")
                .accessibilityAddTraits(randomSelected ? .isSelected : [])
                Divider()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: Self.columns), spacing: 6) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    swatch(color, isSelected: selected == color)
                }
            }
            Divider()
            HStack(spacing: Brand.Space.s8) {
                if let selected, selected.isCustom {
                    swatch(selected, isSelected: true)
                    Text(selected.rawValue).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }
                Spacer()
                Button("Custom…", action: onCustom)
                    .disabled(readOnly)
                    .help("Pick any colour; the Dark Mode paper and the ink follow it")
            }
        }
        .padding(Brand.Space.s12)
        .frame(width: CGFloat(Self.columns) * 34 + 2 * Brand.Space.s12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note colour")
    }

    private var randomSwatch: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: NoteColor.allCases.prefix(8).map { Color(nsColor: NSColor(hex: $0.lightFace)) } + [Color(nsColor: NSColor(hex: NoteColor.coral.lightFace))], center: .center))
            Circle().strokeBorder(Color.black.opacity(randomSelected ? 0.7 : 0.15), lineWidth: randomSelected ? 2 : 1)
        }
        .frame(width: 24, height: 24)
    }

    private func swatch(_ color: NoteColor, isSelected: Bool) -> some View {
        Button { onPick(color) } label: {
            ZStack {
                Circle().fill(Color(nsColor: NSColor(hex: color.lightFace)))
                Circle().strokeBorder(Color.black.opacity(isSelected ? 0.7 : 0.15), lineWidth: isSelected ? 2 : 1)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(nsColor: NSColor(hex: color.swatchInk)))
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(readOnly)
        .help(color.title)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The font menu: the three faces as quick picks, Use default (per note),
/// a search field over every installed family — each row set in its own
/// face, like Font Book — and the size. The open note's footer and
/// Settings → Notes both show it, in a popover.
struct FontChooser: View {
    /// The note's own typeface (nil: the default), or Settings' default.
    let selection: NoteTypeface?
    /// The size in force (the note's own or the default).
    let size: Int
    /// Whether the size shown is the note's own.
    var ownSize = false
    var readOnly = false
    /// "Use default" (per note only).
    var offersDefault = false
    var catalog: FontCatalog = .shared
    var onPick: (NoteTypeface?) -> Void
    var onSize: (Int?) -> Void = { _ in }
    @State private var query = ""
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            HStack(spacing: 6) {
                ForEach(NoteFace.allCases, id: \.self) { face in
                    quickPick(face)
                }
                if offersDefault {
                    Spacer(minLength: 4)
                    Button("Use default") { onPick(nil) }
                        .buttonStyle(.plain)
                        .font(Brand.body(12, weight: selection == nil ? 600 : 400))
                        .foregroundStyle(selection == nil ? Brand.accentText : Brand.textSecondary)
                        .disabled(readOnly)
                        .accessibilityAddTraits(selection == nil ? .isSelected : [])
                }
            }
            if previewRendering {
                // The field and the stepper are AppKit-backed and draw
                // nothing under `ImageRenderer`: flat stand-ins.
                PreviewField(placeholder: "Search fonts")
            } else {
                TextField("Search fonts", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(Brand.body(13))
                    .disabled(readOnly)
                    .accessibilityLabel("Search fonts")
            }
            familyList
            Divider()
            HStack {
                Text("Size").font(Brand.body(13)).foregroundStyle(Brand.textPrimary)
                Spacer()
                SizeStepper(size: size, readOnly: readOnly, onSize: { onSize($0) })
                if offersDefault, ownSize {
                    Button("Default") { onSize(nil) }
                        .buttonStyle(.plain)
                        .font(Brand.body(12))
                        .foregroundStyle(Brand.textSecondary)
                        .disabled(readOnly)
                        .help("Back to the default size")
                }
            }
        }
        .padding(Brand.Space.s12)
        .frame(width: 300)
        .onAppear { catalog.refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note font")
    }

    private var families: [FontCatalog.Family] { FontCatalog.matching(query, in: catalog.families) }

    private func quickPick(_ face: NoteFace) -> some View {
        let isSelected = selection == .face(face)
        return Button { onPick(.face(face)) } label: {
            Text(face.title)
                .font(Font(Brand.noteFont(NoteAppearance.Font(.face(face)), size: 12, weight: isSelected ? 600 : 400)))
                .foregroundStyle(isSelected ? Brand.accentOn : Brand.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(isSelected ? Brand.accentSolid : Brand.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(readOnly)
        .accessibilityLabel(face.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var familyList: some View {
        if previewRendering {
            // No scroll view under `ImageRenderer`: nine rows, flat, around
            // the selected family.
            let all = families
            let selectedIndex = all.firstIndex { $0.name == selection?.family } ?? 0
            let start = max(0, min(selectedIndex - 4, all.count - 9))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(all.dropFirst(start).prefix(9)) { family in row(family) }
            }
        } else if families.isEmpty {
            Text("No font matches “\(query)”.")
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(families) { family in row(family).id(family.name) }
                    }
                }
                .frame(height: 220)
                .onAppear {
                    if let family = selection?.family { proxy.scrollTo(family, anchor: .center) }
                }
            }
        }
    }

    private func row(_ family: FontCatalog.Family) -> some View {
        let isSelected = selection == .family(family.name)
        return Button { onPick(.family(family.name)) } label: {
            HStack(spacing: Brand.Space.s8) {
                Text(family.displayName)
                    .font(Brand.familyFont(family.name, size: 14) ?? Brand.body(14))
                    .foregroundStyle(Brand.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.accentText)
                }
            }
            .padding(.horizontal, Brand.Space.s8)
            .frame(height: 26)
            .background(isSelected ? Brand.accentSubtle : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(readOnly)
        .accessibilityLabel(family.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The system colour panel as the note's Custom… picker: one shared
/// panel, pointed at whichever note or setting asked last. Picks arrive
/// continuously while the user drags; each is handed on after a short
/// settle, so the file is written once per pause, and every write still
/// asks the license at the model (`AppModel.setColor`).
///
/// A pending pick belongs to the owner that was picking when it arrived:
/// it is settled to that owner before the panel is retargeted, closed or
/// the owner's note closes (`settle`), so a pick made in the last 250 ms
/// is never dropped and never reaches the next owner.
@MainActor
final class NoteColorPanel: NSObject {
    static let shared = NoteColorPanel()

    /// Who the panel is picking for; a different owner takes it over.
    private(set) var owner: String?
    private var onPick: ((NoteColor) -> Void)?
    private var pending: NoteColor?
    private var timer: Timer?
    /// The system panel is left alone in tests: the ownership and
    /// settling logic runs the same without it.
    private let usesSystemPanel: Bool
    static let settle: TimeInterval = 0.25

    init(usesSystemPanel: Bool = true) {
        self.usesSystemPanel = usesSystemPanel
    }

    /// Shows the panel at `current`, sending picks to `onPick`. A pick
    /// the previous owner has not received yet goes to it first.
    func present(for owner: String, current: NoteColor, onPick: @escaping (NoteColor) -> Void) {
        if self.owner != nil, self.owner != owner { flush() }
        self.owner = owner
        self.onPick = onPick
        guard usesSystemPanel else { return }
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(hex: current.lightFace)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NSApp.activate()
        panel.orderFront(nil)
    }

    /// Hands any pending pick to its owner now (the note is about to
    /// close or move) without closing the panel.
    func settle(ownersStartingWith prefix: String) {
        guard let owner, owner.hasPrefix(prefix) else { return }
        flush()
    }

    /// Closes the panel if `owner` still has it, its pending pick
    /// delivered first.
    func dismiss(for owner: String) {
        guard self.owner == owner else { return }
        close()
    }

    /// Closes the panel if any owner with the prefix has it (the deck
    /// folding up: every note), the pending pick delivered first.
    func dismiss(ownersStartingWith prefix: String) {
        guard let owner, owner.hasPrefix(prefix) else { return }
        close()
    }

    private func close() {
        flush()
        owner = nil
        onPick = nil
        if usesSystemPanel, NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }

    var isPresented: Bool {
        usesSystemPanel && NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible && owner != nil
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let rgb = Self.rgb(sender.color) else { return }
        receive(rgb)
    }

    /// A pick from the panel: held for the settle, then handed on. The
    /// tests call this in the panel's place.
    func receive(_ rgb: UInt32) {
        pending = .custom(rgb)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.settle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// The pending pick to the current owner, now.
    private func flush() {
        timer?.invalidate()
        timer = nil
        guard let pending else { return }
        self.pending = nil
        onPick?(pending)
    }

    /// The panel's colour as `0xRRGGBB` in sRGB.
    static func rgb(_ color: NSColor) -> UInt32? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return (byte(srgb.redComponent) << 16) | (byte(srgb.greenComponent) << 8) | byte(srgb.blueComponent)
    }
}

/// The point-size stepper, 10–24; a flat stand-in under `ImageRenderer`.
struct SizeStepper: View {
    let size: Int
    var readOnly = false
    var onSize: (Int) -> Void
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        if previewRendering {
            HStack(spacing: 6) {
                Text("\(size) pt").font(Brand.mono(12)).monospacedDigit().foregroundStyle(Brand.textPrimary)
                HStack(spacing: 0) {
                    Text("−").frame(width: 18, height: 18)
                    Divider().frame(height: 12)
                    Text("+").frame(width: 18, height: 18)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.textPrimary)
                .background(Brand.canvas, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Brand.borderSubtle, lineWidth: 1))
            }
        } else {
            Stepper(value: Binding(get: { size }, set: { onSize($0) }), in: NoteTypeface.sizeRange) {
                Text("\(size) pt").font(Brand.mono(12)).monospacedDigit()
            }
            .disabled(readOnly)
            .accessibilityLabel("Size")
        }
    }
}

/// A text field as `ImageRenderer` cannot draw one: the border and the
/// placeholder.
struct PreviewField: View {
    let placeholder: String

    var body: some View {
        Text(placeholder)
            .font(Brand.body(13))
            .foregroundStyle(Brand.textSecondary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(Brand.canvas, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Brand.borderSubtle, lineWidth: 1))
    }
}
