#if OPENAPPS_LICENSING
import AppKit
import OpenReactionCore
import SwiftUI

/// Settings → License. States and copy follow LICENSING.md.
struct LicenseSection: View {
    let license: LicenseController

    @State private var key = ""
    @State private var showsKeyField = false
    /// The key field is for a trial key (refused locally after one trial).
    @State private var keyFieldIsTrial = false

    var body: some View {
        Section {
            statusRow
            if let error = license.storageError {
                Text(LicenseMessage.storageUnavailable.text + " (\(Self.describe(error)))")
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if license.journalError {
                Text("OpenReaction couldn’t save its license notes in Preferences. It keeps retrying.")
                    .font(Brand.body(12))
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            if let pending { key = pending.key }
        }
    }

    private static func describe(_ error: LicenseStoreError) -> String {
        switch error {
        case .unavailable(let reason): reason
        case .corrupt: "the stored license is unreadable"
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
        case .trialEnded(clockChanged: false): "Your trial has ended"
        case .trialEnded(clockChanged: true): "Clock changed — connect to the internet to verify your trial"
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
                    trialButton
                }
                buyButton
                Spacer()
                if !license.trialUsed {
                    Button(keyFieldIsTrial && showsKeyField ? "Hide key field" : "Enter a trial key") {
                        keyFieldIsTrial = true
                        showsKeyField.toggle()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                enterKeyButton
            case .trial:
                buyButton
                Spacer()
                enterKeyButton
                removeButton
            case .trialEnded(clockChanged: false):
                buyButton
                Spacer()
                enterKeyButton
            case .trialEnded(clockChanged: true):
                Button("Try again") { Task { await license.tryAgain() } }
                    .buttonStyle(PrimaryButtonStyle())
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
                // Only an explicit activation can unlock again; showing the
                // field changes nothing until a key is submitted.
                Button("Activate again") { keyFieldIsTrial = false; showsKeyField = true }
                buyButton
                if let support = LicensingConfig.supportURL {
                    Link("Contact support", destination: support)
                }
                Spacer()
            }
        }
        .disabled(license.isBusy)
    }

    /// Checkout links exist only once the website ships them; until then the
    /// buttons say so instead of opening a page that is not there.
    private var buyButton: some View {
        Button(LicensingConfig.buyURL == nil ? "Buy for $5 — coming soon" : "Buy for $5") {
            if let url = LicensingConfig.buyURL { openURL(url) }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(LicensingConfig.buyURL == nil)
        .help("Opens the checkout; you’ll get a license key by email")
    }

    private var trialButton: some View {
        Button(LicensingConfig.trialURL == nil ? "Start 3-day trial — coming soon" : "Start 3-day trial") {
            if let url = LicensingConfig.trialURL { openURL(url) }
        }
        .disabled(LicensingConfig.trialURL == nil)
        .help("Opens the free trial checkout; you’ll get a trial key by email")
    }

    private var enterKeyButton: some View {
        Button(showsKeyField && !keyFieldIsTrial ? "Hide key field" : "Enter a license key") {
            keyFieldIsTrial = false
            showsKeyField.toggle()
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    private var removeButton: some View {
        Button("Remove this Mac", action: confirmRemove)
            .buttonStyle(SecondaryButtonStyle())
            .help("Frees this Mac’s activation so another Mac can use the license")
    }

    private var keyField: some View {
        HStack(spacing: Brand.Space.s8) {
            TextField(keyFieldIsTrial ? "Paste your trial key" : "Paste your license key", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(Brand.mono(13))
                .accessibilityLabel("License key")
                .onSubmit(activateTypedKey)
            Button("Activate", action: activateTypedKey)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || license.isBusy)
        }
    }

    private func pendingKeyRow(_ pending: LicenseController.PendingKey) -> some View {
        HStack(spacing: Brand.Space.s8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.kind == .trial ? "Start the trial on this Mac with the key from your browser?" : "Activate this Mac with the key from your browser?")
                    .font(Brand.body(14))
                Text(pending.key)
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
                Task {
                    if pending.kind == .trial {
                        await license.activateTrial(key: pending.key)
                    } else {
                        await license.activate(key: pending.key)
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Actions

    private func activateTypedKey() {
        let typed = key
        let trial = keyFieldIsTrial
        Task {
            if trial {
                await license.activateTrial(key: typed)
            } else {
                await license.activate(key: typed)
            }
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
