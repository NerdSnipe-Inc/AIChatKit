import XCTest
import SwiftUI
import AIChatCore
@testable import AIChatUI

final class UserMessageRowTests: XCTestCase {

    private func entry(_ text: String = "hello", cancelled: Bool = false) -> ChatSession.UserEntry {
        var e = ChatSession.UserEntry(id: UUID(), text: text)
        e.isCancelled = cancelled
        return e
    }

    func test_normalMessage_hasNoCaption_fullOpacity_plainLabel() {
        let e = entry()
        XCTAssertNil(UserMessagePresentation.caption(for: e))
        XCTAssertEqual(UserMessagePresentation.bubbleOpacity(for: e), 1)
        XCTAssertEqual(UserMessagePresentation.accessibilityLabel(for: e), "hello")
    }

    func test_cancelledMessage_isCaptioned_dimmed_andSpokenAsCancelled() {
        let e = entry("hello", cancelled: true)
        XCTAssertEqual(UserMessagePresentation.caption(for: e), UserMessagePresentation.cancelledCaption)
        XCTAssertLessThan(UserMessagePresentation.bubbleOpacity(for: e), 1)
        XCTAssertTrue(UserMessagePresentation.accessibilityLabel(for: e).contains("Cancelled"),
                      "the cancelled state must not rely on dimming alone")
        XCTAssertTrue(UserMessagePresentation.accessibilityLabel(for: e).hasPrefix("hello"))
    }

    /// The caption is real content, not just a modifier: the cancelled row must render taller.
    @MainActor
    func test_cancelledRowRendersTallerThanNormalRow() {
        func height(_ e: ChatSession.UserEntry) -> CGFloat {
            NSHostingView(rootView: UserMessageRow(entry: e).frame(width: 360)).fittingSize.height
        }
        XCTAssertGreaterThan(height(entry(cancelled: true)), height(entry(cancelled: false)))
    }

    /// End to end through the session: a cancel before any output marks the transcript entry, so the
    /// row above is what the user sees.
    @MainActor
    func test_sessionMarksCancelledEntry_thatRowsRenderAsCancelled() async {
        let provider = HangingProvider()
        let session = ChatSession(provider: provider, model: "m")
        XCTAssertTrue(session.send("first"))
        await Task.yield()
        session.cancel()
        let users = session.entries.compactMap { entry -> ChatSession.UserEntry? in
            if case .userMessage(let e) = entry { return e } else { return nil }
        }
        XCTAssertEqual(users.count, 1)
        XCTAssertTrue(users[0].isCancelled)
        XCTAssertNotNil(UserMessagePresentation.caption(for: users[0]))
    }
}

/// Never yields an event, so `cancel()` always lands before any output.
private struct HangingProvider: ChatProvider {
    let id = "hang"
    let name = "Hang"
    func stream(messages: [ChatMessage], model: String, options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func complete(messages: [ChatMessage], model: String, options: ChatRequestOptions) async throws -> ChatCompletionResult {
        throw ChatError.cancelled
    }
}
