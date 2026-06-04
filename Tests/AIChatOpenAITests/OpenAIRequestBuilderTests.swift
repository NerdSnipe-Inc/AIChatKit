import XCTest
@testable import AIChatOpenAI
import AIChatCore

final class OpenAIRequestBuilderTests: XCTestCase {

    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    private func builder(apiKey: String = "sk-test", streamUsage: Bool = true) -> OpenAIRequestBuilder {
        OpenAIRequestBuilder(endpoint: endpoint, apiKey: apiKey, streamUsage: streamUsage)
    }

    // MARK: - Headers

    func test_authorizationHeader_isSet() throws {
        let req = try builder(apiKey: "sk-abc").buildRequest(messages: [], model: "gpt-4o", options: .init(), stream: false)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-abc")
    }

    func test_contentTypeHeader_isJSON() throws {
        let req = try builder().buildRequest(messages: [], model: "gpt-4o", options: .init(), stream: false)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_extraHeaders_areIncluded() throws {
        var options = ChatRequestOptions()
        options.extraHeaders = ["X-Custom": "value"]
        let req = try builder().buildRequest(messages: [], model: "gpt-4o", options: options, stream: false)
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Custom"), "value")
    }

    // MARK: - Stream options

    func test_streamTrue_encodesStreamTrue() throws {
        let req = try builder().buildRequest(messages: [], model: "gpt-4o", options: .init(), stream: true)
        let body = try body(from: req)
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func test_streamTrue_withStreamUsageTrue_includesStreamOptions() throws {
        let req = try builder(streamUsage: true).buildRequest(messages: [], model: "gpt-4o", options: .init(), stream: true)
        let body = try body(from: req)
        let opts = body["stream_options"] as? [String: Any]
        XCTAssertEqual(opts?["include_usage"] as? Bool, true)
    }

    func test_streamTrue_withStreamUsageFalse_omitsStreamOptions() throws {
        let req = try builder(streamUsage: false).buildRequest(messages: [], model: "gpt-4o", options: .init(), stream: true)
        let body = try body(from: req)
        XCTAssertNil(body["stream_options"])
    }

    // MARK: - Message encoding

    func test_userTextMessage_encodesCorrectly() throws {
        let messages = [ChatMessage(role: .user, content: "Hello")]
        let req = try builder().buildRequest(messages: messages, model: "gpt-4o", options: .init(), stream: false)
        let body = try body(from: req)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs[0]["role"] as? String, "user")
        XCTAssertEqual(msgs[0]["content"] as? String, "Hello")
    }

    func test_assistantToolCallMessage_encodesToolCallsArray() throws {
        let call = ChatMessage.ToolCallBlock(id: "call_1", name: "fn", arguments: "{}")
        let messages = [ChatMessage(role: .assistant, content: [], toolCalls: [call])]
        let req = try builder().buildRequest(messages: messages, model: "gpt-4o", options: .init(), stream: false)
        let body = try body(from: req)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertNotNil(msgs[0]["tool_calls"])
    }

    func test_toolResultMessage_encodesToolCallId() throws {
        let messages = [ChatMessage(toolCallId: "call_1", content: "72°F")]
        let req = try builder().buildRequest(messages: messages, model: "gpt-4o", options: .init(), stream: false)
        let body = try body(from: req)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs[0]["role"] as? String, "tool")
        XCTAssertEqual(msgs[0]["tool_call_id"] as? String, "call_1")
    }

    func test_thinkingBlock_isStrippedForOpenAI() throws {
        // OpenAI doesn't accept thinking blocks — they should be omitted
        let block = ChatMessage.ThinkingBlock(text: "...", signature: "sig")
        let messages = [
            ChatMessage(role: .assistant, content: [.thinking(block), .text("The answer is 42")]),
        ]
        let req = try builder().buildRequest(messages: messages, model: "gpt-4o", options: .init(), stream: false)
        let body = try body(from: req)
        let msgs = body["messages"] as! [[String: Any]]
        // Content should only contain the text block
        XCTAssertEqual(msgs[0]["content"] as? String, "The answer is 42")
    }

    // MARK: - Options

    func test_temperature_isEncoded() throws {
        var options = ChatRequestOptions()
        options.temperature = 0.7
        let req = try builder().buildRequest(messages: [], model: "gpt-4o", options: options, stream: false)
        let body = try body(from: req)
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
    }

    func test_maxTokens_isEncoded() throws {
        var options = ChatRequestOptions()
        options.maxTokens = 512
        let req = try builder().buildRequest(messages: [], model: "gpt-4o", options: options, stream: false)
        let body = try body(from: req)
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
    }

    func test_reasoningEffort_isEncoded() throws {
        var options = ChatRequestOptions()
        options.reasoningEffort = "high"
        let req = try builder().buildRequest(messages: [], model: "o3", options: options, stream: false)
        let body = try body(from: req)
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
    }

    // MARK: - Helpers

    private func body(from request: URLRequest) throws -> [String: Any] {
        let data = request.httpBody!
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
