import Foundation

/// PNG and SVG files of a document. PNG is the render itself; SVG is the
/// document redrawn as vector where the generator is one (gradients as
/// gradients, dots, lines and checks as patterns, grain as a turbulence
/// filter) and an embedded PNG where it is not (noise, pixelize, dither,
/// every pixel field, anything over a base or with a color finish).
public enum WallpaperExport {
    public enum Format: String, CaseIterable, Sendable {
        case png, svg

        public var title: String { rawValue.uppercased() }
        public var fileExtension: String { rawValue }
    }

    /// `macPaper-<generator>-<seed>.<ext>`.
    public static func fileName(for wallpaper: Wallpaper, format: Format) -> String {
        "macPaper-\(wallpaper.generator.kind.rawValue)-\(wallpaper.seed).\(format.fileExtension)"
    }

    public static func png(_ wallpaper: Wallpaper, size: PixelSize, renderer: WallpaperRenderer) -> Data? {
        renderer.render(wallpaper, size: size).pngData()
    }

    public static func svg(_ wallpaper: Wallpaper, size: PixelSize, renderer: WallpaperRenderer) -> String {
        SVGWriter(wallpaper: wallpaper, size: size, renderer: renderer).document()
    }
}

/// One SVG document. Coordinates are the display's pixels; every color is
/// written as the document stores it.
struct SVGWriter {
    let wallpaper: Wallpaper
    let size: PixelSize
    let renderer: WallpaperRenderer
    var side: Side = .light
    var context: RenderContext { RenderContext(size: size) }

