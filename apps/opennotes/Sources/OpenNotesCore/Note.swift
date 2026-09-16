import Foundation

/// A note's identity: its file name without the `.md`, fixed on the first
/// save and never changed by the app (design/products/opennotes.md,
/// "Notes"), so iCloud Drive, Obsidian and git see one stable file.
nonisolated public struct NoteID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var fileName: String { rawValue + ".md" }
    public var description: String { rawValue }

    public static func < (lhs: NoteID, rhs: NoteID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The papers a note can be: a named preset (apps/opennotes/design/tokens.json,
/// `noteFaces`) or any colour the user picked. Stored in the front matter
/// as the preset's name or as `#RRGGBB`. Every 0.1.0 name is still here,
/// so old files render as they did.
nonisolated public enum NoteColor: Hashable, Sendable, Codable, RawRepresentable {
    case preset(NotePaper)
    /// A colour from the picker: the Light Mode paper as `0xRRGGBB`; the
    /// Dark Mode paper and the ink are derived (`NotePaper.derivedDark`,
    /// `NoteColor.ink(dark:)`).
    case custom(UInt32)

    public static let coral = NoteColor.preset(.coral)
    public static let yellow = NoteColor.preset(.yellow)
    public static let butter = NoteColor.preset(.butter)
    public static let mint = NoteColor.preset(.mint)
    public static let sage = NoteColor.preset(.sage)
    public static let sky = NoteColor.preset(.sky)
    public static let lagoon = NoteColor.preset(.lagoon)
    public static let lilac = NoteColor.preset(.lilac)
    public static let rose = NoteColor.preset(.rose)
    public static let sand = NoteColor.preset(.sand)
    public static let slate = NoteColor.preset(.slate)
    public static let graphite = NoteColor.preset(.graphite)
    public static let paper = NoteColor.preset(.paper)

    /// The presets, in the order the swatch grid shows them.
    public static let allCases: [NoteColor] = NotePaper.allCases.map(NoteColor.preset)

    /// A preset's name, or `#RRGGBB` (uppercase) for a custom colour.
    public var rawValue: String {
        switch self {
        case .preset(let paper): paper.rawValue
        case .custom(let rgb): NoteColor.hex(rgb)
        }
    }

    /// A preset's name in any case, or a `#RRGGBB` / `#RGB` colour; anything
    /// else is nil, so an unknown value falls back to the default paper.
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        if let paper = NotePaper(rawValue: trimmed.lowercased()) {
            self = .preset(paper)
        } else if let rgb = NoteColor.rgb(fromHex: trimmed) {
            self = .custom(rgb)
        } else {
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let color = NoteColor(rawValue: raw) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not a note colour: \(raw)"))
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var preset: NotePaper? {
        if case .preset(let paper) = self { return paper }
        return nil
    }

    public var isCustom: Bool { preset == nil }

    /// "Coral", "Butter", …; "Custom" for a picked colour.
    public var title: String {
        switch self {
        case .preset(let paper): paper.title
        case .custom: "Custom"
        }
    }

    /// The fill under the ink in Light Mode, also the pill's dash in both
    /// appearances (the swatches too).
    public var lightFace: UInt32 {
        switch self {
        case .preset(let paper): paper.lightFace
        case .custom(let rgb): rgb & 0xFFFFFF
        }
    }

    /// The bar along a tab's outer edge: the colour's own mid tone, so
    /// the papers tell apart at a glance in both appearances (tuned for
    /// a preset, derived for a custom colour).
    public var bar: UInt32 {
        switch self {
        case .preset(let paper): paper.bar
        case .custom(let rgb): NotePaper.derivedBar(from: rgb)
        }
    }

    /// The fill in Dark Mode: tuned by hand for a preset, derived from the
    /// light face for a custom colour.
    public var darkFace: UInt32 {
        switch self {
        case .preset(let paper): paper.darkFace
        case .custom(let rgb): NotePaper.derivedDark(from: rgb)
        }
    }

    public func face(dark: Bool) -> UInt32 { dark ? darkFace : lightFace }

    /// The text colour on the face: the appearance's ink (neutral/950 in
    /// Light Mode, neutral/0 in Dark Mode) when it reads at 4.5:1 or better,
    /// the other one when it does not — so a deep custom paper carries
    /// paper-coloured text in Light Mode, and Graphite does in both — and
    /// pure black or white for a midtone neither brand ink reaches.
    public func ink(dark: Bool) -> UInt32 {
        NotePaper.ink(on: face(dark: dark), preferDark: !dark)
    }

    /// Markers and metadata on the face: a softer ink of the body's
    /// polarity, at 3:1 or better.
    public func inkSecondary(dark: Bool) -> UInt32 {
        NotePaper.secondaryInk(on: face(dark: dark), body: ink(dark: dark))
    }

    /// URLs and ticked boxes: the coral accent of the body's polarity, the
    /// first shade that reads at 4.5:1, else at 3:1, else the body ink.
    public func link(dark: Bool) -> UInt32 {
        NotePaper.linkInk(on: face(dark: dark), body: ink(dark: dark))
    }

    /// The ink on a swatch of the light face (the colour menu's check).
    public var swatchInk: UInt32 { NotePaper.ink(on: lightFace, preferDark: true) }

    // MARK: Hex

    public static func hex(_ rgb: UInt32) -> String {
        String(format: "#%06X", rgb & 0xFFFFFF)
    }

    /// `#RRGGBB` or `#RGB`, either case; nil for anything else.
    public static func rgb(fromHex text: String) -> UInt32? {
        guard text.hasPrefix("#") else { return nil }
        let digits = text.dropFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        switch digits.count {
        case 6:
            return UInt32(digits, radix: 16)
        case 3:
            var rgb: UInt32 = 0
            for digit in digits {
                let value = UInt32(String(digit), radix: 16) ?? 0
                rgb = (rgb << 8) | (value << 4) | value
            }
            return rgb
        default:
            return nil
        }
    }
}

/// The named papers, tuned by eye for both appearances (the harness's
/// paper sheet shows them all with their ink). Every 0.1.0 name is here.
nonisolated public enum NotePaper: String, CaseIterable, Sendable, Codable {
    case coral, yellow, butter, mint, sage, sky, lagoon, lilac, rose, sand, slate, graphite, paper

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The fill under ink text in Light Mode, also the pill's dash in both
    /// appearances.
    public var lightFace: UInt32 {
        switch self {
        case .coral: 0xFFC0AB
        case .yellow: 0xFFE28A
        case .butter: 0xFFF3B0
        case .mint: 0xB1E7CA
        case .sage: 0xCFE0C3
        case .sky: 0xC1C9FF
        case .lagoon: 0xB9E6EF
        case .lilac: 0xF3C3E8
        case .rose: 0xFFC9D2
        case .sand: 0xEAD9C2
        case .slate: 0xCFD8E3
        case .graphite: 0x4A4A4A
        case .paper: 0xF3F3F3
        }
    }

    /// The fill under paper text in Dark Mode: the same hue as the light
    /// face, deep but still saturated, so the tab, the open note and the
    /// All Notes bar read as one colour in both appearances; every one
    /// carries the paper ink at 5.8:1 or better.
    public var darkFace: UInt32 {
        switch self {
        case .coral: 0x8F3A22
        case .yellow: 0x7A5A12
        case .butter: 0x6E6118
        case .mint: 0x1F6B45
        case .sage: 0x3F6630
        case .sky: 0x2E3D8F
        case .lagoon: 0x1C6A78
        case .lilac: 0x7B2A6A
        case .rose: 0x8A2438
        case .sand: 0x6E5230
        case .slate: 0x2F4A6B
        case .graphite: 0x262626
        case .paper: 0x3A3A3A
        }
    }

    /// The bar along a fanned tab's outer edge: the colour's mid tone, the
    /// same in both appearances (`noteBars` in tokens.json); fills only,
    /// never text. Coral is coral/500; the others sit at its lightness.
    public var bar: UInt32 {
        switch self {
        case .coral: 0xF0653F
        case .yellow: 0xE3B517
        case .butter: 0xE8C43A
        case .mint: 0x3FAE79
        case .sage: 0x7DA86A
        case .sky: 0x6F7FF2
        case .lagoon: 0x3FA6BC
        case .lilac: 0xD56DBC
        case .rose: 0xE8607C
        case .sand: 0xB9905C
        case .slate: 0x7089A6
        case .graphite: 0x8A8A8A
        case .paper: 0xA3A3A3
        }
    }

    /// The tab bar for a picked colour: the light face's hue, saturation
    /// held between 45% and 85% (a grey stays grey), at 55% lightness —
    /// the mid tone the tuned bars sit at. Pure arithmetic.
    public static func derivedBar(from rgb: UInt32) -> UInt32 {
        let (h, s, _) = hsl(rgb)
        if s < 0.12 { return fromHSL(h, s, 0.64) }
        return fromHSL(h, min(max(s, 0.45), 0.85), 0.55)
    }

    /// The paper for a new note when Settings → Notes says Random: a
    /// preset that differs from the last note created and from the notes
    /// the new one lands between in the deck (on top of the unpinned
    /// ones), where the presets allow; the seed (the app passes the
    /// number of notes) spreads the picks. Pure, so the same deck always
    /// gives the same paper.
    public static func randomForNewNote(active: [Note], lastCreated: Note?, seed: Int) -> NotePaper {
        let landing = active.firstIndex { !$0.pinned } ?? active.count
        var avoid: [NoteColor] = []
        if let lastCreated { avoid.append(lastCreated.color) }
        if landing > 0 { avoid.append(active[landing - 1].color) }
        if landing < active.count { avoid.append(active[landing].color) }
        return pick(avoiding: avoid, seed: seed)
    }

    /// A preset not in `avoiding` (every preset when nothing else is left),
    /// chosen by a hash of the seed.
    public static func pick(from presets: [NotePaper] = allCases, avoiding: [NoteColor], seed: Int) -> NotePaper {
        let candidates = presets.filter { !avoiding.contains(.preset($0)) }
        let pool = candidates.isEmpty ? presets : candidates
        guard !pool.isEmpty else { return .coral }
        let mixed = (UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15) &* 0xBF58_476D_1CE4_E5B9
        return pool[Int((mixed >> 33) % UInt64(pool.count))]
    }

    /// neutral/950 and neutral/0: the two inks a note is ever written in.
    public static let lightInk: UInt32 = 0x141414
    public static let darkInk: UInt32 = 0xF8F8F8
    /// neutral/700 and neutral/100: markers and metadata, at 4.5:1 or
    /// better on every preset in its appearance.
    public static let lightInkSecondary: UInt32 = 0x484848
    public static let darkInkSecondary: UInt32 = 0xEBEBEB
    /// WCAG AA for body text; below it the ink flips.
    public static let minimumContrast = 4.5
    /// The floor for markers, metadata and links (large-text / UI AA).
    public static let minimumSecondaryContrast = 3.0
    /// The coral shades a link can take, darkest first for ink-coloured
    /// text and lightest first for paper-coloured text (coral/700, 800,
    /// 950; coral/200, 100, 50).
    static let linkShadesOnLight: [UInt32] = [0xA53A20, 0x7D2C18, 0x4A1D12]
    static let linkShadesOnDark: [UInt32] = [0xFFC0AB, 0xFFDCCF, 0xFFF1EC]

    /// The ink for a face: the preferred brand ink when it reaches 4.5:1,
    /// else the other brand ink, else pure black or white — one of those
    /// always does (a paper no brand ink reaches is a midtone, and black
    /// or white reads on every midtone).
    public static func ink(on face: UInt32, preferDark: Bool) -> UInt32 {
        let preferred = preferDark ? lightInk : darkInk
        let other = preferDark ? darkInk : lightInk
        for candidate in [preferred, other] where contrast(candidate, face) >= minimumContrast { return candidate }
        let pureBlack: UInt32 = 0x000000, pureWhite: UInt32 = 0xFFFFFF
        return contrast(pureBlack, face) >= contrast(pureWhite, face) ? pureBlack : pureWhite
    }

    /// Whether an ink is on the dark side (ink-coloured text) or the
    /// light side (paper-coloured text).
    static func isDarkInk(_ ink: UInt32) -> Bool { luminance(ink) < 0.5 }

    /// Markers and metadata: the brand secondary of the body's polarity
    /// when it reads at 3:1, else the body ink faded towards the paper
    /// as far as 3.5:1 allows (a margin over the floor). Monotonic in the
    /// fade, so a bisection finds it; pure arithmetic.
    public static func secondaryInk(on face: UInt32, body: UInt32) -> UInt32 {
        let brand = isDarkInk(body) ? lightInkSecondary : darkInkSecondary
        if contrast(brand, face) >= minimumSecondaryContrast { return brand }
        return fade(body, towards: face, untilContrast: 3.5)
    }

    /// Links and ticked boxes: the first coral shade of the body's
    /// polarity at 4.5:1, else the first at 3:1, else the body ink.
    public static func linkInk(on face: UInt32, body: UInt32) -> UInt32 {
        let shades = isDarkInk(body) ? linkShadesOnLight : linkShadesOnDark
        for threshold in [minimumContrast, minimumSecondaryContrast] {
            if let shade = shades.first(where: { contrast($0, face) >= threshold }) { return shade }
        }
        return body
    }

    /// `ink` blended towards `face` by the largest amount that keeps the
    /// contrast at or above `target`; `ink` itself when it is below.
    static func fade(_ ink: UInt32, towards face: UInt32, untilContrast target: Double) -> UInt32 {
        guard contrast(ink, face) >= target else { return ink }
        var low = 0.0, high = 1.0
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if contrast(mix(ink, face, mid), face) >= target { low = mid } else { high = mid }
        }
        return mix(ink, face, low)
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) & 0xFF
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }

    /// The Dark Mode paper for a picked Light Mode colour: the same hue,
    /// the saturation held between 45% and 70% (a grey stays grey), the
    /// lightness starting where the tuned dark faces sit (32%) and stepped
    /// down until the paper ink reads at 5:1. Pure arithmetic, so the same
    /// colour derives the same paper on every Mac.
    public static func derivedDark(from rgb: UInt32) -> UInt32 {
        let (h, s, _) = hsl(rgb)
        let saturation = s < 0.12 ? s : min(max(s, 0.45), 0.7)
        var lightness = 0.32
        var paper = fromHSL(h, saturation, lightness)
        while contrast(darkInk, paper) < 5, lightness > 0.05 {
            lightness -= 0.01
            paper = fromHSL(h, saturation, lightness)
        }
        return paper
    }

    /// WCAG 2.x contrast ratio between two `0xRRGGBB` colours.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
    }

    static func hsl(_ rgb: UInt32) -> (Double, Double, Double) {
        let r = Double((rgb >> 16) & 0xFF) / 255, g = Double((rgb >> 8) & 0xFF) / 255, b = Double(rgb & 0xFF) / 255
        let high = max(r, g, b), low = min(r, g, b)
        let l = (high + low) / 2
        guard high != low else { return (0, 0, l) }
        let d = high - low
        let s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
        var h: Double
        if high == r { h = (g - b) / d + (g < b ? 6 : 0) } else if high == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    static func fromHSL(_ h: Double, _ s: Double, _ l: Double) -> UInt32 {
        func hue(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let r, g, b: Double
        if s == 0 {
            r = l; g = l; b = l
        } else {
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            r = hue(p, q, h + 1 / 3); g = hue(p, q, h); b = hue(p, q, h - 1 / 3)
        }
        func byte(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }
}

/// The three quick faces: the bundled sans and mono, the system serif.
/// Stored under `face:`, as 0.1.0 did.
nonisolated public enum NoteFace: String, CaseIterable, Sendable, Codable {
    case sans, serif, mono

    public var title: String {
        switch self {
        case .sans: "Sans"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }

    /// ⌘⇧M: Sans → Serif → Mono → Sans.
    public var toggled: NoteFace {
        switch self {
        case .sans: .serif
        case .serif: .mono
        case .mono: .sans
        }
    }
}

/// What a note is written in: one of the three faces, or any font family
/// installed on the Mac, by name. Stored as `face:` or `font:`; a note
/// with none takes Settings → Notes' default.
nonisolated public enum NoteTypeface: Hashable, Sendable, Codable {
    case face(NoteFace)
    case family(String)

    public var face: NoteFace? {
        if case .face(let face) = self { return face }
        return nil
    }

    public var family: String? {
        if case .family(let family) = self { return family }
        return nil
    }

    /// "Sans", or the family's name as written.
    public var title: String {
        switch self {
        case .face(let face): face.title
        case .family(let family): family
        }
    }

    /// ⌘⇧M on a note in a chosen family goes to the first face.
    public var toggled: NoteTypeface {
        switch self {
        case .face(let face): .face(face.toggled)
        case .family: .face(.sans)
        }
    }

    /// Point sizes a note can be set to.
    public static let sizeRange: ClosedRange<Int> = 10...24
    public static let defaultSize = 14

    public static func clampSize(_ size: Int) -> Int {
        min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
    }
}

/// One sticky: what the front matter keeps, and the text.
nonisolated public struct Note: Hashable, Sendable, Identifiable {
    public var id: NoteID
    public var text: String
    public var color: NoteColor
    /// The note's own font; nil takes the default in Settings → Notes.
    public var typeface: NoteTypeface?
    /// The note's own point size; nil takes the default.
    public var fontSize: Int?
    public var pinned: Bool
    public var archived: Bool
    /// Position in the deck, lower first. New notes take one below the
    /// lowest so they land on top; reordering rewrites the active notes'.
    public var order: Int
    public var created: Date
    /// The last edit made through the app or seen on disk.
    public var modified: Date
    /// The file is larger than the store reads: `text` is its beginning,
    /// and the note is shown but never edited or written. Not persisted.
    public var truncated = false
    /// `text` is the whole body (as far as the read cap goes). False once
    /// the store's body budget evicted it: `text` is then the first
    /// kilobyte, and `NoteStore.body(of:)` reads the rest back. Not persisted.
    public var bodyIsLoaded = true
    /// The note's file is an iCloud placeholder right now (`.<name>.md.icloud`):
    /// not downloaded yet, or evicted. With `bodyIsLoaded` false the note is
    /// only its file name, shown greyed as "Downloading…" once asked for;
    /// with it true the text in memory is the note (evicted while held) and
    /// its write waits for the file to come back. Never written over. Not
    /// persisted.
    public var isDownloading = false

    public init(id: NoteID, text: String = "", color: NoteColor = .coral, typeface: NoteTypeface? = nil, fontSize: Int? = nil, pinned: Bool = false, archived: Bool = false, order: Int = 0, created: Date, modified: Date? = nil) {
        self.id = id
        self.text = text
        self.color = color
        self.typeface = typeface
        self.fontSize = fontSize
        self.pinned = pinned
        self.archived = archived
        self.order = order
        self.created = created
        self.modified = modified ?? created
    }

    /// The first non-empty line, a leading heading marker dropped; "Untitled"
    /// when there is none. The deck's tab, the All Notes list and the file
    /// name (once) all read it.
    public var title: String {
        Note.title(of: text)
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The text after the title line as one line for the All Notes list:
    /// the lines joined with spaces, the markers gone (headings, emphasis,
    /// code, bullets and checkboxes), read line by line only until
    /// `previewLength` characters are in hand (the line that crosses it is
    /// kept whole), so a long note costs no more than a short one.
    public var preview: String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines.removeSubrange(...first)
        }
        var kept: [String] = []
        var length = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            kept.append(trimmed)
            length += trimmed.count + 1
            if length >= Note.previewLength { break }
        }
        guard !kept.isEmpty else { return "" }
        let plain = MarkdownLite.plainText(kept.joined(separator: "\n"))
        return plain.split(separator: "\n").map { Note.withoutListMarker(String($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// How much of the text the preview reads before it stops taking
    /// lines, in characters; far more than a row shows.
    public static let previewLength = 240

    /// The line without a leading bullet, number or checkbox.
    static func withoutListMarker(_ line: String) -> String {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
            rest = rest.dropFirst(2)
        } else if let dot = rest.firstIndex(of: "."), rest[..<dot].allSatisfy(\.isNumber), !rest[..<dot].isEmpty, rest[rest.index(after: dot)...].hasPrefix(" ") {
            rest = rest[rest.index(after: dot)...].dropFirst()
        }
        for box in ["[ ] ", "[x] ", "[X] "] where rest.hasPrefix(box) {
            rest = rest.dropFirst(box.count)
            break
        }
        if rest == "[ ]" || rest == "[x]" || rest == "[X]" { return "" }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    public static func title(of text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            while trimmed.hasPrefix("#") { trimmed.removeFirst() }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Untitled" : trimmed
        }
        return "Untitled"
    }

    /// Orders outside this range (a hand-written file, an overflow) are
    /// brought back to its edge on read, so "one below the lowest" is
    /// always a number.
    public static let orderRange: ClosedRange<Int> = -1_000_000_000...1_000_000_000

    public static func clampOrder(_ order: Int) -> Int {
        min(max(order, orderRange.lowerBound), orderRange.upperBound)
    }

    /// The deck's order: pinned first, then by `order`, then the newest first,
    /// then by id so equal notes still sort the same on every launch.
    public static func deckOrder(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned }
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        if lhs.created != rhs.created { return lhs.created > rhs.created }
        return lhs.id < rhs.id
    }
}

/// The front matter of a note file: a `---` block of `key: value` lines
/// before the text. Only keys OpenNotes writes are read; a block that is
/// not ours (no known key at all) is left as text, so an Obsidian file with
/// its own front matter loses nothing (design/products/opennotes.md,
/// "Defaults and recovery").
nonisolated public enum FrontMatter {
    public static let keys = ["color", "face", "font", "size", "pinned", "archived", "order", "created", "modified"]

    public struct Parsed: Hashable, Sendable {
        public var color: NoteColor?
        /// `face:` (0.1.0's three presets) or `font:` (a family by name);
        /// a file carrying both keeps the family.
        public var typeface: NoteTypeface?
        public var size: Int?
        public var pinned: Bool?
        public var archived: Bool?
        public var order: Int?
        public var created: Date?
        public var modified: Date?
        /// The text after the block (the whole file when there is none),
        /// the one blank line `serialize` puts after the block dropped, so
        /// `parse(serialize(note)).text == note.text`.
        public var text: String
        /// Whether a block OpenNotes recognises was found.
        public var hadFrontMatter: Bool

        public var isEmpty: Bool {
            color == nil && typeface == nil && size == nil && pinned == nil && archived == nil && order == nil && created == nil && modified == nil
        }

        public var face: NoteFace? { typeface?.face }
        public var font: String? { typeface?.family }
    }

    /// Parses a file's contents. The block must start on the first line and
    /// close with a `---` line; unknown keys are ignored, and a block with
    /// no known key is not consumed. The blank line `serialize` writes after
    /// the block is the file's, not the text's: one is dropped.
    public static func parse(_ contents: String) -> Parsed {
        var result = Parsed(text: contents, hadFrontMatter: false)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return result }
        guard let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return result }
        var known = false
        var face: NoteFace?
        var family: String?
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "color": if let color = NoteColor(rawValue: value) { result.color = color; known = true }
            case "face": if let parsed = NoteFace(rawValue: value.lowercased()) { face = parsed; known = true }
            case "font": if !value.isEmpty { family = value; known = true }
            case "size": if let size = Int(value) { result.size = size; known = true }
            case "pinned": if let flag = bool(value) { result.pinned = flag; known = true }
            case "archived": if let flag = bool(value) { result.archived = flag; known = true }
            case "order": if let order = Int(value) { result.order = order; known = true }
            case "created": if let date = date(value) { result.created = date; known = true }
            case "modified": if let date = date(value) { result.modified = date; known = true }
            default: break
            }
        }
        guard known else { return result }
        result.hadFrontMatter = true
        result.typeface = family.map(NoteTypeface.family) ?? face.map(NoteTypeface.face)
        var text = lines[(close + 1)...].joined(separator: "\n")
        if text.hasPrefix("\n") { text.removeFirst() }
        result.text = text
        return result
    }

    /// The file's contents for a note: the block, a blank line, the text.
    /// Dates are ISO 8601 in UTC, so a folder shared between Macs in
    /// different zones reads the same. A custom colour is `#RRGGBB`; a
    /// face is `face:`, a family `font: "Name"`, a size `size:`, each only
    /// when the note has its own (design/products/opennotes.md, "Notes").
    public static func serialize(_ note: Note) -> String {
        var lines = ["---", "color: \(note.color.isCustom ? quote(note.color.rawValue) : note.color.rawValue)"]
        switch note.typeface {
        case .face(let face): lines.append("face: \(face.rawValue)")
        case .family(let family): lines.append("font: \(quote(family))")
        case nil: break
        }
        if let size = note.fontSize { lines.append("size: \(size)") }
        lines += [
            "pinned: \(note.pinned)",
            "archived: \(note.archived)",
            "order: \(note.order)",
            "created: \(format(note.created))",
            "modified: \(format(note.modified))",
            "---",
        ]
        return lines.joined(separator: "\n") + "\n\n" + note.text
    }

    /// Double-quoted, so a family name with a colon or a `#` reads back as
    /// one value; quotes inside are dropped (no family is named with one).
    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "") + "\""
    }

    private static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on": true
        case "false", "no", "off": false
        default: nil
        }
    }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(_ value: String) -> Date? {
        formatter.date(from: value) ?? fractionalFormatter.date(from: value)
    }
}

