import Foundation
import JSONSchema

// MARK: - Request wire types

struct OAIRequestBody: Encodable {
    let model: String
    let messages: [OAIMessage]
    let stream: Bool
    let streamOptions: OAIStreamOptions?
    let temperature: Double?
    let topP: Double?
    let maxTokens: Int?
    let stop: [String]?
    let tools: [OAITool]?
    let toolChoice: OAIToolChoice?
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, stop, tools
        case streamOptions = "stream_options"
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
        case reasoningEffort = "reasoning_effort"
    }
}

struct OAIStreamOptions: Encodable {
    let includeUsage: Bool
    enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
}

struct OAIMessage: Encodable {
    let role: String
    let content: OAIContent?
    let toolCalls: [OAIToolCall]?
    let toolCallId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

enum OAIContent: Encodable {
    case text(String)
    case parts([OAIPart])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let t):   try c.encode(t)
        case .parts(let p):  try c.encode(p)
        }
    }
}

struct OAIPart: Encodable {
    let type: String
    let text: String?
    let imageUrl: OAIImageUrl?

    enum CodingKeys: String, CodingKey { case type, text, imageUrl = "image_url" }
}

struct OAIImageUrl: Encodable {
    let url: String
    let detail: String
}

struct OAIToolCall: Encodable {
    let id: String
    let type: String
    let function: OAIFunctionCall

    struct OAIFunctionCall: Encodable {
        let name: String
        let arguments: String
    }
}

struct OAIToolChoice: Encodable {
    enum Value {
        case none, auto, required
        case function(String)
    }

    let value: Value

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case .none:            try c.encode("none")
        case .auto:            try c.encode("auto")
        case .required:        try c.encode("required")
        case .function(let n):
            var kc = encoder.container(keyedBy: FuncKeys.self)
            try kc.encode("function", forKey: .type)
            var fc = kc.nestedContainer(keyedBy: NameKey.self, forKey: .function)
            try fc.encode(n, forKey: .name)
        }
    }

    private enum FuncKeys: String, CodingKey { case type, function }
    private enum NameKey: String, CodingKey { case name }
}

struct OAITool: Encodable {
    let type: String
    let function: OAIToolFunction

    struct OAIToolFunction: Encodable {
        let name: String
        let description: String?
        let parameters: JSONSchema?
        let strict: Bool?
    }
}

// MARK: - Streaming chunk wire types

struct OAIChunk: Decodable {
    let id: String?
    let choices: [Choice]?
    let usage: Usage?

    struct Choice: Decodable {
        let index: Int
        let delta: Delta
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case index, delta, finishReason = "finish_reason" }
    }

    struct Delta: Decodable {
        let role: String?
        let content: String?
        let reasoningContent: String?
        let toolCalls: [ToolCallDelta]?
        enum CodingKeys: String, CodingKey {
            case role, content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable {
        let index: Int
        let id: String?
        let type: String?
        let function: FunctionDelta?

        struct FunctionDelta: Decodable {
            let name: String?
            let arguments: String?
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

// MARK: - Non-streaming response wire types

struct OAIResponse: Decodable {
    let id: String?
    let model: String
    let choices: [Choice]
    let usage: OAIChunk.Usage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case message, finishReason = "finish_reason" }
    }

    struct Message: Decodable {
        let role: String
        let content: String?
        let reasoningContent: String?
        let toolCalls: [OAIToolCallResponse]?
        enum CodingKeys: String, CodingKey {
            case role, content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }
}

struct OAIToolCallResponse: Decodable {
    let id: String
    let type: String
    let function: FunctionResponse

    struct FunctionResponse: Decodable {
        let name: String
        let arguments: String
    }
}

// MARK: - Error wire type

struct OAIErrorResponse: Decodable {
    let error: OAIError
    struct OAIError: Decodable {
        let message: String
        let type: String?
    }
}
