import XCTest
@testable import AIChatOpenAI
import AIChatCore

final class OpenAIStreamProcessorTests: XCTestCase {

    private func process(jsonLines: [String]) async throws -> [ChatStreamEvent] {
        let sseLines = jsonLines.flatMap { json -> [String] in
            if json == "[DONE]" { return ["data: [DONE]", ""] }
            return ["data: \(json)", ""]
        }
        let events = SSEParser.events(from: makeLineStream(sseLines))
        return try await collectEvents(OpenAIStreamProcessor.process(events: events))
    }

    // MARK: - Text

    func test_textDelta_emitsTextEvent() async throws {
        let json = #"{"choices":[{"delta":{"content":"hello"},"finish_reason":null,"index":0}]}"#
        let events = try await process(jsonLines: [json, "[DONE]"])
        XCTAssertEqual(events.first, .text("hello"))
    }

    func test_multipleTextDeltas_emitInOrder() async throws {
        let a = #"{"choices":[{"delta":{"content":"foo"},"finish_reason":null,"index":0}]}"#
        let b = #"{"choices":[{"delta":{"content":"bar"},"finish_reason":null,"index":0}]}"#
        let events = try await process(jsonLines: [a, b, "[DONE]"])
        let texts = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(texts, ["foo", "bar"])
    }

    // MARK: - Reasoning

    func test_reasoningContentDelta_emitsReasoningEvent() async throws {
        let json = #"{"choices":[{"delta":{"reasoning_content":"thinking..."},"finish_reason":null,"index":0}]}"#
        let events = try await process(jsonLines: [json, "[DONE]"])
        XCTAssertEqual(events.first, .reasoning("thinking..."))
    }

    // MARK: - Tool calls

    func test_toolCallDelta_accumulatesAndEmitsComplete() async throws {
        let chunks = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null,"index":0}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\""}}]},"finish_reason":null,"index":0}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"SF\"}"}}]},"finish_reason":"tool_calls","index":0}]}"#,
            "[DONE]",
        ]
        let events = try await process(jsonLines: chunks)
        let completed = events.compactMap { event -> (id: String, name: String, args: String)? in
            if case .toolCallComplete(let id, let name, let args) = event { return (id, name, args) }
            return nil
        }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].id, "call_1")
        XCTAssertEqual(completed[0].name, "get_weather")
        XCTAssertEqual(completed[0].args, #"{"city":"SF"}"#)
    }

    func test_multipleToolCalls_bothEmitted() async throws {
        let chunks = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"fn1","arguments":"{}"}}]},"finish_reason":null,"index":0}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c2","type":"function","function":{"name":"fn2","arguments":"{}"}}]},"finish_reason":"tool_calls","index":0}]}"#,
            "[DONE]",
        ]
        let events = try await process(jsonLines: chunks)
        let completed = events.filter { if case .toolCallComplete = $0 { return true } else { return false } }
        XCTAssertEqual(completed.count, 2)
    }

    // MARK: - Termination

    func test_doneEvent_streamsFinishes() async throws {
        let events = try await process(jsonLines: ["[DONE]"])
        XCTAssertEqual(events.count, 0)
    }

    // MARK: - Edge cases

    func test_emptyContentDelta_doesNotEmitTextEvent() async throws {
        let json = #"{"choices":[{"delta":{"content":""},"finish_reason":null,"index":0}]}"#
        let events = try await process(jsonLines: [json, "[DONE]"])
        XCTAssertTrue(events.filter { if case .text = $0 { return true } else { return false } }.isEmpty)
    }

    func test_toolCallWithoutFinishReason_stillFlushed() async throws {
        // Some servers omit finish_reason:"tool_calls" — tool calls should still be emitted.
        let chunks = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c99","type":"function","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":null,"index":0}]}"#,
            "[DONE]",
        ]
        let events = try await process(jsonLines: chunks)
        let completed = events.filter { if case .toolCallComplete = $0 { return true } else { return false } }
        XCTAssertEqual(completed.count, 1)
    }

    func test_usageChunk_emitsUsageEvent() async throws {
        let json = #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}"#
        let events = try await process(jsonLines: [json, "[DONE]"])
        let usageEvents = events.compactMap { e -> TokenUsage? in
            if case .usage(let u) = e { return u } else { return nil }
        }
        XCTAssertEqual(usageEvents.count, 1)
        XCTAssertEqual(usageEvents[0].promptTokens, 10)
        XCTAssertEqual(usageEvents[0].completionTokens, 20)
    }

    // MARK: - Helpers

    private func makeLineStream(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    private func collectEvents(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