/// File names from titles: lowercase ASCII letters, digits and hyphens,
/// 60 characters at most; a counter when the name is taken; a timestamp
/// when there is no title.
nonisolated public enum NoteFileName {
    public static let maximumLength = 60

    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        var result = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                if pendingHyphen, !result.isEmpty {
                    guard result.count + 1 < maximumLength else { break }
                    result.append("-")
                }
                pendingHyphen = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
            if result.count >= maximumLength { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    /// The id for a new note: the title's slug (or `note-<timestamp>`), with
    /// `-2`, `-3`, … while `taken` says the name is in use.
    public static func id(for title: String, created: Date, taken: (NoteID) -> Bool) -> NoteID {
        var base = slug(title == "Untitled" ? "" : title)
        if base.isEmpty {
            base = "note-" + timestampFormatter.string(from: created)
        }
        var candidate = NoteID(base)
        var counter = 2
        while taken(candidate) {
            candidate = NoteID("\(base)-\(counter)")
            counter += 1
        }
        return candidate
    }

    /// `<name> (conflict 2026-09-16 10-30-05.123)`, the stem of the note
    /// beside the original that holds the user's text; the store adds
    /// `-2`, `-3`… while the name is taken.
    public static func conflictStem(for id: NoteID, at date: Date) -> String {
        "\(id.rawValue) (conflict \(conflictFormatter.string(from: date)))"
    }

    public static func conflictName(for id: NoteID, at date: Date) -> String {
        conflictStem(for: id, at: date) + ".md"
    }

    /// `<name> (conflict from Kevin's MacBook 2026-09-16 10-30-05.123)`: a
    /// version iCloud could not merge, kept as a note beside the file.
    /// The device's name is slugged like a title, so the stem stays a
    /// plain file name; without one it is the plain conflict stem.
    public static func conflictStem(for id: NoteID, device: String?, at date: Date) -> String {
        let name = device.map(slug) ?? ""
        guard !name.isEmpty else { return conflictStem(for: id, at: date) }
        return "\(id.rawValue) (conflict from \(name) \(conflictFormatter.string(from: date)))"
    }

    /// `<name> (recovered 2026-09-16 10-30-05.123)`: a version found in a
    /// temporary file a cut-short write left behind.
    public static func recoveredStem(for stem: String, at date: Date) -> String {
        "\(stem) (recovered \(conflictFormatter.string(from: date)))"
    }

    nonisolated(unsafe) private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()

    nonisolated(unsafe) private static let conflictFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss.SSS"
        return formatter
    }()
}
