import AppKit
import CoreText
import OpenNotesCore
import SwiftUI

/// Bundled resources. A packaged app reads `Contents/Resources`; `swift run`
/// falls back to the SwiftPM resource bundle next to the build products.
enum AppResources {
    static func url(_ name: String, _ ext: String, subdirectory: String? = nil) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return url
        }
        let moduleSubdirectory = ["Resources", subdirectory].compactMap { $0 }.joined(separator: "/")
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: moduleSubdirectory)
    }

    static func registerFonts() {
        let files = [
            ("BricolageGrotesque[opsz,wdth,wght]", "ttf"),
            ("InstrumentSans[wdth,wght]", "ttf"),
            ("IBMPlexMono-Regular", "ttf"),
            ("IBMPlexMono-Medium", "ttf"),
        ]
        for (name, ext) in files {
            guard let url = url(name, ext, subdirectory: "Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// 18 pt monochrome template built from the @1x and @2x renders.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for name in ["MenuBarIcon", "MenuBarIcon@2x"] {
            guard let url = url(name, "png"), let rep = NSImageRep(contentsOf: url) else { continue }
            rep.size = image.size
            image.addRepresentation(rep)
        }
        if image.representations.isEmpty {
            return NSImage(systemSymbolName: "note.text", accessibilityDescription: "OpenNotes") ?? image
        }
        image.isTemplate = true
        image.accessibilityDescription = "OpenNotes"
        return image
    }

    static func appIcon() -> NSImage? {
        url("AppIcon", "icns").flatMap(NSImage.init(contentsOf:))
    }
}

/// OpenApps HQ Tactile Studio tokens as used by OpenNotes (see design/tokens.json).
enum Brand {
    // MARK: Color

    static let accentSolid = dynamic(light: 0xA53A20, dark: 0xFFA48A)
    static let accentOn = dynamic(light: 0xFFFFFF, dark: 0x141414)
    static let accentSubtle = dynamic(light: 0xFFF1EC, dark: 0x4A1D12)
    static let accentText = dynamic(light: 0xA53A20, dark: 0xFFC0AB)
    static let canvas = dynamic(light: 0xFFFFFF, dark: 0x141414)
    static let surface = dynamic(light: 0xF3F3F3, dark: 0x202020)
    static let hover = dynamic(light: 0xEBEBEB, dark: 0x2C2C2C)
    static let textPrimary = dynamic(light: 0x141414, dark: 0xF8F8F8)
    static let textSecondary = dynamic(light: 0x626262, dark: 0xBABABA)
    static let borderSubtle = dynamic(light: 0xD9D9D9, dark: 0x484848)
    static let borderControl = dynamic(light: 0x858585, dark: 0x858585)
    /// The coral tile face: the brand mark, never text on a light ground.
    static let coral = Color(nsColor: NSColor(hex: 0xFFA48A))
    static let successSolid = dynamic(light: 0x236B48, dark: 0x91DCB4)
    static let successSubtle = dynamic(light: 0xEDF8F1, dark: 0x163A29)
    /// HQ yellow. Fills and shapes only; never text on a light ground.
    static let warningSolid = Color(nsColor: NSColor(hex: 0xFFD528))
    static let dangerSolid = dynamic(light: 0xAC243C, dark: 0xFFACB8)
    static let dangerSubtle = dynamic(light: 0xFFF0F2, dark: 0x4B2028)

    /// A note's paper for the appearance (apps/opennotes/design/tokens.json,
    /// `noteFaces`): the open note, its tab and All Notes' colour bar.
    static func face(_ color: NoteColor) -> Color {
        dynamic(light: color.lightFace, dark: color.darkFace)
    }

    /// The pill's dash and the colour swatches: the light face in both
    /// appearances (`NoteAppearance.swatch`).
    static func tab(_ color: NoteColor) -> Color {
        Color(nsColor: NSColor(hex: color.lightFace))
    }

    /// The bar along a tab's outer edge: the colour's mid tone, the same
    /// in both appearances.
    static func bar(_ color: NoteColor) -> Color {
        Color(nsColor: NSColor(hex: color.bar))
    }

    /// The text color on a note's face, per appearance.
    static let noteInk = dynamic(light: 0x141414, dark: 0xF8F8F8)
    /// Markers and metadata on a note's face: neutral/700 on the light
    /// faces (at least 4.4:1 on every face), neutral/400 on the dark ones.
    static let noteInkSecondary = dynamic(light: 0x484848, dark: 0xBABABA)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // MARK: Metrics

    enum Space {
        static let s4: CGFloat = 4, s8: CGFloat = 8, s12: CGFloat = 12, s16: CGFloat = 16
        static let s24: CGFloat = 24, s32: CGFloat = 32, s48: CGFloat = 48
    }

