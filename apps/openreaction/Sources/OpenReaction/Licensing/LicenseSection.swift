#if OPENAPPS_LICENSING
import AppKit
import OpenReactionCore
import SwiftUI

/// Settings → License. States and copy follow LICENSING.md.
struct LicenseSection: View {
    let license: LicenseController

    @State private var key = ""
    @State private var showsKeyField = false

    var body: some View {
        Section {
            statusRow
            if let message = license.message {
                Text(message.text)
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let pending = license.pendingKey {
                pendingKeyRow(pending)
            }
            actions
            if showsKeyField || needsKeyField {
                keyField
            }
        } header: {
            MonoLabel("License")
        } footer: {
            Text(LicensingCopy.privacy)
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
        }
        .onChange(of: license.pendingKey) { _, pending in
            if let pending { key = pending }
        }
    }

    private var needsKeyField: Bool {
        switch license.state {
        case .unlicensed, .trialEnded, .revoked: true
        default: false
        }
    }

    // MARK: - Rows

    private var statusRow: some View {
        LabeledContent {
            Text(statusText)
                .font(Brand.mono(13, medium: true))
                .foregroundStyle(license.isFeatureEnabled ? Brand.successSolid : Brand.textSecondary)
                .multilineTextAlignment(.trailing)
        } label: {
            Text("Status").font(Brand.body(14))
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch license.state {
        case .unlicensed: "Not licensed"
        case .trial(let days): "Trial: about \(days) day\(days == 1 ? "" : "s") left"
        case .trialEnded: "Your trial has ended"
        case .licensed: "Licensed"
        case .grace(let days, let warn):
            warn ? "Connect to the internet within \(days) day\(days == 1 ? "" : "s") to keep using OpenReaction" : "Licensed"
        case .checkRequired: "Connect to the internet to verify your license"
        case .revoked: "This license is no longer active on this Mac"
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Brand.Space.s8) {
            switch license.state {
            case .unlicensed:
                if !license.trialUsed {
                    Button("Start 3-day trial") { openURL(LicensingConfig.trialURL) }
                        .help("Opens the free trial checkout; you’ll get a trial key by email")
                }
                buyButton
                Spacer()
                enterKeyButton
            case .trial:
                buyButton
                Spacer()
                enterKeyButton
                removeButton
            case .trialEnded:
                buyButton
                Spacer()
                enterKeyButton
            case .licensed, .grace:
                Spacer()
                removeButton
            case .checkRequired:
                Button("Try again") { Task { await license.tryAgain() } }
                    .buttonStyle(PrimaryButtonStyle())
                Spacer()
                removeButton
            case .revoked:
                Button("Activate again") { license.forgetRevokedRecord(); showsKeyField = true }
                buyButton
                Link("Contact support", destination: LicensingConfig.supportURL)
                Spacer()
            }
        }
        .disabled(license.isBusy)
    }

    private var buyButton: some View {
        Button("Buy for $5") { openURL(LicensingConfig.buyURL) }
            .buttonStyle(PrimaryButtonStyle())
            .help("Opens the checkout; you’ll get a license key by email")
    }

    private var enterKeyButton: some View {
        Button(showsKeyField ? "Hide key field" : "Enter a key") { showsKeyField.toggle() }
            .buttonStyle(SecondaryButtonStyle())
    }

    private var removeButton: some View {
        Button("Remove this Mac", action: confirmRemove)
            .buttonStyle(SecondaryButtonStyle())
            .help("Frees this Mac’s activation so another Mac can use the license")
    }

    private var keyField: some View {
        HStack(spacing: Brand.Space.s8) {
            TextField("Paste your license key", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(Brand.mono(13))
                .accessibilityLabel("License key")
                .onSubmit(activateTypedKey)
            Button("Activate", action: activateTypedKey)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || license.isBusy)
        }
    }

    private func pendingKeyRow(_ pending: String) -> some View {
        HStack(spacing: Brand.Space.s8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activate this Mac with the key from your browser?")
                    .font(Brand.body(14))
                Text(pending)
                    .font(Brand.mono(12))
                    .foregroundStyle(Brand.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Not now") { license.pendingKey = nil }
                .buttonStyle(SecondaryButtonStyle())
            Button("Activate") {
                license.pendingKey = nil
                Task { await license.activate(key: pending) }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Actions

    private func activateTypedKey() {
        let typed = key
        Task {
            await license.activate(key: typed)
            if case .activated = license.message { key = ""; showsKeyField = false }
        }
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove this Mac from the license?"
        alert.informativeText = "OpenReaction will stop working here until you activate again. The activation is freed for another Mac."
        alert.addButton(withTitle: "Remove this Mac")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await license.removeThisMac() }
        }
    }

    private func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
#endif
