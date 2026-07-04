import AppKit
import FabCore
import ScreenReader
import Testing

/// Real Accessibility walk against TextEdit. Requires:
/// - FAB_REAL_AX=1 in the environment
/// - Accessibility permission for the test runner process
/// Run: FAB_REAL_AX=1 swift test --filter RealAXReaderTests
@Suite struct RealAXReaderTests {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["FAB_REAL_AX"] == "1"
    }

    @Test(.enabled(if: enabled))
    func readsTermsFromTextEditDocument() async throws {
        let marker = "ZyxwvutMarker QuuxFrobnicate42"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("fab-ax-test-\(UUID().uuidString).txt")
        try marker.data(using: .utf8)!.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let textEdit = try await NSWorkspace.shared.open(
            [file],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
        defer { textEdit.terminate() }
        try await Task.sleep(for: .seconds(2)) // let the document window appear

        let context = await ScreenContextReader().read(pid: textEdit.processIdentifier)
        #expect(context.terms.contains("ZyxwvutMarker"))
        #expect(context.terms.contains("QuuxFrobnicate42"))
    }
}
