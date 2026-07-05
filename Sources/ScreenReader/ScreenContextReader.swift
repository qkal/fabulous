import ApplicationServices
import FabCore
import Foundation

/// Live AX implementation. The entire walk stays inside `read` on one
/// task — AXUIElement is not Sendable and must never escape. The AX
/// calls are synchronous and may block this cooperative thread for up
/// to the walk time-box (~1 s worst case, bounded by per-element
/// messaging timeouts); that is accepted — the walk overlaps recording,
/// nothing awaits it on the hot path.
public struct ScreenContextReader: ScreenContextReading {
    /// Whole-walk budget. Checked between nodes via `shouldContinue`.
    private static let walkBudget: Duration = .seconds(1)
    /// Per-element AX messaging timeout — a hung app costs ≤100 ms per
    /// attribute fetch instead of the 6 s system default. The timeout is
    /// NOT inherited: it applies only to the element it was set on, so
    /// `LiveAXNode` re-applies it to every element it wraps (window and
    /// each child) — setting it is a cheap local call, no IPC.
    static let messagingTimeout: Float = 0.1

    public init() {}

    public func read(pid: pid_t) async -> ScreenContext {
        let capturedAt = Date()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)

        guard let window = Self.focusedWindow(of: app) else {
            return ScreenContext(windowTitle: nil, terms: [], capturedAt: capturedAt)
        }
        let root = LiveAXNode(element: window)
        let deadline = ContinuousClock.now.advanced(by: Self.walkBudget)
        let pieces = TextHarvester.harvest(root) {
            !Task.isCancelled && ContinuousClock.now < deadline
        }
        return ScreenContext(
            windowTitle: root.title,
            terms: SalientTermExtractor.terms(from: pieces),
            capturedAt: capturedAt
        )
    }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: AnyObject?
            let err = AXUIElementCopyAttributeValue(app, attribute as CFString, &value)
            if err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }
}

/// AXUIElement wrapped as a TextHarvestNode. Deliberately NOT Sendable;
/// stays internal to this module and never crosses an isolation boundary.
struct LiveAXNode: TextHarvestNode {
    let element: AXUIElement

    /// Messaging timeouts are per-element (not inherited from the app
    /// handle), so every wrapped element gets the short timeout or its
    /// attribute fetches would fall back to the 6 s system default.
    init(element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, ScreenContextReader.messagingTimeout)
        self.element = element
    }

    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String? { string(kAXTitleAttribute) }

    /// Prefer the visible portion of large text areas (a log view can
    /// hold megabytes off-screen); fall back to the full value, which
    /// the harvester caps.
    var textValue: String? { visibleText() ?? string(kAXValueAttribute) }

    var children: [LiveAXNode] {
        guard let value = copy(kAXChildrenAttribute),
              CFGetTypeID(value) == CFArrayGetTypeID()
        else { return [] }
        return ((value as! [AnyObject]).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID()
                ? LiveAXNode(element: (item as! AXUIElement))
                : nil
        })
    }

    private func copy(_ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    private func string(_ attribute: String) -> String? {
        copy(attribute) as? String
    }

    private func visibleText() -> String? {
        guard let rangeObject = copy(kAXVisibleCharacterRangeAttribute),
              CFGetTypeID(rangeObject) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue((rangeObject as! AXValue), .cfRange, &range),
              range.length > 0,
              let axRange = AXValueCreate(.cfRange, &range)
        else { return nil }
        var out: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &out
        )
        return err == .success ? out as? String : nil
    }
}
