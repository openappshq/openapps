/// Chromium and Electron apps (Chrome, Aside, VS Code, Electron chat apps)
/// expose no text tree through Accessibility until an assistive client asks
/// for it. Setting `AXEnhancedUserInterface` (Chromium) and
/// `AXManualAccessibility` (Electron) on the app element turns the tree on, so
/// the focused editable and its selection become readable and the verified
/// insertion path can work.
///
/// The actual attribute writes are a live Accessibility call, kept behind this
/// seam so the decision logic — once per pid per launch, never for excluded
/// apps — is pure and testable without touching a real process.
public protocol AccessibilityTreeEnabling: Sendable {
    /// Turn on the app's accessibility tree. Called on a worker queue with a
    /// bounded messaging timeout; failures are ignored.
    func enableTree(pid: Int32)
}

/// Decides when the frontmost app's accessibility tree should be enabled: once
/// per pid for the life of the launch, and never for excluded apps. The flags
/// are harmless and other assistive apps set them too, so nothing is restored
/// when the app is no longer frontmost.
public struct AccessibilityActivation: Sendable {
    private var enabled: Set<Int32> = []

    public init() {}

    /// Returns true the first time a non-excluded pid is seen, and marks it so
    /// the tree is enabled only once per pid per launch. An excluded app never
    /// returns true; if it is later un-excluded and re-activates, the still
    /// unseen pid enables then.
    public mutating func shouldEnable(pid: Int32, excluded: Bool) -> Bool {
        guard !excluded else { return false }
        return enabled.insert(pid).inserted
    }
}
