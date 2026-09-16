import AppKit
import ApplicationServices
import OpenReactionCore

/// What the Accessibility API reports about the focused element.
enum FocusInfo: Equatable, Sendable {
    /// A password field. Nothing may be observed or inserted.
    case secure
    /// Editable text whose caret bounds are known (Quartz coordinates).
    case caret(CGRect, FocusTarget)
    /// Editable text without caret bounds; the element's frame (Quartz coordinates).
    case element(CGRect, FocusTarget)
    /// A non-secure focused element with no usable geometry.
    case noGeometry(FocusTarget)
    /// No focused element, or the check could not complete (timeout, no
    /// Accessibility access). Unsafe: the field might be secure.
    case unavailable
}

/// Queries the focused element off the main thread.
///
/// Accessibility calls are synchronous IPC into the target app. A busy or hung
/// app can stall them for seconds, so they run on a private queue with a short
/// messaging timeout, and the main thread only ever awaits the result.
///
/// The element behind the last editable answer is kept so a replacement can
/// check, right before deleting, that focus is still there and the typed
/// token is still in front of the caret.
final class CaretLocator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.openappshq.openreaction.accessibility", qos: .userInitiated)
    private static let messagingTimeout: Float = 0.15
    /// Elements taller than this are text areas or web views; their frame says little about the caret.
    private static let maxElementAnchorHeight: CGFloat = 80

    /// Accessed on `queue` only.
    private var elements: [FocusTarget: AXUIElement] = [:]

    func focusInfo() async -> FocusInfo {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.queryFocusedElement())
            }
        }
    }

    /// Confirms `target` still has focus with the typed token right before an
    /// empty caret. Read-only and fail-closed: anything unreadable refuses.
    func verify(_ target: FocusTarget, typed: String, text: String) async -> VerifyResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.verifyTarget(target, typed: typed, text: text))
            }
        }
    }

    // MARK: - Queue

    private func queryFocusedElement() -> FocusInfo {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
        guard let focused = Self.element(systemWide, kAXFocusedUIElementAttribute) else {
            return .unavailable
        }
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)

        // The secure-field check must complete, not merely fail to say "secure".
        switch Self.secureFieldCheck(focused) {
        case .some(true): return .secure
        case .none: return .unavailable
        case .some(false): break
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success else { return .unavailable }
        let target = FocusTarget(pid: pid, element: CFHash(focused))
        elements = [target: focused]

        if let caret = Self.caretBounds(focused) {
            return .caret(caret, target)
        }
        if let frame = Self.frame(focused), frame.height > 0, frame.height <= Self.maxElementAnchorHeight {
            return .element(frame, target)
        }
        return .noGeometry(target)
    }

    /// Read-only verification. The focused element must be the remembered one
    /// (`CFEqual`, same pid) and answer that it is not a secure field; anything
    /// else refuses, since focus may have moved or the field might be secure.
    /// The rest — comparing the selection and the text before the caret against
    /// the typed token — is the pure `CaretVerification.decide` (which returns
    /// `.unverifiable` for the opaque-tree and bogus-`{0,0}` cases so the gate
    /// may fall back to typed replacement). The host is never modified here;
    /// the gate posts key events later, if it may.
    private func verifyTarget(_ target: FocusTarget, typed: String, text: String) -> VerifyResult {
        guard let remembered = elements[target] else { return .refused }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
        guard let focused = Self.element(systemWide, kAXFocusedUIElementAttribute),
              CFEqual(focused, remembered) else { return .refused }
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success, pid == target.pid else { return .refused }
        // A nil answer (the question could not be delivered) also refuses: the
        // field is not confirmed non-secure, so typed replacement is unsafe.
        guard Self.secureFieldCheck(focused) == false else { return .refused }

        let count = typed.utf16.count
        let selection = Self.selectedRange(focused).map { (location: $0.location, length: $0.length) }
        let decision = CaretVerification.decide(typedCount: count, selection: selection, typed: typed) {
            Self.string(focused, CFRange(location: (selection?.location ?? 0) - count, length: count))
        }
        switch decision {
        case .keystrokes: return .keystrokes(text: text)
        case .unverifiable: return .unverifiable(text: text)
        case .refused: return .refused
        }
    }

    // MARK: - Attribute helpers

    /// True/false when the element answered, nil when the question could not
    /// be delivered (timeout, dead app) and the field might be secure.
    private static func secureFieldCheck(_ element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) {
        case .success:
            return (value as? String) == kAXSecureTextFieldSubrole
        case .noValue, .attributeUnsupported:
            return false
        default:
            return nil
        }
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let selection = value(element, kAXSelectedTextRangeAttribute),
              AXValueGetType(selection) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    private static func caretBounds(_ element: AXUIElement) -> CGRect? {
        guard let range = selectedRange(element) else { return nil }

        if let rect = bounds(element, CFRange(location: range.location, length: range.length)),
           PanelPlacement.isPlausibleCaretRect(rect) {
            return rect
        }
        // Many apps return nothing for an empty range; measure the previous
        // character and use its trailing edge instead.
        if range.length == 0, range.location > 0,
           let previous = bounds(element, CFRange(location: range.location - 1, length: 1)),
           PanelPlacement.isPlausibleCaretRect(previous) {
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        return nil
    }

    private static func parameterized(_ element: AXUIElement, _ attribute: String, _ range: CFRange) -> CFTypeRef? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &result) == .success else {
            return nil
        }
        return result
    }

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        guard let result = parameterized(element, kAXBoundsForRangeParameterizedAttribute, range),
              CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let axValue = result as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        parameterized(element, kAXStringForRangeParameterizedAttribute, range) as? String
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = value(element, kAXPositionAttribute),
              let sizeValue = value(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
