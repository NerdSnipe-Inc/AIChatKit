import XCTest
@testable import AIChatCore

final class ChatMessageTests: XCTestCase {

    // MARK: - Role encoding

    func test_userRole_encodesAsString() throws {
        let msg = ChatMessage(role: .user, content: [.text("hello")])
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["role"] as? String, "user")
    }

    func test_toolRole_encodesAsString() throws {
        let msg = ChatMessage(role: .tool, content: [.text("result")], toolCallId: "call_1")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["role"] as? String, "tool")
        XCTAssertEqual(json["tool_call_id"] as? String, "call_1")
    }

    // MARK: - Content encoding

    func test_singleText_encodesAsString() throws {
        let msg = ChatMessage(role: .user, content: [.text("hi")])
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["content"] as? String, "hi")
    }

    func test_multipleContentBlocks_encodesAsArray() throws {
        let msg = ChatMessage(role: .user, content: [.text("a"), .text("b")])
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssert(json["content"] is [[String: Any]])
    }

    func test_imageContent_encodesUrlAndDetail() throws {
        let image = ChatMessage.ImageContent(url: "https://example.com/img.png", mediaType: nil, base64Data: nil)
        let msg = ChatMessage(role: .user, content: [.image(image)])
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let blocks = json["content"] as! [[String: Any]]
        // Internal encoding uses "image"; OpenAIRequestBuilder converts to "image_url" wire format
        XCTAssertEqual(blocks[0]["type"] as? String, "image")
    }

    // MARK: - Tool call blocks

    func test_assistantToolCall_encodesToolCallsArray() throws {
        let call = ChatMessage.ToolCallBlock(id: "call_abc", name: "get_weather", arguments: "{\"city\":\"SF\"}")
        let msg = ChatMessage(role: .assistant, content: [], toolCalls: [call])
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // ChatMessage uses flat internal encoding; OpenAIRequestBuilder handles wire transformation
        let toolCalls = json["tool_calls"] as! [[String: Any]]
        XCTAssertEqual(toolCalls[0]["id"] as? String, "call_abc")
        XCTAssertEqual(toolCalls[0]["name"] as? String, "get_weather")
    }

    func test_toolResultMessage_encodesToolCallId() throws {
        let msg = ChatMessage(toolCallId: "call_abc", content: "72°F")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["role"] as? String, "tool")
        XCTAssertEqual(json["tool_call_id"] as? String, "call_abc")
        XCTAssertEqual(json["content"] as? String, "72°F")
    }

    // MARK: - Thinking block round-trip

    func test_thinkingBlock_preservesSignature() throws {
        let block = ChatMessage.ThinkingBlock(text: "I should check the weather", signature: "sig_xyz")
        let original = ChatMessage(role: .assistant, content: [.thinking(block)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        if case .thinking(let decoded) = decoded.content[0] {
            XCTAssertEqual(decoded.text, "I should check the weather")
            XCTAssertEqual(decoded.signature, "sig_xyz")
        } else {
            XCTFail("Expected .thinking content block")
        }
    }

    func test_redactedThinking_roundTrips() throws {
        let original = ChatMessage(role: .assistant, content: [.redactedThinking("encrypted_data_blob")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        if case .redactedThinking(let blob) = decoded.content[0] {
            XCTAssertEqual(blob, "encrypted_data_blob")
        } else {
            XCTFail("Expected .redactedThinking content block")
        }
    }

    // MARK: - Convenience inits

    func test_stringInit_createsSingleTextBlock() {
        let msg = ChatMessage(role: .user, content: "hello world")
        XCTAssertEqual(msg.content.count, 1)
        if case .text(let t) = msg.content[0] {
            XCTAssertEqual(t, "hello world")
        } else {
            XCTFail("Expected .text block")
        }
    }

    func test_systemMessage_convenience() {
        let msg = ChatMessage.system("You are helpful.")
        XCTAssertEqual(msg.role, .system)
    }
}
