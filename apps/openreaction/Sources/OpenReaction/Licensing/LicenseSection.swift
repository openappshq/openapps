#if OPENAPPS_LICENSING
import AppKit
import OpenReactionCore
import SwiftUI

/// Settings → License. States and copy follow LICENSING.md.
struct LicenseSection: View {
    let license: LicenseController
    /// Scroll target for "Settings → License" (the pill, the status menu).
    let anchor: SettingsNavigation.Anchor

    @State private var key = ""
    @State private var showsKeyField = false

    var body: some View {
        Section {
            statusRow
            if let error = license.storageError {
                note(LicenseMessage.storageUnavailable.text + " (\(Self.describe(error)))")
            } else if let error = license.trialStorageError {
                note("OpenReaction can’t read or save its free trial in the Keychain right now. It keeps retrying; unlock the Keychain if it stays locked. (\(Self.describe(error)))")
            } else if license.journalError {
                note("OpenReaction couldn’t save its license notes in Preferences. It keeps retrying.")
            }
            if let message = license.message {
                note(message.text)
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
            MonoLabel("License").id(anchor)
        } footer: {
            Text(LicensingCopy.privacy)
                .font(Brand.body(12))
                .foregroundStyle(Brand.textSecondary)
        }
        .onChange(of: license.pendingKey) { _, pending in
            if let pending { key = pending }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Brand.body(12))
            .foregroundStyle(Brand.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func describe(_ error: LicenseStoreError) -> String {
        switch error {
        case .unavailable(let reason): reason
        case .corrupt: "the stored record is unreadable"
        }
    }

    /// Without a license the key field is always there, next to Buy.
    private var needsKeyField: Bool {
        switch license.state {
        case .trialUnavailable, .trial, .trialNeedsConnection, .trialClockBehind, .trialEnded: true
        case .licensed, .grace, .checkRequired, .revoked: false
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
        case .trialUnavailable:
            license.storageError == nil && license.trialStorageError == nil ? "Starting your free trial…" : "Free trial unavailable"
        case .trial(let days): LicenseController.trialText(daysLeft: days)
        case .trialNeedsConnection: "Connect to the internet to continue your free trial"
        case .trialClockBehind: LicenseController.clockBehindText
        case .trialEnded: "Your free trial has ended"
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
            case .trialUnavailable:
                if license.storageError != nil || license.trialStorageError != nil {
                    tryAgainButton
                }
                buyButton
                Spacer()
            case .trial, .trialEnded:
                buyButton
                Spacer()
            case .trialNeedsConnection:
                tryAgainButton
                buyButton
                Spacer()
            case .trialClockBehind:
                buyButton
                Spacer()
            case .licensed, .grace:
                Spacer()
                removeButton
            case .checkRequired:
                tryAgainButton
                Spacer()
                removeButton
            case .revoked:
                // Only an explicit activation can unlock again; showing the
                // field changes nothing until a key is submitted.
                Button("Activate again") { showsKeyField = true }
                buyButton
                if let support = LicensingConfig.supportURL {
                    Link("Contact support", destination: support)
                }
                Spacer()
            }
        }
        .disabled(license.isBusy)
    }

    private var tryAgainButton: some View {
        Button("Try again") { Task { await license.tryAgain() } }
            .buttonStyle(PrimaryButtonStyle())
    }

    /// Checkout links exist only once the website ships them; until then the
    /// button says so instead of opening a page that is not there. The price
    /// is the website's to state: it may change, or carry an offer.
    private var buyButton: some View {
        Button(LicensingConfig.buyURL == nil ? "Buy a license — coming soon" : "Buy a license") {
            if let url = LicensingConfig.buyURL { openURL(url) }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(LicensingConfig.buyURL == nil)
        .help("Opens the checkout; you’ll get a license key by email")
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
            if license.message == .activated { key = ""; showsKeyField = false }
        }
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.messageText = "Remove this Mac from the license?"
        alert.informativeText = "The activation is freed for another Mac. OpenReaction goes back to its free trial here, and stops if the trial has already ended, until you activate again."
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
