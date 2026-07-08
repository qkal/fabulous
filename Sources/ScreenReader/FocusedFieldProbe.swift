import ApplicationServices

/// Best-effort check of whether the system-wide focused UI element is a secure
/// (password) text field. Used to distinguish a real password field from the
/// process-global IsSecureEventInputEnabled() flag (which any app can set).
public enum FocusedFieldProbe {
    @MainActor
    public static func isSecureFieldFocused() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return false }
        // CFGetTypeID above has proven the type; the CF downcast is total
        // (a conditional `as?` here is a compile error — "always succeeds").
        let axElement = unsafeDowncast(element, to: AXUIElement.self)

        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subrole) == .success,
              let value = subrole as? String
        else { return false }
        return value == TextHarvester.secureSubrole
    }
}
