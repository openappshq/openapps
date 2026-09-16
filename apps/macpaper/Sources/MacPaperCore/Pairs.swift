import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Dynamic-desktop HEIC files, the format macOS's own wallpapers use:
/// several images in one HEIC plus an XMP record in Apple's
/// `apple_desktop` namespace saying which image is for which appearance
/// (`apr`) or which moment of the day (`h24`). Written with ImageIO; macOS
/// keeps switching after the app that wrote the file has quit.
///
/// The records are base64 binary property lists:
/// - `apr`: `{"l": <index>, "d": <index>}`
/// - `h24`: `{"ap": {"l": <index>, "d": <index>}, "ti": [{"t": <fraction of day>, "i": <index>}, …]}`
public enum DynamicDesktop {
    public static let namespace = "http://ns.apple.com/namespace/1.0/"
    public static let prefix = "apple_desktop"

    public enum WriteError: Error, LocalizedError {
        case noFrames
        case encoder
        case metadata

        public var errorDescription: String? {
            switch self {
            case .noFrames: "Nothing to write."
            case .encoder: "This Mac could not encode a HEIC file."
            case .metadata: "The dynamic-desktop record could not be written."
            }
        }
    }

    /// A light/dark pair.
    public static func appearancePair(light: Raster, dark: Raster) throws -> Data {
        try write(frames: [light, dark], record: (name: "apr", plist: ["l": 0, "d": 1]))
    }

    /// A time-of-day set: frame `i` shows from `i / n` of the day. The
    /// brightest frame (noon, `n / 2`) is the light appearance, the first
    /// (midnight) the dark one.
    public static func timeOfDay(frames: [Raster]) throws -> Data {
        guard frames.count >= 2 else { throw WriteError.noFrames }
        let n = frames.count
        let times = (0..<n).map { ["t": Double($0) / Double(n), "i": $0] as [String: Any] }
        let plist: [String: Any] = ["ap": ["l": n / 2, "d": 0], "ti": times]
        return try write(frames: frames, record: (name: "h24", plist: plist))
    }

    /// The record's plist (decoded) from a HEIC's first image, for tests
    /// and diagnostics: `("apr", {...})` or `("h24", {...})`, nil without one.
    public static func record(in data: Data) -> (name: String, plist: [String: Any])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return nil }
        for tag in tags {
            guard let name = CGImageMetadataTagCopyName(tag) as String?, name == "apr" || name == "h24",
                  let value = CGImageMetadataTagCopyValue(tag) as? String,
                  let bytes = Data(base64Encoded: value),
                  let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { continue }
            return (name, plist)
        }
        return nil
    }

    /// How many images a HEIC holds.
    public static func frameCount(in data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    private static func write(frames: [Raster], record: (name: String, plist: [String: Any])) throws -> Data {
        guard !frames.isEmpty else { throw WriteError.noFrames }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, frames.count, nil) else {
            throw WriteError.encoder
        }
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace as CFString, prefix as CFString, nil),
              let plistData = try? PropertyListSerialization.data(fromPropertyList: record.plist, format: .binary, options: 0),
              let tag = CGImageMetadataTagCreate(namespace as CFString, prefix as CFString, record.name as CFString, .string, plistData.base64EncodedString() as CFString),
              CGImageMetadataSetTagWithPath(metadata, nil, "\(prefix):\(record.name)" as CFString, tag) else {
            throw WriteError.metadata
        }
        // Lossless as HEIC allows: the highest quality the encoder takes.
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        for (index, frame) in frames.enumerated() {
            guard let image = frame.cgImage else { throw WriteError.encoder }
            if index == 0 {
                CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, image, options as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw WriteError.encoder }
        return data as Data
    }
}

/// Phone sizes for the pair export: the current large iPhone in portrait.
public enum PhoneCanvas {
    public static let size = PixelSize(width: 1290, height: 2796)
    public static let name = "phone"
}

/// The fraction of the day now, 0 at midnight local time.
public enum DayClock {
    public static func fraction(of date: Date = Date(), calendar: Calendar = .current) -> Double {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = Double(components.hour ?? 0) * 3600 + Double(components.minute ?? 0) * 60 + Double(components.second ?? 0)
        return seconds / 86_400
    }
}
