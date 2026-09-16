import Foundation

/// An sRGB color with straight alpha, the unit the documents store and the
/// generators blend. Encoded as `#RRGGBB` (or `#RRGGBBAA` when not opaque)
/// so a document reads like CSS.
public struct RGBAColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// `#RRGGBB`, `#RRGGBBAA`, `RRGGBB` or the three-digit short form.
    public init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 8 {
            self.init(hex: UInt32(value >> 8), alpha: Double(value & 0xFF) / 255)
        } else {
            self.init(hex: UInt32(value))
        }
    }

    public var hexString: String {
        let r = Self.byte(red), g = Self.byte(green), b = Self.byte(blue)
        if alpha >= 1 { return String(format: "#%02X%02X%02X", r, g, b) }
        return String(format: "#%02X%02X%02X%02X", r, g, b, Self.byte(alpha))
    }

    public static func byte(_ component: Double) -> UInt8 {
        UInt8((min(max(component, 0), 1) * 255).rounded())
    }

    /// The color as its `#RRGGBB` bytes: what a document stores, so a
    /// computed color (a mix, a fold) compares equal after a round trip.
    public var snapped: RGBAColor {
        RGBAColor(red: Double(Self.byte(red)) / 255, green: Double(Self.byte(green)) / 255, blue: Double(Self.byte(blue)) / 255, alpha: Double(Self.byte(alpha)) / 255)
    }

    /// Linear interpolation in sRGB, `t` clamped to 0…1.
    public func mixed(with other: RGBAColor, amount t: Double) -> RGBAColor {
        let t = min(max(t, 0), 1)
        return RGBAColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    /// Relative luminance (WCAG), for picking readable text over a preview.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    public static let black = RGBAColor(hex: 0x000000)
    public static let white = RGBAColor(hex: 0xFFFFFF)
}

extension RGBAColor: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = RGBAColor(hexString: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a color: \(text)")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

/// A color at a position along a gradient, 0…1.
public struct ColorStop: Codable, Hashable, Sendable {
    public var position: Double
    public var color: RGBAColor

    public init(position: Double, color: RGBAColor) {
        self.position = position
        self.color = color
    }

    private enum CodingKeys: String, CodingKey { case position, color }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decodeFinite(Double.self, forKey: .position, in: 0...1)
        color = try container.decode(RGBAColor.self, forKey: .color)
    }
}

/// Numbers from documents: finite, and inside the range the memberwise
/// initializer would clamp to. A document that carries NaN, infinity or a
/// value far outside its range is refused rather than clamped, so a
/// shared link can never make the renderer trap or spin.
extension KeyedDecodingContainer {
    func decodeFinite(_ type: Double.Type, forKey key: Key, in range: ClosedRange<Double>) throws -> Double {
        let value = try decode(Double.self, forKey: key)
        try check(value, key: key, in: range)
        return value
    }

    func decodeFiniteIfPresent(_ type: Double.Type, forKey key: Key, in range: ClosedRange<Double>, default fallback: Double) throws -> Double {
        guard let value = try decodeIfPresent(Double.self, forKey: key) else { return fallback }
        try check(value, key: key, in: range)
        return value
    }

    func decodeBounded(_ type: Int.Type, forKey key: Key, in range: ClosedRange<Int>) throws -> Int {
        let value = try decode(Int.self, forKey: key)
        guard range.contains(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "\(value) is outside \(range)")
        }
        return value
    }

    func decodeBoundedIfPresent(_ type: Int.Type, forKey key: Key, in range: ClosedRange<Int>, default fallback: Int) throws -> Int {
        guard let value = try decodeIfPresent(Int.self, forKey: key) else { return fallback }
        guard range.contains(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "\(value) is outside \(range)")
        }
        return value
    }

    private func check(_ value: Double, key: Key, in range: ClosedRange<Double>) throws {
        guard value.isFinite, range.contains(value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "\(value) is not a finite number in \(range)")
        }
    }
}

// MARK: - OKLCH

