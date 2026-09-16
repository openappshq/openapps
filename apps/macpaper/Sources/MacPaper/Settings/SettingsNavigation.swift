import Observation

/// A request to bring one part of the settings form into view: the trial
/// pill, the panel's license card and the setup guide all land on
/// Settings → License through it.
@Observable
final class SettingsNavigation {
    enum Anchor: Hashable {
        case license
    }

    /// Incremented per request, so asking for the same anchor twice scrolls twice.
    private(set) var request = 0
    private(set) var anchor: Anchor?
    /// The request came from "Enter a key": the key field takes focus.
    private(set) var wantsKeyField = false

    func reveal(_ anchor: Anchor, keyField: Bool = false) {
        self.anchor = anchor
        wantsKeyField = keyField
        request += 1
    }
}
