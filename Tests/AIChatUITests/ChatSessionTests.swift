import XCTest
@testable import AIChatUI
import AIChatCore

@MainActor
final class ChatSessionTests: XCTestCase {

    private func makeSession(events: [ChatStreamEvent]) -> ChatSession {
        let provider = MockChatProvider(events: events)
        return ChatSession(provider: provider, model: "test-model")
    }

    // MARK: - Initial state

    func test_initialState_isEmpty() {
        let session = makeSession(events: [])
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertFalse(session.isGenerating)
        XCTAssertNil(session.error)
    }

    // MARK: - Sending messages

    func test_send_addsUserEntry() async {
        let session = makeSession(events: [])
        session.send("Hello")
        let userEntries = session.entries.filter { if case .userMessage = $0 { return true } else { return false } }
        XCTAssertEqual(userEntries.count, 1)
    }

    func test_send_emptyString_doesNothing() {
        let session = makeSession(events: [])
        session.send("   ")
        XCTAssertTrue(session.entries.isEmpty)
    }

    func test_send_setsIsGeneratingTrue() {
        let session = makeSession(events: [])
        session.send("Hello")
        XCTAssertTrue(session.isGenerating)
    }

    // MARK: - Text streaming

    func test_textEvents_createAIEntry() async throws {
        let session = makeSession(events: [.text("Hello"), .text(" world")])
        session.send("Hi")
        try await waitForGeneration(session)
        let aiEntries = session.entries.compactMap { entry -> ChatSession.AIEntry? in
            if case .aiMessage(let e) = entry { return e } else { return nil }
        }
        XCTAssertEqual(aiEntries.count, 1)
        XCTAssertEqual(aiEntries[0].text, "Hello world")
    }

    // MARK: - Reasoning streaming

    func test_reasoningEvents_createReasoningEntry() async throws {
        let session = makeSession(events: [.reasoning("thinking..."), .text("Answer")])
        session.send("Question")
        try await waitForGeneration(session)
        let reasoningEntries = session.entries.filter { if case .reasoning = $0 { return true } else { return false } }
        XCTAssertEqual(reasoningEntries.count, 1)
    }

    func test_reasoningEntry_appearsBeforeAIEntry() async throws {
        let session = makeSession(events: [.reasoning("hmm"), .text("yes")])
        session.send("Q")
        try await waitForGeneration(session)
        let indices = session.entries.enumerated().compactMap { (i, e) -> (Int, String)? in
            switch e {
            case .reasoning: return (i, "reasoning")
            case .aiMessage: return (i, "ai")
            default: return nil
            }
        }
        if let reasoningIdx = indices.first(where: { $0.1 == "reasoning" })?.0,
           let aiIdx = indices.first(where: { $0.1 == "ai" })?.0 {
            XCTAssertLessThan(reasoningIdx, aiIdx)
        } else {
            XCTFail("Expected both reasoning and AI entries")
        }
    }

    // MARK: - Tool calls

    func test_toolCallComplete_createsToolEntry() async throws {
        let session = makeSession(events: [.toolCallComplete(id: "c1", name: "search", arguments: "{}")])
        session.send("search for x")
        try await waitForGeneration(session)
        let toolEntries = session.entries.filter { if case .toolCall = $0 { return true } else { return false } }
        XCTAssertEqual(toolEntries.count, 1)
    }

    // MARK: - isGenerating lifecycle

    func test_isGenerating_falseAfterCompletion() async throws {
        let session = makeSession(events: [.text("Done")])
        session.send("Go")
        try await waitForGeneration(session)
        XCTAssertFalse(session.isGenerating)
    }

    // MARK: - Toggle thinking

    func test_toggleThinking_flipsIsExpanded() async throws {
        let session = makeSession(events: [.reasoning("thought"), .text("answer")])
        session.send("Q")
        try await waitForGeneration(session)

        if case .reasoning(let entry) = session.entries.first(where: { if case .reasoning = $0 { return true } else { return false } }) {
            XCTAssertFalse(entry.isExpanded)
            session.toggleThinking(id: entry.id)
            if case .reasoning(let updated) = session.entries.first(where: { if case .reasoning = $0 { return true } else { return false } }) {
                XCTAssertTrue(updated.isExpanded)
            }
        } else {
            XCTFail("No reasoning entry found")
        }
    }

    // MARK: - Error handling

    func test_errorFromProvider_setsSessionError() async throws {
        let provider = ErrorMockProvider(error: ChatError.serverError(statusCode: 401, message: "invalid x-api-key"))
        let session = ChatSession(provider: provider, model: "test")
        session.send("Hello")
        try await waitForGeneration(session)
        XCTAssertNotNil(session.error)
        XCTAssertTrue(session.error?.localizedDescription.contains("401") == true)
    }

    func test_errorFromProvider_noAIEntry() async throws {
        let provider = ErrorMockProvider(error: ChatError.serverError(statusCode: 500, message: "oops"))
        let session = ChatSession(provider: provider, model: "test")
        session.send("Hello")
        try await waitForGeneration(session)
        let aiEntries = session.entries.filter { if case .aiMessage = $0 { return true } else { return false } }
        XCTAssertTrue(aiEntries.isEmpty)
    }

