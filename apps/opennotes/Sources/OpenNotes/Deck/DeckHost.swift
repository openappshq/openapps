import AppKit
import OpenNotesCore

/// Which displays host a deck, from the Display setting and the screens,
/// and one controller per host. Follows display changes, the settings and
/// the notes; on "the display with the pointer" the deck moves to the
/// display whose edge strip the pointer reaches (`EdgeSentinel`: a
/// transparent strip with a tracking area on every other display, no
/// timer, no monitor), and never while a note is open.
final class DeckHost {
    private let model: AppModel
    private let preferences: Preferences
    private let showAllNotes: () -> Void
    private(set) var controllers: [CGDirectDisplayID: DeckPanelController] = [:]
    private(set) var sentinels: [CGDirectDisplayID: EdgeSentinel] = [:]
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel, preferences: Preferences, showAllNotes: @escaping () -> Void) {
        self.model = model
        self.preferences = preferences
        self.showAllNotes = showAllNotes
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        observeChanges({ [preferences] in _ = preferences.side; _ = preferences.display }, onChange: { [weak self] in self?.settingsChanged() })
        // The default font or size changed: every note without its own
        // re-renders in it.
        observeChanges({ [preferences] in _ = preferences.face; _ = preferences.font; _ = preferences.size }, onChange: { [weak self] in self?.notesChanged() })
        // "Keep notes out of screen sharing": every deck's window follows.
        // Turned off, a deck once hidden cannot be shown again (macOS never
        // raises a window's sharing type, `ScreenSharing`): that deck is
        // torn down — its open note saved and slid back — and made anew.
        observeChanges({ [preferences] in _ = preferences.hideFromScreenSharing }, onChange: { [weak self] in
            guard let self else { return }
            var replaced = false
            for (id, controller) in self.controllers where !controller.applyScreenSharing() {
                controller.tearDown()
                self.controllers[id] = nil
                replaced = true
            }
            if replaced { self.rebuild() }
        })
        observeChanges({ [model] in _ = model.revision }, onChange: { [weak self] in self?.notesChanged() })
        model.onRedirect = { [weak self] from, to in
            guard let self else { return }
            for controller in self.controllers.values { controller.noteRedirected(from: from, to: to) }
        }
        // The license published a change: the machines take the new
        // read-only flag (the hotkey and `+` ask it again at the click
        // regardless) and the decks re-render the lock, the pill and the
        // footer's line.
        observeChanges({ [model] in _ = model.readOnly }, onChange: { [weak self] in
            guard let self else { return }
            for controller in self.controllers.values { controller.settingsChanged() }
        })
        rebuild()
    }

    deinit {
        MainActor.assumeIsolated {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            for sentinel in sentinels.values { sentinel.tearDown() }
        }
    }

    /// The display names hosting a deck, for diagnostics.
    var hostedDisplayNames: [String] {
        controllers.keys.sorted().compactMap { ScreenCatalog.screen(for: $0)?.localizedName }
    }

    var stateDescription: String {
        controllers.values.map { controller in
            switch controller.state {
            case .pill: "pill"
            case .fan: "fan"
            case .open(let id, let editing): "open \(id.rawValue)\(editing ? " (editing)" : "")"
            }
        }.joined(separator: ", ")
    }

    /// The hotkey: a new note on the deck the pointer is on, else the first.
    func hotkey() {
        primaryController?.handle(.hotkey)
    }

    /// All Notes' Open, and the menu.
    func open(_ id: NoteID) {
        primaryController?.handle(.openRequested(id))
    }

    func closeAll() {
        for controller in controllers.values where controller.isOpen { controller.handle(.clickedOutside) }
    }

    /// Saves every open note (quit, folder change).
    func saveAll() {
        for controller in controllers.values where controller.isOpen { controller.handle(.escape) }
    }

    private var primaryController: DeckPanelController? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }), let id = ScreenCatalog.displayID(of: screen), let controller = controllers[id] {
            return controller
        }
        return controllers.sorted { $0.key < $1.key }.first?.value
    }

    /// Re-reads the screens; keeps controllers whose display is still a
    /// host, tears down the others (saving an open note), makes new ones.
    func rebuild() {
        let hosts = Self.hosts(for: preferences.display, screens: NSScreen.screens)
        for (id, controller) in controllers where hosts[id] == nil {
            controller.tearDown()
            controllers[id] = nil
        }
        for (id, screen) in hosts {
            if let existing = controllers[id] {
                existing.update(screen: screen)
            } else {
                controllers[id] = DeckPanelController(displayID: id, screen: screen, model: model, preferences: preferences, showAllNotes: showAllNotes)
            }
        }
        rebuildSentinels(hosts: hosts)
    }

    /// "The display with the pointer": every display without a deck gets
    /// a sentinel strip on the deck's edge; the pointer reaching it moves
    /// the deck there. Nothing on the other settings.
    private func rebuildSentinels(hosts: [CGDirectDisplayID: NSScreen]) {
        let wanted: [CGDirectDisplayID: NSScreen]
        if preferences.display == .pointer {
            wanted = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let id = ScreenCatalog.displayID(of: screen), hosts[id] == nil else { return nil }
                return (id, screen)
            })
        } else {
            wanted = [:]
        }
        for (id, sentinel) in sentinels where wanted[id] == nil {
            sentinel.tearDown()
            sentinels[id] = nil
        }
        for (id, screen) in wanted {
            if let existing = sentinels[id] {
                existing.update(screen: screen, side: preferences.side)
            } else {
                let sentinel = EdgeSentinel(screen: screen, side: preferences.side)
                sentinel.onEnter = { [weak self] in self?.pointerReached(id) }
                sentinels[id] = sentinel
            }
        }
    }

    /// The screens to host on: the main one, the pointer's, or every one.
    static func hosts(for display: DeckDisplay, screens: [NSScreen], pointer: CGPoint = NSEvent.mouseLocation) -> [CGDirectDisplayID: NSScreen] {
        var result: [CGDirectDisplayID: NSScreen] = [:]
        switch display {
        case .main:
            if let screen = screens.first, let id = ScreenCatalog.displayID(of: screen) { result[id] = screen }
        case .pointer:
            let screen = screens.first { $0.frame.contains(pointer) } ?? screens.first
            if let screen, let id = ScreenCatalog.displayID(of: screen) { result[id] = screen }
        case .every:
            for screen in screens {
                if let id = ScreenCatalog.displayID(of: screen) { result[id] = screen }
            }
        }
        return result
    }

    /// The pointer reached another display's edge: the deck moves there,
    /// unless a note is open (it stays where it is being written).
    private func pointerReached(_ id: CGDirectDisplayID) {
        guard preferences.display == .pointer, controllers[id] == nil else { return }
        guard !controllers.values.contains(where: \.isOpen) else { return }
        guard let screen = ScreenCatalog.screen(for: id) else { return }
        for (old, controller) in controllers {
            controller.tearDown()
            controllers[old] = nil
        }
        controllers[id] = DeckPanelController(displayID: id, screen: screen, model: model, preferences: preferences, showAllNotes: showAllNotes)
        rebuildSentinels(hosts: [id: screen])
        // The pointer is already on the edge: the new deck should know.
        controllers[id]?.handle(.pointerEnteredEdge)
    }

    private func settingsChanged() {
        rebuild()
        for controller in controllers.values { controller.settingsChanged() }
    }

    private func notesChanged() {
        for controller in controllers.values { controller.notesChanged() }
    }
}

