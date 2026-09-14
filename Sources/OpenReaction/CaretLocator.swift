import AppKit
import ApplicationServices
import OpenReactionCore

/// What the Accessibility API reports about the focused element.
enum FocusInfo: Equatable, Sendable {
    /// A password field. Nothing may be observed or inserted.
    case secure
    /// Editable text whose caret bounds are known (Quartz coordinates).
    case caret(CGRect)
    /// Editable text without caret bounds; the element's frame (Quartz coordinates).
    case element(CGRect)
    /// A non-secure focused element with no usable geometry.
    case noGeometry
    /// No focused element, or the check could not complete (timeout, no
    /// Accessibility access). Unsafe: the field might be secure.
    case unavailable
}

/// Queries the focused element off the main thread.
///
/// Accessibility calls are synchronous IPC into the target app. A busy or hung
/// app can stall them for seconds, so they run on a private queue with a short
/// messaging timeout, and the main thread only ever awaits the result.
final class CaretLocator: Sendable {
    private let queue = DispatchQueue(label: "com.openappshq.openreaction.accessibility", qos: .userInitiated)
    private static let messagingTimeout: Float = 0.15
    /// Elements taller than this are text areas or web views; their frame says little about the caret.
    private static let maxElementAnchorHeight: CGFloat = 80

    func focusInfo() async -> FocusInfo {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.queryFocusedElement())
            }
        }
    }

    private static func queryFocusedElement() -> FocusInfo {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        guard let focused = element(systemWide, kAXFocusedUIElementAttribute) else {
            return .unavailable
        }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        // The secure-field check must complete, not merely fail to say "secure".
        switch secureFieldCheck(focused) {
        case .some(true): return .secure
        case .none: return .unavailable
        case .some(false): break
        }
        if let caret = caretBounds(focused) {
            return .caret(caret)
        }
        if let frame = frame(focused), frame.height > 0, frame.height <= maxElementAnchorHeight {
            return .element(frame)
        }
        return .noGeometry
    }

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

    private static func caretBounds(_ element: AXUIElement) -> CGRect? {
        guard let selection = value(element, kAXSelectedTextRangeAttribute),
              AXValueGetType(selection) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection, .cfRange, &range), range.location >= 0 else { return nil }

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

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &result
        ) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let axValue = result as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
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

    // MARK: - Attribute helpers

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

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }
}
