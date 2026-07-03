public enum KeystrokeSegment: Equatable, Sendable {
    case text(String)
    case newline
}

/// Splits text for the keystroke strategy: `keyboardSetUnicodeString`
/// can't reliably type Return, so newlines become real key events.
public enum KeystrokeSegmenter {
    public static func segments(of text: String) -> [KeystrokeSegment] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [KeystrokeSegment] = []
        var run = ""
        for character in normalized {
            if character == "\n" {
                if !run.isEmpty {
                    result.append(.text(run))
                    run = ""
                }
                result.append(.newline)
            } else {
                run.append(character)
            }
        }
        if !run.isEmpty {
            result.append(.text(run))
        }
        return result
    }
}