    func test_errorFromProvider_showsInlineErrorEntry() async throws {
        let provider = ErrorMockProvider(error: ChatError.networkError(URLError(.notConnectedToInternet)))
        let session = ChatSession(provider: provider, model: "test")
        session.send("Hello")
        try await waitForGeneration(session)
        // On error with no AI response, a single inline error activity entry is shown
        let activityEntries = session.entries.filter { if case .activity = $0 { return true } else { return false } }
        XCTAssertEqual(activityEntries.count, 1)
        if case .activity(let e) = activityEntries.first {
            XCTAssertTrue(e.text.contains("⚠️"))
        }
    }

    func test_errorFromProvider_isGeneratingFalse() async throws {
        let provider = ErrorMockProvider(error: ChatError.serverError(statusCode: 503, message: "unavailable"))
        let session = ChatSession(provider: provider, model: "test")
        session.send("Hello")
        try await waitForGeneration(session)
        XCTAssertFalse(session.isGenerating)
    }

    // MARK: - Cancel

    func test_cancel_setsIsGeneratingFalse() async throws {
        let provider = SlowMockProvider()
        let session = ChatSession(provider: provider, model: "test")
        session.send("Hello")
        try await Task.sleep(for: .milliseconds(20))
        session.cancel()
        try await waitForGeneration(session)
        XCTAssertFalse(session.isGenerating)
    }

    func test_cancel_doesNotSetError() async throws {
        let provider = SlowMockProvider()
        let session = ChatSession(provider: provider, model: "test")
        session.send("Hello")
        try await Task.sleep(for: .milliseconds(20))
        session.cancel()
        try await waitForGeneration(session)
        XCTAssertNil(session.error)
    }

    // MARK: - Clear history

    func test_clearHistory_removesAllEntries() async throws {
        let session = makeSession(events: [.text("Hello")])
        session.send("Hi")
        try await waitForGeneration(session)
        XCTAssertFalse(session.entries.isEmpty)
        session.clearHistory()
        XCTAssertTrue(session.entries.isEmpty)
    }

    func test_clearHistory_allowsSendAgain() async throws {
        let session = makeSession(events: [.text("A"), .text("B")])
        session.send("first")
        try await waitForGeneration(session)
        session.clearHistory()
        session.send("second")
        try await waitForGeneration(session)
        let userEntries = session.entries.filter { if case .userMessage = $0 { return true } else { return false } }
        XCTAssertEqual(userEntries.count, 1)
    }

    // MARK: - Guard conditions

    func test_send_whileGenerating_isIgnored() async {
        let provider = SlowMockProvider()
        let session = ChatSession(provider: provider, model: "test")
        session.send("first")
        XCTAssertTrue(session.isGenerating)
        session.send("second")
        let userEntries = session.entries.filter { if case .userMessage = $0 { return true } else { return false } }
        XCTAssertEqual(userEntries.count, 1, "Second send should be ignored while generating")
        session.cancel()
    }

    func test_emptyStream_noAIEntry() async throws {
        let session = makeSession(events: [])
        session.send("Hi")
        try await waitForGeneration(session)
        let aiEntries = session.entries.filter { if case .aiMessage = $0 { return true } else { return false } }
        XCTAssertTrue(aiEntries.isEmpty)
    }

    // MARK: - Usage event

    func test_usageEvent_doesNotCreateActivity() async throws {
        let usage = TokenUsage(promptTokens: 10, completionTokens: 20, totalTokens: 30)
        let session = makeSession(events: [.text("Hi"), .usage(usage)])
        session.send("Hello")
        try await waitForGeneration(session)
        let activityEntries = session.entries.filter { if case .activity = $0 { return true } else { return false } }
        XCTAssertTrue(activityEntries.isEmpty)
    }

    // MARK: - Helpers

    private func waitForGeneration(_ session: ChatSession, timeout: Double = 3.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while session.isGenerating && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(session.isGenerating, "Generation did not complete within \(timeout)s")
    }
}

// MARK: - Mock Providers

final class MockChatProvider: ChatProvider {
    let id = "mock"
    let name = "Mock"
    let events: [ChatStreamEvent]

    init(events: [ChatStreamEvent]) {
        self.events = events
    }

    func stream(messages: [ChatMessage], model: String, options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let events = self.events
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    try? await Task.sleep(for: .milliseconds(5))
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func complete(messages: [ChatMessage], model: String, options: ChatRequestOptions) async throws -> ChatCompletionResult {
        ChatCompletionResult(
            id: "mock-id",
            model: model,
            message: ChatMessage(role: .assistant, content: "Mock response"),
            usage: nil,
            finishReason: .stop
        )
    }
}

/// Provider that immediately throws a given error.
final class ErrorMockProvider: ChatProvider {
    let id = "error-mock"
    let name = "Error Mock"
    let error: Error

    init(error: Error) { self.error = error }

    func stream(messages: [ChatMessage], model: String, options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let error = self.error
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    func complete(messages: [ChatMessage], model: String, options: ChatRequestOptions) async throws -> ChatCompletionResult {
        throw error
    }
}

/// Provider that yields a single text event after a delay — lets tests cancel mid-stream.
final class SlowMockProvider: ChatProvider {
    let id = "slow-mock"
    let name = "Slow Mock"

    func stream(messages: [ChatMessage], model: String, options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.yield(.text("slow response"))
                continuation.finish()
            }
        }
    }

    func complete(messages: [ChatMessage], model: String, options: ChatRequestOptions) async throws -> ChatCompletionResult {
        try await Task.sleep(for: .milliseconds(500))
        return ChatCompletionResult(id: nil, model: "slow", message: ChatMessage(role: .assistant, content: "slow"), usage: nil, finishReason: .stop)
    }
}
