import XCTest
@testable import AIChatUI

// Tests for GemmaOutputRecovery.parse — the inline tool-call extractor.
//
// Every supported format is tested: call:name{...}, <tool_call>JSON</tool_call>,
// and ```tool_code Python blocks. Edge cases like text+toolcall and empty-text
// (the "call text stuck in bubble" bug) are explicit test cases.

final class GemmaOutputRecoveryTests: XCTestCase {

    // MARK: - Inline call:name{...} format

    func test_inlineFormat_parsesName() {
        let r = GemmaOutputRecovery.parse(from: #"call:webSearch{"query":"cats"}"#)
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls[0].name, "webSearch")
    }

    func test_inlineFormat_parsesArguments() {
        let r = GemmaOutputRecovery.parse(from: #"call:webSearch{"query":"NerdSnipe Inc"}"#)
        XCTAssertEqual(r.calls[0].arguments, #"{"query":"NerdSnipe Inc"}"#)
    }

    func test_inlineFormat_cleanedTextIsEmpty_whenOnlyToolCall() {
        // This is the "call:webSearch stuck in bubble" bug — cleanedText must be empty
        // so ChatSession removes the aiMessage entry instead of showing raw call syntax.
        let r = GemmaOutputRecovery.parse(from: #"call:webSearch{"query":"test"}"#)
        XCTAssertTrue(r.cleanedText.isEmpty,
            "cleanedText must be empty when model emits only a tool call — not the raw call: text")
    }

    func test_inlineFormat_preservesPreambleText() {
        let r = GemmaOutputRecovery.parse(from: "I'll search for that.\n\ncall:webSearch{\"query\":\"test\"}")
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertTrue(r.cleanedText.contains("I'll search for that."),
            "Preamble text before the tool call must be preserved in cleanedText")
    }

    func test_inlineFormat_multipleArgs() {
        let r = GemmaOutputRecovery.parse(from: #"call:fetchURL{"url":"https://example.com"}"#)
        XCTAssertEqual(r.calls[0].name, "fetchURL")
        XCTAssertTrue(r.calls[0].arguments.contains("https://example.com"))
    }

    func test_inlineFormat_nestedBraces() {
        let r = GemmaOutputRecovery.parse(from: #"call:remember{"body":{"key":"value"}}"#)
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls[0].name, "remember")
    }

    // MARK: - XML <tool_call> format

    func test_xmlFormat_parsesCall() {
        let r = GemmaOutputRecovery.parse(from: #"<tool_call>{"name":"webSearch","arguments":{"query":"test"}}</tool_call>"#)
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls[0].name, "webSearch")
    }

    func test_xmlFormat_cleanedTextIsEmpty_whenOnlyToolCall() {
        let r = GemmaOutputRecovery.parse(from: #"<tool_call>{"name":"webSearch","arguments":{"query":"q"}}</tool_call>"#)
        XCTAssertTrue(r.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - tool_code Python block format

    func test_pythonBlock_keywordArg() {
        let src = "```tool_code\nwebSearch(query=\"ottawa weather\")\n```"
        let r = GemmaOutputRecovery.parse(from: src)
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls[0].name, "webSearch")
        XCTAssertTrue(r.calls[0].arguments.contains("ottawa weather"))
    }

    func test_pythonBlock_cleanedTextIsEmpty_whenOnlyBlock() {
        let src = "```tool_code\nwebSearch(query=\"test\")\n```"
        let r = GemmaOutputRecovery.parse(from: src)
        XCTAssertTrue(r.cleanedText.isEmpty)
    }

    func test_pythonBlock_preservesPreamble() {
        let src = "Let me check.\n```tool_code\nwebSearch(query=\"test\")\n```"
        let r = GemmaOutputRecovery.parse(from: src)
        XCTAssertTrue(r.cleanedText.contains("Let me check."))
        XCTAssertEqual(r.calls.count, 1)
    }

    // MARK: - Channel markup stripping

    func test_channelMarkup_stripped() {
        // stripChannelMarkup removes the <|channel>thought and <channel|> tags but
        // leaves the thought body in the text (Gemma4StreamProcessor handles channel routing).
        let src = "<|channel>thought\nsome reasoning\n<channel|>The answer is 42."
        let r = GemmaOutputRecovery.parse(from: src)
        XCTAssertFalse(r.cleanedText.contains("<|channel>"), "channel open-tag must be stripped")
        XCTAssertFalse(r.cleanedText.contains("<channel|>"), "channel close-tag must be stripped")
        XCTAssertTrue(r.cleanedText.contains("The answer is 42."))
        XCTAssertTrue(r.calls.isEmpty)
    }

    func test_toolCallMarkup_stripped() {
        let src = "<|tool_call>call:webSearch{\"query\":\"q\"}<tool_call|>"
        let r = GemmaOutputRecovery.parse(from: src)
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertTrue(r.cleanedText.isEmpty)
    }

    // MARK: - No tool calls

    func test_plainText_returnsNoCalls() {
        let r = GemmaOutputRecovery.parse(from: "The capital of France is Paris.")
        XCTAssertTrue(r.calls.isEmpty)
        XCTAssertEqual(r.cleanedText, "The capital of France is Paris.")
    }

    func test_emptyString_returnsNoCalls() {
        let r = GemmaOutputRecovery.parse(from: "")
        XCTAssertTrue(r.calls.isEmpty)
        XCTAssertTrue(r.cleanedText.isEmpty)
    }
}
