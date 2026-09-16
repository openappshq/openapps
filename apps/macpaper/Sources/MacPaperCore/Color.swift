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
}

/// The built-in palettes the random documents draw from. Every palette is
/// a set of colors that read as one wallpaper; the seed picks a palette and
/// the order it is used in.
public enum Palettes {
    public static let all: [[RGBAColor]] = [
        // Sunset
        [RGBAColor(hex: 0xFF7A2F), RGBAColor(hex: 0xFFB48A), RGBAColor(hex: 0xF3A0DC), RGBAColor(hex: 0x4A2114)],
        // Sea
        [RGBAColor(hex: 0x0B3D91), RGBAColor(hex: 0x1FA2FF), RGBAColor(hex: 0x12D8FA), RGBAColor(hex: 0xA6FFCB)],
        // Forest
        [RGBAColor(hex: 0x163A29), RGBAColor(hex: 0x236B48), RGBAColor(hex: 0x91DCB4), RGBAColor(hex: 0xEDF8F1)],
        // Dusk
        [RGBAColor(hex: 0x242B55), RGBAColor(hex: 0x304BFF), RGBAColor(hex: 0xA6B2FF), RGBAColor(hex: 0xEDF0FF)],
        // Charcoal
        [RGBAColor(hex: 0x141414), RGBAColor(hex: 0x2C2C2C), RGBAColor(hex: 0x484848), RGBAColor(hex: 0x858585)],
        // Peach
        [RGBAColor(hex: 0xFFF1EA), RGBAColor(hex: 0xFFCDB3), RGBAColor(hex: 0xFFD528), RGBAColor(hex: 0xFF7A2F)],
        // Berry
        [RGBAColor(hex: 0x4B2028), RGBAColor(hex: 0xAC243C), RGBAColor(hex: 0xFFACB8), RGBAColor(hex: 0xFFF0F2)],
        // Slate
        [RGBAColor(hex: 0x1F2933), RGBAColor(hex: 0x3E4C59), RGBAColor(hex: 0x9AA5B1), RGBAColor(hex: 0xE4E7EB)],
    ]
}
