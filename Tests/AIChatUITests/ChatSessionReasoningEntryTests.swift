import XCTest
@testable import AIChatUI

final class ChatSessionReasoningEntryTests: XCTestCase {
    func test_reasoningEntry_hasPublicInitializer() {
        let entry = ChatSession.ReasoningEntry(
            id: UUID(), text: "thinking about it", duration: 2.5,
            isExpanded: false, isThinking: true, thinkingSignature: nil
        )
        XCTAssertEqual(entry.text, "thinking about it")
        XCTAssertEqual(entry.duration, 2.5)
        XCTAssertTrue(entry.isThinking)
    }
}
