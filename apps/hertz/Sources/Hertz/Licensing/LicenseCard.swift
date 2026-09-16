import AppKit
import OpenAppsLicensing
import SwiftUI

/// The dashboard while the readings are off: one card at the top, in place
/// of the metric cards, saying why and what to do (design/products/hertz.md,
/// "Licensing"). The footer with Settings and Quit stays underneath. Never
/// shown by a build without licensing, whose status has no restriction.
struct LicenseCard: View {
    let restriction: LicenseRestriction
    let status: LicenseStatus

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: Brand.Space.s8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.textPrimary)
                    .accessibilityHidden(true)
                Text(restriction.title)
                    .font(Brand.body(15, weight: 600))
                    .foregroundStyle(Brand.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(restriction.detail)
                .font(Brand.body(13))
                .lineSpacing(2)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Brand.Space.s8) {
                ForEach(Array(restriction.actions.enumerated()), id: \.offset) { index, action in
                    button(for: action, primary: index == 0)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, Brand.Space.s4)
            .disabled(status.isBusy)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("License: \(restriction.title)")
    }

    @ViewBuilder private func button(for action: LicenseRestriction.Action, primary: Bool) -> some View {
        switch action {
        case .buy:
            // The website states the price; the button never does.
            Button(status.canBuy ? "Buy a license" : "Buy a license — coming soon", action: status.buy)
                .modifier(Emphasis(primary: primary))
                .disabled(!status.canBuy)
                .help("Opens the website; you’ll get a license key by email")
        case .enterKey:
            Button("Enter a key", action: status.enterKey)
                .modifier(Emphasis(primary: primary))
                .help("Opens License settings with the key field")
        case .tryAgain:
            Button("Try again", action: status.tryAgain)
                .modifier(Emphasis(primary: primary))
        }
    }

    /// The first action is the filled one; the rest are outlined.
    private struct Emphasis: ViewModifier {
        let primary: Bool

        func body(content: Content) -> some View {
            if primary {
                content.buttonStyle(PrimaryButtonStyle())
            } else {
                content.buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}
