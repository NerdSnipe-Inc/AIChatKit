import Foundation

// MARK: - Request

struct AnthropicRequestBody: Encodable {
    let model: String
    let messages: [AnthropicMessage]
    let maxTokens: Int
    let stream: Bool
    let system: [AnthropicSystemBlock]?
    let temperature: Double?
    let thinking: AnthropicThinkingConfig?
    let tools: [AnthropicTool]?
    let topP: Double?
    let stopSequences: [String]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, system, temperature, thinking, tools
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case stopSequences = "stop_sequences"
    }
}

struct AnthropicSystemBlock: Encodable {
    let type: String
    let text: String
}

struct AnthropicThinkingConfig: Encodable {
    let type: String
    let budgetTokens: Int
    enum CodingKeys: String, CodingKey { case type, budgetTokens = "budget_tokens" }
}

struct AnthropicMessage: Encodable {
    let role: String
    let content: [AnthropicContentBlock]
}

enum AnthropicContentBlock: Encodable {
    case text(String)
    case image(mediaType: String, data: String)
    case imageUrl(String)
    case toolUse(id: String, name: String, input: [String: AnyCodable])
    case toolResult(toolUseId: String, content: String, isError: Bool)
    case thinking(thinking: String, signature: String)
    case redactedThinking(data: String)

    private enum CK: String, CodingKey {
        case type, text, source, id, name, input, toolUseId = "tool_use_id", content, thinking, signature, data, isError = "is_error"
    }
    private enum SK: String, CodingKey { case type, mediaType = "media_type", data, url }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CK.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type); try c.encode(t, forKey: .text)
        case .image(let mt, let d):
            try c.encode("image", forKey: .type)
            var s = c.nestedContainer(keyedBy: SK.self, forKey: .source)
            try s.encode("base64", forKey: .type); try s.encode(mt, forKey: .mediaType); try s.encode(d, forKey: .data)
        case .imageUrl(let url):
            try c.encode("image", forKey: .type)
            var s = c.nestedContainer(keyedBy: SK.self, forKey: .source)
            try s.encode("url", forKey: .type); try s.encode(url, forKey: .url)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseId, forKey: .toolUseId); try c.encode(content, forKey: .content)
            if isError { try c.encode(true, forKey: .isError) }
        case .thinking(let thinking, let signature):
            try c.encode("thinking", forKey: .type)
            try c.encode(thinking, forKey: .thinking); try c.encode(signature, forKey: .signature)
        case .redactedThinking(let data):
            try c.encode("redacted_thinking", forKey: .type); try c.encode(data, forKey: .data)
        }
    }
}

struct AnthropicTool: Encodable {
    let name: String
    let description: String?
    let inputSchema: [String: AnyCodable]?
    enum CodingKeys: String, CodingKey { case name, description, inputSchema = "input_schema" }
}

// MARK: - Streaming events

struct AnthropicStreamEvent: Decodable {
    let type: String
    let index: Int?
    let contentBlock: ContentBlock?
    let delta: Delta?
    let error: APIError?

    enum CodingKeys: String, CodingKey {
        case type, index, delta, error
        case contentBlock = "content_block"
    }

    struct ContentBlock: Decodable {
        let type: String
        let id: String?
        let name: String?
        let thinking: String?
        let data: String?
    }

    struct Delta: Decodable {
        // Optional: `message_delta` events send {"stop_reason":"end_turn"} with no "type" key.
        // Making it optional prevents DecodingError.keyNotFound from killing the stream.
        let type: String?
        let text: String?
        let thinking: String?
        let signature: String?
        let partialJson: String?

        enum CodingKeys: String, CodingKey {
            case type, text, thinking, signature
            case partialJson = "partial_json"
        }
    }

    struct APIError: Decodable {
        let type: String?
        let message: String?
    }
}

// MARK: - Non-streaming response

struct AnthropicResponse: Decodable {
    let id: String?
    let model: String
    let content: [ContentBlock]
    let stopReason: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id, model, content, usage
        case stopReason = "stop_reason"
    }

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let thinking: String?
        let signature: String?
        let id: String?
        let name: String?
        let input: [String: AnyCodable]?
        let data: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens", outputTokens = "output_tokens" }
    }
}

// MARK: - AnyCodable helper

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)   { value = v; return }
        if let v = try? c.decode(Int.self)    { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([AnyCodable].self) { value = v.map(\.value); return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues(\.value); return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:               try c.encode(v)
        case let v as Int:                try c.encode(v)
        case let v as Double:             try c.encode(v)
        case let v as String:             try c.encode(v)
        case let v as [Any]:              try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]:      try c.encode(v.mapValues { AnyCodable($0) })
        default:                          try c.encodeNil()
        }
    }
}
