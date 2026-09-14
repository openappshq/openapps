// Renders the committed SVG masters in design/assets into the macOS app icon
// (.icns via iconutil) and the 18 pt menu-bar template image.
// Run through scripts/make-icons.sh from the repository root.
import AppKit

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let assets = root.appendingPathComponent("design/assets")
let resources = root.appendingPathComponent("Sources/OpenReaction/Resources")

func loadSVG(_ name: String) -> NSImage {
    let url = assets.appendingPathComponent(name)
    guard let image = NSImage(contentsOf: url) else {
        fatalError("Could not load \(url.path). NSImage SVG support requires macOS 14 or later.")
    }
    return image
}

/// Draws `image` into a square bitmap. The SVG's own drop-shadow filter is not
/// rendered by NSImage, so the app tile gets an equivalent NSShadow instead.
func render(_ image: NSImage, pixels: Int, shadow: Bool) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Could not allocate bitmap") }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / image.size.width
    if shadow && pixels >= 64 {
        let dropShadow = NSShadow()
        dropShadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
        dropShadow.shadowBlurRadius = 24 * scale
        dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        dropShadow.set()
    }
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    return png
}

func write(_ data: Data, to url: URL) {
    do { try data.write(to: url) } catch { fatalError("Could not write \(url.path): \(error)") }
}

// App icon.
let appIcon = loadSVG("app-icon.svg")
let iconset = fileManager.temporaryDirectory.appendingPathComponent("OpenReaction-\(UUID().uuidString).iconset")
try! fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    write(render(appIcon, pixels: points, shadow: true), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    write(render(appIcon, pixels: points * 2, shadow: true), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? fileManager.removeItem(at: iconset)

// Menu-bar template image: the flat ink symbol, alpha only matters.
let symbol = loadSVG("symbol-ink.svg")
write(render(symbol, pixels: 18, shadow: false), to: resources.appendingPathComponent("MenuBarIcon.png"))
write(render(symbol, pixels: 36, shadow: false), to: resources.appendingPathComponent("MenuBarIcon@2x.png"))

print("Wrote AppIcon.icns and MenuBarIcon PNGs to \(resources.path)")