    enum Radius {
        static let small: CGFloat = 4, control: CGFloat = 8, panel: CGFloat = 16
    }

    enum Motion {
        static let fast = 0.1, standard = 0.18, expressive = 0.26
    }

    // MARK: Type

    /// Bricolage Grotesque ExtraBold, for window headings.
    static func display(_ size: CGFloat) -> Font {
        Font(variableFont(family: "Bricolage Grotesque", size: size, weight: 800, opticalSize: size)
            ?? .systemFont(ofSize: size, weight: .heavy))
    }

    /// Instrument Sans, for UI text.
    static func body(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        let fallbackWeight: NSFont.Weight = weight >= 600 ? .semibold : .regular
        return Font(variableFont(family: "Instrument Sans", size: size, weight: weight)
            ?? .systemFont(ofSize: size, weight: fallbackWeight))
    }

    /// IBM Plex Mono, for labels, the "Saved" line and the mono face.
    static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
        let name = medium ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular"
        return Font(NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: medium ? .medium : .regular))
            .monospacedDigit()
    }

    static func variableFont(family: String, size: CGFloat, weight: CGFloat, opticalSize: CGFloat? = nil) -> NSFont? {
        var variations: [NSNumber: NSNumber] = [NSNumber(value: fourCharCode("wght")): NSNumber(value: Double(weight))]
        if let opticalSize {
            variations[NSNumber(value: fourCharCode("opsz"))] = NSNumber(value: Double(min(max(opticalSize, 12), 96)))
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variations,
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == family else { return nil }
        return font
    }

    private static func fourCharCode(_ tag: String) -> UInt32 {
        tag.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

extension Brand {
    /// A note's font for the editor: Instrument Sans and IBM Plex Mono for
    /// the bundled faces (the system fonts when they are missing), the
    /// system serif for Serif, and any installed family by name through
    /// the font manager, which picks the member for the weight. Italic is
    /// the family's own italic member; a face without one is left upright
    /// here and slanted by the styler.
    static func noteFont(_ font: NoteAppearance.Font, size: CGFloat, weight: CGFloat = 400, italic: Bool = false) -> NSFont {
        let base: NSFont
        switch font {
        case .sans:
            let fallbackWeight: NSFont.Weight = weight >= 700 ? .bold : weight >= 600 ? .semibold : .regular
            base = variableFont(family: "Instrument Sans", size: size, weight: weight) ?? .systemFont(ofSize: size, weight: fallbackWeight)
        case .serif:
            let systemWeight: NSFont.Weight = weight >= 700 ? .bold : weight >= 600 ? .semibold : .regular
            let system = NSFont.systemFont(ofSize: size, weight: systemWeight)
            base = system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
                ?? NSFont(name: "Georgia", size: size) ?? system
        case .mono:
            let name = weight >= 500 ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular"
            base = NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight >= 500 ? .medium : .regular)
        case .family(let family):
            base = familyFont(family, size: size, weight: weight) ?? noteFont(.sans, size: size, weight: weight)
        }
        guard italic else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    /// The member of an installed family nearest the weight (the font
    /// manager's 0–15 scale: 5 regular, 9 bold); nil when the family is
    /// not installed.
    static func familyFont(_ family: String, size: CGFloat, weight: CGFloat) -> NSFont? {
        let managerWeight = weight >= 700 ? 9 : weight >= 600 ? 8 : weight >= 500 ? 6 : 5
        let traits: NSFontTraitMask = weight >= 600 ? .boldFontMask : []
        if let font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: managerWeight, size: size), font.familyName == family {
            return font
        }
        guard let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: size), font.familyName == family else { return nil }
        return weight >= 600 ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    /// A family at a size for lists and buttons: the family's regular
    /// member, or nil when it is not installed.
    static func familyFont(_ family: String, size: CGFloat) -> Font? {
        familyFont(family, size: size, weight: 400).map { Font($0) }
    }

    static func monoFont(size: CGFloat, medium: Bool = false) -> NSFont {
        let name = medium ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular"
        return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: medium ? .medium : .regular)
    }
}

extension NSColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Filled accent button for the single primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.body(14, weight: 600))
            .foregroundStyle(Brand.accentOn)
            .padding(.horizontal, Brand.Space.s16)
            .frame(minHeight: 32)
            .background(Brand.accentSolid, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4)
            .animation(.easeOut(duration: Brand.Motion.fast), value: configuration.isPressed)
    }
}

/// Quiet outlined button for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.body(14, weight: 600))
            .foregroundStyle(Brand.textPrimary)
            .padding(.horizontal, Brand.Space.s12)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                    .fill(configuration.isPressed ? Brand.borderSubtle.opacity(0.6) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                    .strokeBorder(Brand.borderControl, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .animation(.easeOut(duration: Brand.Motion.fast), value: configuration.isPressed)
    }
}

