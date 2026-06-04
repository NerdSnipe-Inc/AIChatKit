import XCTest
@testable import AIChatAnthropic
import AIChatCore

final class AnthropicStreamProcessorTests: XCTestCase {

    private func process(sseEvents: [(type: String, data: String)]) async throws -> [ChatStreamEvent] {
        let lines = sseEvents.flatMap { e -> [String] in
            ["event: \(e.type)", "data: \(e.data)", ""]
        }
        let lineStream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        let events = SSEParser.events(from: lineStream)
        return try await collectEvents(AnthropicStreamProcessor.process(events: events))
    }

    // MARK: - Text

    func test_textDelta_emitsTextEvent() async throws {
        let events = try await process(sseEvents: [
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#),
            ("content_block_stop",  #"{"type":"content_block_stop","index":0}"#),
            ("message_stop",        #"{"type":"message_stop"}"#),
        ])
        XCTAssertTrue(events.contains(.text("Hello")))
    }

    // MARK: - Thinking

    func test_thinkingDelta_emitsReasoningEvent() async throws {
        let events = try await process(sseEvents: [
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"I should"}}"#),
            ("content_block_stop",  #"{"type":"content_block_stop","index":0}"#),
        ])
        XCTAssertTrue(events.contains(.reasoning("I should")))
    }

    func test_thinkingBlockWithSignature_emitsThinkingBlockComplete() async throws {
        let events = try await process(sseEvents: [
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"deep thought"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_xyz"}}"#),
            ("content_block_stop",  #"{"type":"content_block_stop","index":0}"#),
        ])
        let blockEvent = events.first {
            if case .thinkingBlockComplete = $0 { return true }
            return false
        }
        XCTAssertNotNil(blockEvent)
        if case .thinkingBlockComplete(let thinking, let sig) = blockEvent! {
            XCTAssertEqual(thinking, "deep thought")
            XCTAssertEqual(sig, "sig_xyz")
        }
    }

    func test_redactedThinking_emitsRedactedEvent() async throws {
        let events = try await process(sseEvents: [
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"encrypted_blob"}}"#),
            ("content_block_stop",  #"{"type":"content_block_stop","index":0}"#),
        ])
        let redacted = events.first {
            if case .redactedThinking = $0 { return true }
            return false
        }
        XCTAssertNotNil(redacted)
    }

    // MARK: - Tool calls

    func test_toolUseBlock_emitsToolCallComplete() async throws {
        let events = try await process(sseEvents: [
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"search","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"q\":\"swift\"}"}}"#),
            ("content_block_stop",  #"{"type":"content_block_stop","index":0}"#),
        ])
        let completed = events.compactMap { event -> (String, String, String)? in
            if case .toolCallComplete(let id, let name, let args) = event { return (id, name, args) }
            return nil
        }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].0, "toolu_1")
        XCTAssertEqual(completed[0].1, "search")
        XCTAssertEqual(completed[0].2, #"{"q":"swift"}"#)
    }

    // MARK: - Error handling

    func test_errorEvent_propagates() async throws {
        do {
            _ = try await process(sseEvents: [
                ("error", #"{"type":"error","error":{"type":"overloaded_error","message":"API overloaded"}}"#),
            ])
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("overloaded") || error.localizedDescription.contains("Anthropic"))
        }
    }

    // MARK: - Full conversation flow

    func test_fullTextConversation_emitsTextAndNoExtra() async throws {
        let events = try await process(sseEvents: [
            ("message_start",      #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-6","stop_reason":null,"usage":{"input_tokens":10,"output_tokens":1}}}"#),
            ("content_block_start",#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("ping",               #"{"type":"ping"}"#),
            ("content_block_delta",#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello world"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta",      #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":3}}"#),
            ("message_stop",       #"{"type":"message_stop"}"#),
        ])
        let texts = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(texts, ["Hello world"])
        // No spurious reasoning, tool call, or error events
        XCTAssertFalse(events.contains { if case .reasoning = $0 { return true } else { return false } })
        XCTAssertFalse(events.contains { if case .toolCallComplete = $0 { return true } else { return false } })
    }

    func test_pingEvent_producesNoOutput() async throws {
        let events = try await process(sseEvents: [
            ("ping", #"{"type":"ping"}"#),
        ])
        XCTAssertTrue(events.isEmpty)
    }

    func test_messageStartEvent_producesNoOutput() async throws {
        let events = try await process(sseEvents: [
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"m","stop_reason":null,"usage":{"input_tokens":5,"output_tokens":1}}}"#),
        ])
        XCTAssertTrue(events.isEmpty)
    }

    func test_multipleTextDeltas_concatenateInOrder() async throws {
        let events = try await process(sseEvents: [
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"foo"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"bar"}}"#),
            ("content_block_stop",  #"{"type":"content_block_stop","index":0}"#),
        ])
        let texts = events.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
        XCTAssertEqual(texts, ["foo", "bar"])
    }

    func test_emptyTextDelta_notEmitted() async throws {
        let events = try await process(sseEvents: [
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}"#),
            ("content_block_stop",  #"{"type":"content_block_stop","index":0}"#),
        ])
        XCTAssertTrue(events.filter { if case .text = $0 { return true } else { return false } }.isEmpty)
    }

    // MARK: - Helpers

    private func collectEvents(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
