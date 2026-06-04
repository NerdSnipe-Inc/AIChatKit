import XCTest
@testable import AIChatAnthropic
import AIChatCore

final class AnthropicRequestBuilderTests: XCTestCase {

    private func builder(apiKey: String = "test-key") -> AnthropicRequestBuilder {
        AnthropicRequestBuilder(apiKey: apiKey)
    }

    // MARK: - Headers

    func test_apiKeyHeader_isSet() throws {
        let req = try builder().buildRequest(messages: [], model: "claude-opus-4-8", options: .init(), stream: false)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "test-key")
    }

    func test_anthropicVersionHeader_isSet() throws {
        let req = try builder().buildRequest(messages: [], model: "claude-opus-4-8", options: .init(), stream: false)
        XCTAssertNotNil(req.value(forHTTPHeaderField: "anthropic-version"))
    }

    func test_contentTypeHeader_isJSON() throws {
        let req = try builder().buildRequest(messages: [], model: "claude-opus-4-8", options: .init(), stream: false)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_betaHeader_includedWhenThinkingEnabled() throws {
        var options = ChatRequestOptions()
        options.thinkingBudget = 5000
        let req = try builder().buildRequest(messages: [], model: "claude-opus-4-8", options: options, stream: false)
        XCTAssertNotNil(req.value(forHTTPHeaderField: "anthropic-beta"))
    }

    // MARK: - System message

    func test_systemMessage_goesToSystemParam() throws {
        var options = ChatRequestOptions()
        options.systemPrompt = "You are helpful."
        let req = try builder().buildRequest(messages: [], model: "claude-opus-4-8", options: options, stream: false)
        let body = try self.body(from: req)
        let system = body["system"] as? [[String: Any]]
        XCTAssertEqual(system?.first?["text"] as? String, "You are helpful.")
    }

    func test_systemMessageInHistory_isExtractedToParam() throws {
        let messages = [ChatMessage.system("Be concise.")]
        let req = try builder().buildRequest(messages: messages, model: "claude-opus-4-8", options: .init(), stream: false)
        let body = try self.body(from: req)
        let msgs = body["messages"] as? [[String: Any]] ?? []
        // System message should not appear in messages array
        let roles = msgs.compactMap { $0["role"] as? String }
        XCTAssertFalse(roles.contains("system"))
    }

    // MARK: - Thinking config

    func test_thinkingBudget_encodesThinkingConfig() throws {
        var options = ChatRequestOptions()
        options.thinkingBudget = 8000
        let req = try builder().buildRequest(messages: [], model: "claude-opus-4-8", options: options, stream: false)
        let body = try self.body(from: req)
        let thinking = body["thinking"] as? [String: Any]
        XCTAssertEqual(thinking?["type"] as? String, "enabled")
        XCTAssertEqual(thinking?["budget_tokens"] as? Int, 8000)
    }

    // MARK: - Message conversion

    func test_userTextMessage_encodesCorrectly() throws {
        let messages = [ChatMessage(role: .user, content: "Hello")]
        let req = try builder().buildRequest(messages: messages, model: "claude-opus-4-8", options: .init(), stream: false)
        let body = try self.body(from: req)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs[0]["role"] as? String, "user")
    }

    func test_thinkingBlock_preservedWithSignature() throws {
        let block = ChatMessage.ThinkingBlock(text: "reasoning here", signature: "sig_abc")
        let messages = [
            ChatMessage(role: .assistant, content: [.thinking(block), .text("Answer")]),
        ]
        let req = try builder().buildRequest(messages: messages, model: "claude-opus-4-8", options: .init(), stream: false)
        let body = try self.body(from: req)
        let msgs = body["messages"] as! [[String: Any]]
        let content = msgs[0]["content"] as! [[String: Any]]
        let thinkingBlock = content.first { $0["type"] as? String == "thinking" }
        XCTAssertNotNil(thinkingBlock)
        XCTAssertEqual(thinkingBlock?["signature"] as? String, "sig_abc")
    }

    func test_toolCallBlock_encodesAsToolUse() throws {
        let call = ChatMessage.ToolCallBlock(id: "toolu_1", name: "search", arguments: "{\"q\":\"swift\"}")
        let messages = [ChatMessage(role: .assistant, content: [.text("Let me search."), .toolCall(call)])]
        let req = try builder().buildRequest(messages: messages, model: "claude-opus-4-8", options: .init(), stream: false)
        let body = try self.body(from: req)
        let msgs = body["messages"] as! [[String: Any]]
        let content = msgs[0]["content"] as! [[String: Any]]
        let toolBlock = content.first { $0["type"] as? String == "tool_use" }
        XCTAssertEqual(toolBlock?["id"] as? String, "toolu_1")
        XCTAssertEqual(toolBlock?["name"] as? String, "search")
    }

    func test_toolResultMessage_encodesAsToolResult() throws {
        let messages = [ChatMessage(toolCallId: "toolu_1", content: "10 results found")]
        let req = try builder().buildRequest(messages: messages, model: "claude-opus-4-8", options: .init(), stream: false)
        let body = try self.body(from: req)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs[0]["role"] as? String, "user")
        let content = msgs[0]["content"] as! [[String: Any]]
        let resultBlock = content.first { $0["type"] as? String == "tool_result" }
        XCTAssertEqual(resultBlock?["tool_use_id"] as? String, "toolu_1")
    }

    // MARK: - Helpers

    private func body(from request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    }
}
