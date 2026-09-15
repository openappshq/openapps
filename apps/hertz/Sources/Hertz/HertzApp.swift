import AppKit
import HertzCore
import SwiftUI

@main
struct HertzApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                model: delegate.model,
                preferences: delegate.preferences,
                showSettings: delegate.showSettings
            )
        } label: {
            MenuBarLabel(model: delegate.model, preferences: delegate.preferences)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The symbol, plus the chosen readout. The readout uses the system font like
/// every other status item; the brand fonts belong inside the dashboard.
private struct MenuBarLabel: View {
    let model: MetricsModel
    let preferences: Preferences

    var body: some View {
        let text = preferences.menuBarReadout.text(cpu: model.cpu, memory: model.memory)
        Label {
            if !text.isEmpty {
                Text(text).font(.system(size: 12).monospacedDigit())
            }
        } icon: {
            Image(nsImage: AppResources.menuBarImage())
        }
        .accessibilityLabel(text.isEmpty ? "Hertz" : "Hertz, \(preferences.menuBarReadout.title) \(text)")
    }
}

/// Owns the long-lived objects: the metrics model, preferences, login item
/// and the two windows. Menu-bar only: no Dock icon, no main window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MetricsModel()
    let preferences = Preferences()
    let loginItem = LoginItem()
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?

    override init() {
        super.init()
        AppResources.registerFonts()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let icon = AppResources.appIcon() { NSApp.applicationIconImage = icon }
        // Once, on the first launch of the packaged app. `swift run` builds
        // skip it so a development loop never opens a window.
        if !preferences.didShowWelcome, Bundle.main.bundleURL.pathExtension == "app" {
            preferences.didShowWelcome = true
            showWelcome()
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                model: model, preferences: preferences, loginItem: loginItem,
                showWelcome: { [weak self] in self?.showWelcome() }
            )
        }
        settingsWindow?.show()
    }

    func showWelcome() {
        if welcomeWindow == nil {
            welcomeWindow = WelcomeWindowController(preferences: preferences, loginItem: loginItem)
        }
        welcomeWindow?.show()
    }
}