/// A transparent strip on one display's deck edge, the pill's width, that
/// only reports the pointer entering it. It takes no clicks, no focus and
/// no timer; it exists so "the display with the pointer" needs no polling.
final class EdgeSentinel {
    private let panel: NSPanel
    private let zone: SentinelView
    var onEnter: () -> Void = {} {
        didSet { zone.onEnter = onEnter }
    }

    init(screen: NSScreen, side: DeckSide) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = DeckPanelController.level
        panel.collectionBehavior = DeckPanelController.collectionBehavior
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        zone = SentinelView(frame: .zero)
        panel.contentView = zone
        update(screen: screen, side: side)
        panel.orderFrontRegardless()
    }

    func update(screen: NSScreen, side: DeckSide) {
        let width = DeckMetrics().pillWidth
        let frame = screen.visibleFrame
        let x = side == .right ? frame.maxX - width : frame.minX
        panel.setFrame(CGRect(x: x, y: frame.minY, width: width, height: frame.height), display: false)
    }

    func tearDown() {
        panel.orderOut(nil)
    }
}

/// The sentinel's view: a tracking area, nothing else.
final class SentinelView: NSView {
    var onEnter: () -> Void = {}
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override var acceptsFirstResponder: Bool { false }
    /// Clicks on the strip go to what is under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What `NSScreen` says about the displays.
enum ScreenCatalog {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == display }
    }
}
