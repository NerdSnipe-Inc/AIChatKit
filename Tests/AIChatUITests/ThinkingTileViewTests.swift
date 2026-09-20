import XCTest
import SwiftUI
@testable import AIChatUI

final class ThinkingTileViewTests: XCTestCase {
    private func entry(text: String = "abc", duration: TimeInterval = 3.7,
                       expanded: Bool = false, thinking: Bool) -> ChatSession.ReasoningEntry {
        .init(id: UUID(), text: text, duration: duration, isExpanded: expanded, isThinking: thinking)
    }

    func test_pillLabel_streamingVsFinished() {
        XCTAssertEqual(ThinkingTilePresentation.pillLabel(entry(thinking: true)), "Thinking…")
        XCTAssertEqual(ThinkingTilePresentation.pillLabel(entry(thinking: false)), "Thought for 3s")
    }

    func test_contentHiddenWhileThinking_evenIfExpanded() {
        XCTAssertFalse(ThinkingTilePresentation.showsExpandedContent(entry(expanded: true, thinking: true)))
    }

    func test_contentShownOnlyWhenFinishedAndExpanded() {
        XCTAssertTrue(ThinkingTilePresentation.showsExpandedContent(entry(expanded: true, thinking: false)))
        XCTAssertFalse(ThinkingTilePresentation.showsExpandedContent(entry(expanded: false, thinking: false)))
    }

    func test_toggleDisabledWhileThinking() {
        XCTAssertFalse(ThinkingTilePresentation.isToggleEnabled(entry(thinking: true)))
        XCTAssertTrue(ThinkingTilePresentation.isToggleEnabled(entry(thinking: false)))
    }

    func test_previewText_lastFiftyCharsSingleLine() {
        let text = String(repeating: "x", count: 80) + "\nend"
        let preview = ThinkingTilePresentation.previewText(entry(text: text, thinking: false))
        XCTAssertEqual(preview.count, 50)
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertTrue(preview.hasSuffix(" end"))
    }

    @MainActor
    func test_expandedRendersTallerThanCollapsed() {
        func height(_ e: ChatSession.ReasoningEntry) -> CGFloat {
            let host = NSHostingView(rootView: ThinkingTileView(entry: e, onToggle: {}).frame(width: 300))
            return host.fittingSize.height
        }
        let long = String(repeating: "reasoning words ", count: 30)
        let collapsed = height(entry(text: long, expanded: false, thinking: false))
        let expanded = height(entry(text: long, expanded: true, thinking: false))
        let thinkingExpanded = height(entry(text: long, expanded: true, thinking: true))
        XCTAssertGreaterThan(expanded, collapsed)
        XCTAssertEqual(thinkingExpanded, height(entry(text: long, expanded: false, thinking: true)))
    }
}