/// A color in OKLCH (Björn Ottosson's OKLab in polar form): perceptual
/// lightness 0…1, chroma (0 grey, ~0.37 the most saturated sRGB can hold),
/// hue in degrees. Mixing here turns hue the short way and never dips into
/// grey between two saturated colors; `color` clips chroma back into the
/// sRGB gamut, lightness and hue kept.
public struct OKLCH: Hashable, Sendable {
    public var l: Double
    public var c: Double
    public var h: Double

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    public init(_ color: RGBAColor) {
        let (L, a, b) = Self.oklab(fromLinear: Self.linear(color.red), Self.linear(color.green), Self.linear(color.blue))
        l = L
        c = (a * a + b * b).squareRoot()
        var hue = atan2(b, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        h = c < 1e-6 ? 0 : hue
    }

    /// Back to sRGB; a chroma outside the gamut is reduced (binary search)
    /// until every channel fits, so the hue and lightness survive.
    public var color: RGBAColor {
        var chroma = max(0, c)
        if let rgb = Self.srgb(l: l, c: chroma, h: h) { return rgb }
        var low = 0.0, high = chroma
        for _ in 0..<20 {
            chroma = (low + high) / 2
            if Self.srgb(l: l, c: chroma, h: h) != nil { low = chroma } else { high = chroma }
        }
        return Self.srgb(l: l, c: low, h: h) ?? RGBAColor(red: min(max(l, 0), 1), green: min(max(l, 0), 1), blue: min(max(l, 0), 1))
    }

    /// The mix at `t` between two colors: lightness and chroma linear, hue
    /// the short way round.
    public static func mix(_ a: RGBAColor, _ b: RGBAColor, amount t: Double) -> RGBAColor {
        let t = min(max(t, 0), 1)
        let x = OKLCH(a), y = OKLCH(b)
        // A grey has no hue: take the other's.
        let hx = x.c < 1e-4 ? y.h : x.h
        let hy = y.c < 1e-4 ? x.h : y.h
        let h = hx + hueDelta(from: hx, to: hy) * t
        return OKLCH(l: x.l + (y.l - x.l) * t, c: x.c + (y.c - x.c) * t, h: h).color
    }

    /// The signed shortest turn from one hue to another, −180…180.
    public static func hueDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    // MARK: Math

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private static func oklab(fromLinear r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// sRGB for the LCH, nil when a channel leaves 0…1 (with a hair of tolerance).
    private static func srgb(l: Double, c: Double, h: Double) -> RGBAColor? {
        let radians = h * .pi / 180
        let a = c * cos(radians), b = c * sin(radians)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        let tolerance = 0.0005
        for channel in [r, g, bl] where channel < -tolerance || channel > 1 + tolerance { return nil }
        return RGBAColor(red: encode(min(max(r, 0), 1)), green: encode(min(max(g, 0), 1)), blue: encode(min(max(bl, 0), 1)))
    }
}

// MARK: - Palettes from images and the accent color

/// The dominant colors of an image: median cut over a sample of its
/// pixels, ordered dark to light.
public enum PaletteExtractor {
    public static func dominantColors(of raster: Raster, count: Int, samples: Int = 4096) -> [RGBAColor] {
        let count = min(max(count, 1), 16)
        let total = raster.width * raster.height
        guard total > 0 else { return [] }
        let step = max(1, total / max(1, samples))
        var colors: [RGBAColor] = []
        colors.reserveCapacity(total / step + 1)
        var index = 0
        while index < total {
            let i = index * 4
            colors.append(RGBAColor(red: Double(raster.pixels[i]) / 255, green: Double(raster.pixels[i + 1]) / 255, blue: Double(raster.pixels[i + 2]) / 255))
            index += step
        }
        return MedianCut.palette(of: colors, count: count).sorted { $0.luminance < $1.luminance }
    }
}

/// The Mac's accent color expanded into a wallpaper palette in OKLCH: the
/// accent, a lighter and a darker step, its complement, a near-black and
/// a near-white that keep its hue.
public enum AccentPalette {
    public static func make(from accent: RGBAColor) -> [RGBAColor] {
        var base = OKLCH(accent)
        if base.c < 0.02 { base.c = 0.06 }
        func at(l: Double, c: Double? = nil, hueShift: Double = 0) -> RGBAColor {
            OKLCH(l: l, c: c ?? base.c, h: base.h + hueShift).color.snapped
        }
        return [
            at(l: 0.16, c: base.c * 0.5),           // near-black
            at(l: max(0.3, base.l - 0.22)),         // darker
            base.color.snapped,                     // the accent
            at(l: min(0.88, base.l + 0.2)),         // lighter
            at(l: base.l, hueShift: 180),           // the complement
            at(l: 0.96, c: base.c * 0.25),          // near-white
        ]
    }
}

// MARK: - Menu-bar readability

/// Whether the menu bar's text reads over a render's top strip: the mean
/// luminance of that strip against the text macOS draws there (dark text
/// in the light appearance, light text in the dark one — the light side of
/// a document shows under the first, the dark side under the second), and
/// how uneven the strip is (busy strips read badly whatever their mean).
public struct MenuBarReadability: Hashable, Sendable {
    public let side: Side
    public let meanLuminance: Double
    public let luminanceSpread: Double
    public let contrastWithWhite: Double
    public let contrastWithBlack: Double

    /// The contrast with the side's text: black on the light side, white
    /// on the dark side.
    public var contrast: Double { side == .light ? contrastWithBlack : contrastWithWhite }

    /// Normal-text contrast (4.5:1) and an even strip.
    public var reads: Bool {
        contrast >= 4.5 && luminanceSpread < 0.2
    }

    public var verdict: String {
        reads ? "Menu bar: reads" : "Menu bar: low contrast"
    }

    /// Reads the top `stripHeight` pixel rows (the menu bar's height at the
    /// display's scale), sampling every few pixels.
    public static func assess(_ raster: Raster, stripHeight: Int, side: Side = .light) -> MenuBarReadability {
        let rows = min(max(1, stripHeight), raster.height)
        let step = max(1, raster.width / 512)
        var sum = 0.0, sumSquares = 0.0, n = 0.0
        for y in stride(from: 0, to: rows, by: max(1, rows / 8)) {
            var x = 0
            while x < raster.width {
                let i = (y * raster.width + x) * 4
                let lum = 0.2126 * linear(raster.pixels[i]) + 0.7152 * linear(raster.pixels[i + 1]) + 0.0722 * linear(raster.pixels[i + 2])
                sum += lum
                sumSquares += lum * lum
                n += 1
                x += step
            }
        }
        let mean = n > 0 ? sum / n : 0
        let variance = n > 0 ? max(0, sumSquares / n - mean * mean) : 0
        return MenuBarReadability(
            side: side, meanLuminance: mean, luminanceSpread: variance.squareRoot(),
            contrastWithWhite: (1 + 0.05) / (mean + 0.05), contrastWithBlack: (mean + 0.05) / 0.05
        )
    }

    private static func linear(_ byte: UInt8) -> Double {
        let c = Double(byte) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
