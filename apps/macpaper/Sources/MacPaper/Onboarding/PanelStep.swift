import MacPaperCore
import SwiftUI

/// "Where the panel lives": the setup guide's step that shows the notch
/// hover zone — a looping animation of the pointer reaching the notch and
/// the column dropping — and says the menu-bar icon and the shortcut open
/// the same panel. On a Mac without a notch (or with the panel hosted on
/// none) the step shows the pointer reaching the menu-bar icon instead
/// and says those are the triggers (design/products/macpaper.md, "The
/// panel", first run).
struct PanelStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.s24) {
            VStack(alignment: .leading, spacing: Brand.Space.s12) {
                MonoLabel("The panel")
                Text(model.hasNotch ? "It hangs from the notch." : "It lives in the menu bar.")
                    .font(Brand.display(40))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(GuideCopy.panelLine(hasNotch: model.hasNotch, shortcut: model.shortcut))
                    .font(Brand.body(16))
                    .lineSpacing(4)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PanelDemo(hasNotch: model.hasNotch)
                .frame(maxWidth: .infinity)
                .frame(height: PanelDemo.height)
                .cardSurface()

            Spacer(minLength: 0)
            HStack(spacing: Brand.Space.s12) {
                Button("Continue", action: model.advance)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Back", action: model.back)
                    .buttonStyle(LinkButtonStyle())
                Spacer(minLength: 0)
                Button("Skip for now", action: model.skip)
                    .buttonStyle(LinkButtonStyle())
            }
        }
        .padding(Brand.Space.s32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The step's words, kept where the tests can read them.
extension GuideCopy {
    /// What the panel step says under its heading.
    static func panelLine(hasNotch: Bool, shortcut: String?) -> String {
        if hasNotch {
            let key = shortcut.map { ", and so does \($0)" } ?? ""
            return "Rest the pointer on the notch, or click it, and the column drops from it. The menu bar icon opens the same panel\(key). On the first launches a glow under the notch marks the spot."
        }
        let key = shortcut.map { ", or press \($0) from anywhere" } ?? ""
        return "This Mac has no notch, so the panel opens under the menu bar icon: click it\(key)."
    }
}

/// A drawn display — the menu bar with its notch and the macPaper item,
/// a desktop under it — on which the pointer travels to the trigger and
/// the column drops, over and over. Drawn from the clock (`TimelineView`)
/// so the loop never drifts and needs no timer; under Reduce Motion, and
/// for the harness, the last frame holds still: the pointer on the
/// trigger, the column open.
struct PanelDemo: View {
    let hasNotch: Bool
    static let height: CGFloat = 170
    /// One loop, in seconds.
    static let cycle: TimeInterval = 4.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        if reduceMotion || previewRendering {
            frame(at: 2.6)
        } else {
            TimelineView(.animation) { context in
                frame(at: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle))
            }
        }
    }

