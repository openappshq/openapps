import AppKit
import HertzCore
import SwiftUI

/// How a reading is doing. Colour is never the only carrier: a warning or
/// critical level always comes with a label or a shape as well, because the
/// healthy colour is also Hertz's accent.
enum Level {
    case ok, warning, critical

    var color: Color {
        switch self {
        case .ok: return Brand.successSolid
        case .warning: return Brand.warningSolid
        case .critical: return Brand.dangerSolid
        }
    }

    /// Percent of a capacity: fine to 60, high to 85, critical above.
    static func load(_ percent: Double) -> Level {
        switch percent {
        case ..<60: return .ok
        case ..<85: return .warning
        default: return .critical
        }
    }

    static func health(_ score: Int) -> Level {
        switch score {
        case 80...: return .ok
        case 55..<80: return .warning
        default: return .critical
        }
    }

    /// Battery charge: the scale runs the other way.
    static func charge(_ percent: Double) -> Level {
        switch percent {
        case ..<20: return .critical
        case ..<40: return .warning
        default: return .ok
        }
    }

    static func severity(_ severity: DiagnosticSeverity) -> Level {
        switch severity {
        case .info: return .ok
        case .warning: return .warning
        case .critical: return .critical
        }
    }
}

/// One dashboard section on its own glass surface.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s8) {
            content
        }
        .padding(Brand.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 12)
    }
}

/// The card's first line: its mono label on the left, the headline reading
/// or the card's actions on the right.
struct CardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Brand.Space.s8) {
            MonoLabel(title)
            Spacer(minLength: Brand.Space.s8)
            trailing
        }
        .frame(minHeight: 20)
    }
}

extension CardHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title, trailing: { EmptyView() })
    }
}

/// The headline value on the right of a card header. Text stays in the text
/// colour; a state that needs attention adds a pill beside it.
struct Readout: View {
    let value: String
    var level: Level = .ok

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Brand.Space.s8) {
            if level != .ok {
                StatePill(level: level)
            }
            Text(value)
                .font(Brand.mono(15, medium: true))
                .foregroundStyle(Brand.textPrimary)
        }
    }
}

/// "HIGH" or "CRITICAL" in a tinted capsule. Warning uses HQ yellow with ink
/// text; critical uses the danger colours.
struct StatePill: View {
    let level: Level
    var text: String? = nil

    private var label: String {
        if let text { return text }
        switch level {
        case .ok: return "OK"
        case .warning: return "HIGH"
        case .critical: return "CRITICAL"
        }
    }

    var body: some View {
        Text(label)
            .font(Brand.mono(9, medium: true))
            .tracking(0.4)
            .foregroundStyle(level == .critical ? Brand.dangerSolid : Color(nsColor: NSColor(hex: 0x141414)))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(level == .critical ? Brand.dangerSubtle : level == .warning ? Brand.warningSolid : Brand.accentSubtle))
            .accessibilityLabel(label.lowercased())
    }
}

/// One line of secondary facts under a chart.
struct DetailLine: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Brand.mono(11))
            .foregroundStyle(Brand.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// A value with its name under it, for a row of readings.
struct Stat: View {
    let label: String
    let value: String
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Brand.Space.s4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Brand.textSecondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(Brand.mono(13, medium: true))
                    .foregroundStyle(Brand.textPrimary)
                Text(label)
                    .font(Brand.mono(10))
                    .foregroundStyle(Brand.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A short confirmation under a card's rows ("Copied", "Revealed in Finder").
struct Note: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Brand.body(12))
            .foregroundStyle(Brand.textSecondary)
            .lineLimit(1)
    }
}

/// A small count in a capsule beside a name.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Brand.mono(9, medium: true))
            .foregroundStyle(Brand.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Brand.hover))
    }
}

struct ProcessIcon: View {
    let path: String

    var body: some View {
        if let image = IconProvider.shared.icon(forPath: path) {
            Image(nsImage: image).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 12))
                .foregroundStyle(Brand.textSecondary)
                .frame(width: 16, height: 16)
        }
    }
}

/// Resolves and caches process icons. App bundles get their real icon;
/// plain executables get the system's generic binary icon.
final class IconProvider {
    static let shared = IconProvider()
    private var cache: [String: NSImage] = [:]

    func icon(forPath path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = cache[path] { return cached }
        let target: String
        if let range = path.range(of: ".app/") {
            target = String(path[..<range.lowerBound]) + ".app"
        } else {
            target = path
        }
        let image = NSWorkspace.shared.icon(forFile: target)
        cache[path] = image
        return image
    }
}

/// Copies text that carries no reading (the upgrade command, Copy
/// Diagnostics' gated text). Readings leave only through `MetricsModel`'s
/// export actions.
func copyToPasteboard(_ text: String) {
    ExportSinks.clipboard(text)
}

let shortEventTime: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()
