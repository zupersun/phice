import Foundation
import Testing

@Test func bundleIdentifierNeverChanges() {
    // macOS keys the Accessibility grant to this identifier; see CLAUDE.md constraint 3.
    #expect(Bundle.main.bundleIdentifier == "com.phice.app")
}
