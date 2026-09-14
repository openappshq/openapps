import AppKit
import OpenReactionCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var statusMenu: StatusMenuController?
    private var onboarding: OnboardingWindowController?
    private var preview: PreviewHarness?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppResources.registerFonts()
        if Bundle.main.bundleIdentifier == nil, let icon = AppResources.appIcon() {
            // Running unbundled via `swift run`.
            NSApp.applicationIconImage = icon
        }

        let database: EmojiDatabase
        do {
            database = EmojiRenderability.filter(try EmojiDatabase.bundled())
        } catch {
            let alert = NSAlert()
            alert.messageText = "OpenReaction can't load its emoji list"
            alert.informativeText = "Reinstall OpenReaction. (\(error.localizedDescription))"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let provider = EmojiSuggestionProvider(database: database)
        if CommandLine.arguments.contains("--preview-picker") {
            preview = PreviewHarness(provider: provider, layout: CommandLine.arguments.contains("--strip") ? .strip : .list)
            return
        }

        let controller = AppController(provider: provider)
        let onboarding = OnboardingWindowController(controller: controller)
        let statusMenu = StatusMenuController(controller: controller) { onboarding.show() }
        controller.onStateChange = { [weak statusMenu] in statusMenu?.updateButton() }
        self.controller = controller
        self.onboarding = onboarding
        self.statusMenu = statusMenu

        controller.start()
        if !controller.permissions.allGranted {
            onboarding.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onboarding?.show()
        return true
    }
}
