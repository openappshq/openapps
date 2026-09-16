import AppKit
import OpenAppsLicensing
import SwiftUI

/// The license status as a small capsule: the trial's remaining time, or
/// the short reason the notes are read-only. Clicking it opens Settings →
/// License. Shown at the top of the open note, in All Notes' toolbar, the
/// settings window's title bar and on the guide's welcome step. Hidden
/// while simply licensed.
struct LicensePill: View {
    let label: LicenseBadge.Label
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if label.tone == .attention {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    Circle()
                        .fill(Brand.accentSolid)
                        .frame(width: 6, height: 6)
                }
                Text(label.text)
                    .font(Brand.mono(11, medium: true))
                    .lineLimit(1)
            }
            .foregroundStyle(label.tone == .trial ? Brand.accentText : Brand.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .modifier(PillSurface(tone: label.tone))
            .contentShape(Capsule())
        }
        .buttonStyle(PillButtonStyle())
        .help("Opens License settings")
        .accessibilityLabel("License: \(label.text)")
        .accessibilityHint("Opens License settings")
        .animation(Motion.standard(reduceMotion: reduceMotion), value: label)
    }
}

/// The pill right-aligned in a row, while the status has something to
/// say; nothing otherwise. Read on every body: All Notes' toolbar and the
/// open note's top edge use it.
struct LicensePillHeader: View {
    let license: LicenseStatus

    var body: some View {
        if let badge = license.badge() {
            HStack {
                Spacer()
                LicensePill(label: badge, action: license.openLicense)
            }
        }
    }
}

/// Capsule behind the pill: Liquid Glass tinted with the tone's color on
/// macOS 26, a flat brand fill before that, with Reduce Transparency, or
/// in the preview harness (`ImageRenderer` draws no glass). Increase
/// Contrast adds a visible rim in every case.
private struct PillSurface: ViewModifier {
    let tone: LicenseBadge.Tone
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.previewRendering) private var previewRendering

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26, *), !reduceTransparency, !previewRendering {
                content.glassEffect(.regular.tint(glassTint).interactive(), in: Capsule())
            } else {
                content.background(flatFill, in: Capsule())
            }
        }
        .overlay {
            Capsule().strokeBorder(rim, lineWidth: 1)
        }
    }

    /// Glass blends its tint with what is behind it, so the trial's tint is
    /// the solid accent at low opacity rather than the already pale subtle
    /// token: it reads at a glance on a white title bar and stays in the
    /// same family in dark.
    private var glassTint: Color {
        tone == .trial ? Brand.accentSolid.opacity(0.2) : Brand.surface
    }

    private var flatFill: Color {
        tone == .trial ? Brand.accentSubtle : Brand.surface
    }

    private var rim: Color {
        if contrast == .increased { return Brand.textPrimary.opacity(0.6) }
        return tone == .trial ? Brand.accentSolid.opacity(0.35) : Brand.borderSubtle
    }
}

/// Press feedback for the pill; the cursor says it is clickable.
private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: Brand.Motion.fast), value: configuration.isPressed)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Hosts the pill at the trailing end of the settings window's title bar.
/// `badge` is read under observation tracking, so an `@Observable` source
/// (the license controller) re-lays the pill out as its text changes.
/// Hidden while there is nothing to say (licensed).
@MainActor
final class LicensePillAccessory: NSTitlebarAccessoryViewController {
    private let badge: () -> LicenseBadge.Label?
    private let action: () -> Void
    private let hosting: NSHostingView<AnyView>

    init(badge: @escaping () -> LicenseBadge.Label?, action: @escaping () -> Void) {
        self.badge = badge
        self.action = action
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
        view = hosting
        observeChanges { [badge] in
            _ = badge()
        } onChange: { [weak self] in
            self?.update()
        }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        update()
    }

    /// The pill, centered in a view as tall as the title bar: AppKit places
    /// a trailing accessory by its frame, so the height must match.
    private func update() {
        guard let label = badge() else {
            isHidden = true
            return
        }
        let action = self.action
        let height = titleBarHeight
        hosting.rootView = AnyView(
            LicensePill(label: label, action: action)
                .padding(.trailing, Brand.Space.s8)
                .padding(.leading, Brand.Space.s4)
                .frame(height: height)
        )
        view.frame = NSRect(x: 0, y: 0, width: hosting.fittingSize.width, height: height)
        isHidden = false
    }

    private var titleBarHeight: CGFloat {
        guard let window = view.window else { return 28 }
        return max(22, window.frame.height - window.contentLayoutRect.height)
    }
}

/// The card All Notes shows above its list while read-only: the state in
/// LICENSING.md's words, what it means for the notes, and the way out.
/// Asked on every body, so it appears and disappears with the projection.
struct LicenseCard: View {
    let license: LicenseStatus

    var body: some View {
        if let card = license.restriction() {
            VStack(alignment: .leading, spacing: Brand.Space.s8) {
                HStack(spacing: Brand.Space.s8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Brand.accentText)
                        .accessibilityHidden(true)
                    Text(card.title)
                        .font(Brand.body(14, weight: 600))
                        .foregroundStyle(Brand.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(card.detail)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Brand.Space.s8) {
                    ForEach(Array(card.actions.enumerated()), id: \.offset) { index, action in
                        Button(buttonTitle(action)) { license.perform(action) }
                            .buttonStyle(index == 0 ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
                            .disabled(license.isBusy || (action == .buy && !license.canBuy))
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(Brand.Space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.accentSubtle, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous).strokeBorder(Brand.accentSolid.opacity(0.35), lineWidth: 1))
            .accessibilityElement(children: .contain)
        }
    }

    /// The Buy button never states a price; without a website page it says
    /// so and is disabled.
    private func buttonTitle(_ action: LicenseRestriction.Action) -> String {
        action == .buy && !license.canBuy ? "Buy a license — coming soon" : action.title
    }
}

/// A button style chosen at runtime (the card's first action is primary).
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some ButtonStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