    /// The loop's phases: the pointer travels (0–1.4 s), rests (to 1.7),
    /// the column drops (to 2.0) and stays (to 3.5), then fades (to 3.9)
    /// and the pointer returns (to 4.4).
    private func frame(at t: TimeInterval) -> some View {
        let travel = Self.ease(Self.phase(t, 0, 1.4))
        let drop = Self.ease(Self.phase(t, 1.7, 2.0)) * (1 - Self.ease(Self.phase(t, 3.5, 3.9)))
        let glow = min(Self.phase(t, 0.9, 1.3), 1 - Self.ease(Self.phase(t, 3.5, 3.9)))
        let back = Self.ease(Self.phase(t, 3.9, 4.4))
        return GeometryReader { proxy in
            let size = proxy.size
            let menuBar: CGFloat = 26
            let notch = CGRect(x: size.width / 2 - 45, y: 0, width: 90, height: menuBar - 3)
            let item = CGRect(x: size.width - 92, y: 3, width: 20, height: 20)
            let trigger = hasNotch ? CGPoint(x: notch.midX, y: notch.midY + 2) : CGPoint(x: item.midX, y: item.midY + 2)
            let start = CGPoint(x: size.width * 0.28, y: size.height * 0.78)
            let pointer = CGPoint(
                x: start.x + (trigger.x - start.x) * travel - (trigger.x - start.x) * back,
                y: start.y + (trigger.y - start.y) * travel - (trigger.y - start.y) * back
            )
            let columnWidth: CGFloat = 132
            let columnHeight = size.height - menuBar - 14
            let columnX = hasNotch ? notch.midX - columnWidth / 2 : min(item.midX - columnWidth / 2, size.width - columnWidth - 8)
            ZStack(alignment: .topLeading) {
                // The desktop: a quiet mesh in the brand's tangerine.
                LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xFF7A2F)), Color(nsColor: NSColor(hex: 0xFFB48A)), Color(nsColor: NSColor(hex: 0x4A2114))], startPoint: .topLeading, endPoint: .bottomTrailing)
                // The menu bar.
                Rectangle().fill(Color.black.opacity(0.18)).frame(height: menuBar)
                HStack(spacing: 10) {
                    Image(systemName: "apple.logo").font(.system(size: 11, weight: .semibold))
                    Text("Finder").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: "wifi").font(.system(size: 11))
                    Image(nsImage: AppResources.menuBarImage()).renderingMode(.template)
                        .frame(width: item.width, height: item.height)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(hasNotch ? 0 : 0.25 * drop)))
                    Text("9:41").font(.system(size: 11))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: menuBar)
                if hasNotch {
                    // The glow under the notch, then the notch itself.
                    NotchGlow()
                        .frame(width: notch.width + 2 * PanelLayout.hintReach * 0.4, height: PanelLayout.hintDepth)
                        .offset(x: notch.midX - (notch.width + 2 * PanelLayout.hintReach * 0.4) / 2, y: notch.maxY)
                        .opacity(glow * (1 - drop))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black)
                        .frame(width: notch.width, height: notch.height + 8)
                        .offset(x: notch.minX, y: -8)
                }
                // The column: squared against the notch, rounded under the item.
                MiniColumn(squaredTop: hasNotch)
                    .frame(width: columnWidth, height: columnHeight)
                    .offset(x: columnX, y: (hasNotch ? notch.maxY : menuBar + 6) - columnHeight * (1 - drop) * 0.12)
                    .opacity(drop)
                // The pointer.
                Image(systemName: "cursorarrow")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                    // The arrow's tip, not the glyph's center, lands on the trigger.
                    .position(x: pointer.x + 6, y: pointer.y + 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasNotch
            ? "The pointer reaches the notch and the panel drops from it; the menu bar icon opens the same panel"
            : "The pointer reaches the menu bar icon and the panel opens under it")
    }

    /// 0 before `from`, 1 after `to`, linear between.
    private static func phase(_ t: TimeInterval, _ from: TimeInterval, _ to: TimeInterval) -> CGFloat {
        CGFloat(max(0, min(1, (t - from) / (to - from))))
    }

    /// Ease out, quartic: fast start, soft landing.
    private static func ease(_ x: CGFloat) -> CGFloat {
        1 - pow(1 - x, 4)
    }
}

/// The column in miniature: the rail's dots and the pane's lines.
private struct MiniColumn: View {
    let squaredTop: Bool

    var body: some View {
        NotchPanelShape(squaredTop: squaredTop)
            .fill(Brand.Panel.ground)
            .overlay(NotchPanelShape(squaredTop: squaredTop).strokeBorder(Brand.Panel.rim, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 6) {
                        Circle().fill(Brand.Panel.accent).frame(width: 6, height: 6)
                        ForEach(0..<5, id: \.self) { index in
                            Circle().fill(index == 0 ? Brand.Panel.accent : Brand.Panel.textSecondary.opacity(0.6)).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.top, 10)
                    .padding(.leading, 8)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Brand.Panel.textPrimary).frame(width: 40, height: 6)
                        RoundedRectangle(cornerRadius: 4).fill(Brand.Panel.surface).frame(height: 44)
                        ForEach(0..<3, id: \.self) { _ in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(Brand.Panel.surface).frame(width: 18, height: 12)
                                RoundedRectangle(cornerRadius: 2).fill(Brand.Panel.textSecondary.opacity(0.5)).frame(height: 5)
                            }
                        }
                    }
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                }
            }
    }
}
