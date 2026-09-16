import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    #if DEBUG
    // `OpenNotes --preview <directory>`: renders the deck's states, All
    // Notes and Settings to PNGs without a status item, a window, a login
    // item, a hotkey or the user's notes folder, then quits
    // (PreviewHarness.swift).
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--preview"), arguments.count > index + 1 {
        app.setActivationPolicy(.prohibited)
        let harness = PreviewHarness(outputDirectory: URL(fileURLWithPath: arguments[index + 1]))
        Task { @MainActor in
            let ok = await harness.run()
            exit(ok ? 0 : 1)
        }
        app.run()
    }
    #endif
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