    func document() -> String {
        var defs: [String] = []
        var body: [String] = []
        let w = size.width, h = size.height
        switch wallpaper.generator(for: side) {
        case .gradient(let p):
            gradient(p, defs: &defs, body: &body)
        case .mesh(let p):
            mesh(p, defs: &defs, body: &body)
        case .pattern(let p):
            pattern(p, defs: &defs, body: &body)
        case .solid(let p):
            body.append("<rect width=\"\(w)\" height=\"\(h)\" fill=\"\(p.color.hexString)\"/>")
        case .pixelize, .dither, .field:
            embedRender(body: &body)
        }
        if wallpaper.composition != .none || !wallpaper.finish.isEmpty || (wallpaper.base != .none && wallpaper.generator.kind.takesBase) {
            // Compositions and the color finishes are raster work: the
            // whole render goes in as an image instead.
            defs.removeAll()
            body.removeAll()
            embedRender(body: &body)
        }
        if wallpaper.grain > 0 {
            // feTurbulence on the position, seeded: the same idea as the
            // raster grain, not the same pixels.
            let opacity = format(wallpaper.grain * 0.25)
            defs.append("""
            <filter id="grain" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="1" seed="\(wallpaper.seed % 1_000_000)" stitchTiles="stitch" result="n"/><feColorMatrix in="n" type="saturate" values="0"/><feComponentTransfer><feFuncA type="linear" slope="\(opacity)"/></feComponentTransfer></filter>
            """.trimmingCharacters(in: .whitespacesAndNewlines))
            // No fill: a renderer without filter support draws nothing here
            // instead of a grey slab.
            body.append("<rect width=\"\(w)\" height=\"\(h)\" fill=\"none\" filter=\"url(#grain)\" style=\"mix-blend-mode:overlay\"/>")
        }
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\">",
            "<title>macPaper \(wallpaper.generator.kind.title) \(wallpaper.seed)</title>",
        ]
        if !defs.isEmpty { lines.append("<defs>" + defs.joined() + "</defs>") }
        lines.append(contentsOf: body)
        lines.append("</svg>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Generators

    private func gradient(_ p: GradientParameters, defs: inout [String], body: inout [String]) {
        let w = Double(size.width), h = Double(size.height)
        // OKLCH interpolation has no SVG form: the stops are subdivided so
        // the browser's sRGB blend follows the same curve closely.
        let stops = svgStops(p).map { "<stop offset=\"\(format($0.position * 100))%\" stop-color=\"\($0.color.hexString)\"/>" }.joined()
        switch p.kind {
        case .linear:
            // The same line the raster uses: through the center along the
            // angle, long enough for the first and last stop to touch the
            // rect's corners.
            let radians = p.angle * .pi / 180
            let dx = cos(radians), dy = sin(radians)
            let extent = abs(w * dx) + abs(h * dy)
            let x1 = w / 2 - dx * extent / 2, y1 = h / 2 - dy * extent / 2
            let x2 = w / 2 + dx * extent / 2, y2 = h / 2 + dy * extent / 2
            defs.append("<linearGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" x1=\"\(format(x1))\" y1=\"\(format(y1))\" x2=\"\(format(x2))\" y2=\"\(format(y2))\">\(stops)</linearGradient>")
            body.append("<rect width=\"\(size.width)\" height=\"\(size.height)\" fill=\"url(#g)\"/>")
        case .radial:
            let cx = p.center.x * w, cy = p.center.y * h
            let radius = (max(cx, w - cx) * max(cx, w - cx) + max(cy, h - cy) * max(cy, h - cy)).squareRoot()
            defs.append("<radialGradient id=\"g\" gradientUnits=\"userSpaceOnUse\" cx=\"\(format(cx))\" cy=\"\(format(cy))\" r=\"\(format(radius))\">\(stops)</radialGradient>")
            body.append("<rect width=\"\(size.width)\" height=\"\(size.height)\" fill=\"url(#g)\"/>")
        case .conic:
            // SVG has no conic gradient: 90 wedges around the center, each
            // filled with the color at its middle angle.
            let cx = p.center.x * w, cy = p.center.y * h
            let table = ColorTable(stops: p.normalizedStops, interpolation: p.interpolation)
            let radius = (w * w + h * h).squareRoot()
            let wedges = 90
            var paths: [String] = []
            for i in 0..<wedges {
                let a0 = (Double(i) / Double(wedges)) * 2 * .pi + p.angle * .pi / 180
                // Each wedge overlaps the next by a degree so no seam shows.
                let a1 = (Double(i + 1) / Double(wedges)) * 2 * .pi + p.angle * .pi / 180 + 0.02
                let t = (Double(i) + 0.5) / Double(wedges)
                let index = table.index(t)
                let color = RGBAColor(red: table.r[index], green: table.g[index], blue: table.b[index]).hexString
                let x0 = cx + cos(a0) * radius, y0 = cy + sin(a0) * radius
                let x1 = cx + cos(a1) * radius, y1 = cy + sin(a1) * radius
                paths.append("<path d=\"M\(format(cx)) \(format(cy))L\(format(x0)) \(format(y0))L\(format(x1)) \(format(y1))Z\" fill=\"\(color)\"/>")
            }
            defs.append("<clipPath id=\"c\"><rect width=\"\(size.width)\" height=\"\(size.height)\"/></clipPath>")
            body.append("<g clip-path=\"url(#c)\">" + paths.joined() + "</g>")
        }
    }

    /// The stops as written: as they are in sRGB, or with seven intermediate
    /// OKLCH-mixed stops per segment when the document interpolates in OKLCH.
    private func svgStops(_ p: GradientParameters) -> [ColorStop] {
        let stops = p.normalizedStops
        guard p.interpolation == .oklch else { return stops }
        var out: [ColorStop] = []
        for i in 0..<(stops.count - 1) {
            let a = stops[i], z = stops[i + 1]
            for step in 0..<8 {
                let f = Double(step) / 8
                out.append(ColorStop(position: a.position + (z.position - a.position) * f, color: OKLCH.mix(a.color, z.color, amount: f)))
            }
        }
        out.append(stops[stops.count - 1])
        return out
    }

    private func mesh(_ p: MeshParameters, defs: inout [String], body: inout [String]) {
        // One blurred radial gradient per control point over the mean color,
        // the same points the raster blends.
        let w = Double(size.width), h = Double(size.height)
        let points = Generators.meshPoints(p, seed: wallpaper.seed)
        let n = Double(points.count)
        let mean = RGBAColor(red: points.reduce(0) { $0 + $1.r } / n, green: points.reduce(0) { $0 + $1.g } / n, blue: points.reduce(0) { $0 + $1.b } / n)
        let reach = (0.35 + p.softness * 0.5) * max(w / Double(p.columns), h / Double(p.rows))
        defs.append("<filter id=\"soft\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\"><feGaussianBlur stdDeviation=\"\(format(reach * 0.35))\"/></filter>")
        for (i, point) in points.enumerated() {
            let color = RGBAColor(red: point.r, green: point.g, blue: point.b).hexString
            defs.append("<radialGradient id=\"m\(i)\"><stop offset=\"0%\" stop-color=\"\(color)\"/><stop offset=\"100%\" stop-color=\"\(color)\" stop-opacity=\"0\"/></radialGradient>")
        }
        body.append("<rect width=\"\(size.width)\" height=\"\(size.height)\" fill=\"\(mean.hexString)\"/>")
        var circles: [String] = []
        for (i, point) in points.enumerated() {
            circles.append("<circle cx=\"\(format(point.x * w))\" cy=\"\(format(point.y * h))\" r=\"\(format(reach))\" fill=\"url(#m\(i))\"/>")
        }
        body.append("<g filter=\"url(#soft)\">" + circles.joined() + "</g>")
    }

    private func pattern(_ p: PatternParameters, defs: inout [String], body: inout [String]) {
        let w = size.width, h = size.height
        let s = format(p.scale)
        let transform = p.angle == 0 ? "" : " patternTransform=\"rotate(\(format(p.angle)) \(format(Double(w) / 2)) \(format(Double(h) / 2)))\""
        switch p.kind {
        case .dots:
            defs.append("<pattern id=\"p\" width=\"\(s)\" height=\"\(s)\" patternUnits=\"userSpaceOnUse\"><circle cx=\"\(format(p.scale / 2))\" cy=\"\(format(p.scale / 2))\" r=\"\(format(p.scale * 0.28))\" fill=\"\(p.foreground.hexString)\"/></pattern>")
        case .lines:
            defs.append("<pattern id=\"p\" width=\"\(s)\" height=\"\(s)\" patternUnits=\"userSpaceOnUse\"\(transform)><rect width=\"\(format(p.scale / 2))\" height=\"\(s)\" fill=\"\(p.foreground.hexString)\"/></pattern>")
        case .checks:
            let half = format(p.scale)
            let double = format(p.scale * 2)
            defs.append("<pattern id=\"p\" width=\"\(double)\" height=\"\(double)\" patternUnits=\"userSpaceOnUse\"\(transform)><rect x=\"\(half)\" width=\"\(half)\" height=\"\(half)\" fill=\"\(p.foreground.hexString)\"/><rect y=\"\(half)\" width=\"\(half)\" height=\"\(half)\" fill=\"\(p.foreground.hexString)\"/></pattern>")
        case .noise:
            embedRender(body: &body)
            return
        }
        body.append("<rect width=\"\(w)\" height=\"\(h)\" fill=\"\(p.background.hexString)\"/>")
        body.append("<rect width=\"\(w)\" height=\"\(h)\" fill=\"url(#p)\"/>")
    }

    /// The raster itself, as a PNG data URL, at the requested size and
    /// without grain (the filter adds it, once).
    private func embedRender(body: inout [String]) {
        var plain = wallpaper
        plain.grain = 0
        let raster = renderer.render(plain, side: side, context: context)
        guard let png = raster.pngData() else { return }
        body.append("<image width=\"\(size.width)\" height=\"\(size.height)\" style=\"image-rendering:pixelated\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>")
    }

    private func format(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.2f", value)
    }
}
