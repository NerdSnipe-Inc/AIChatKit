import Foundation

/// A message in a conversation. Works with OpenAI, Anthropic, and any compatible provider.
public struct ChatMessage: Codable, Sendable, Identifiable {
    public let id: UUID
    public let role: Role
    public var content: [ContentBlock]
    /// Present when `role == .tool` — the ID of the tool call being answered.
    public let toolCallId: String?
    /// Present on assistant messages that contain tool calls.
    public let toolCalls: [ToolCallBlock]?

    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        role: Role,
        content: [ContentBlock],
        toolCallId: String? = nil,
        toolCalls: [ToolCallBlock]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }

    /// Convenience: single text content.
    public init(id: UUID = UUID(), role: Role, content: String) {
        self.init(id: id, role: role, content: [.text(content)])
    }

    /// Convenience: tool result message.
    public init(id: UUID = UUID(), toolCallId: String, content: String) {
        self.init(id: id, role: .tool, content: [.text(content)], toolCallId: toolCallId)
    }

    /// Convenience: system message.
    public static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, content: text)
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case id, role, content, toolCallId = "tool_call_id", toolCalls = "tool_calls"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        if let toolCalls { try c.encode(toolCalls, forKey: .toolCalls) }

        // Single plain text encodes as a string; everything else as array
        if content.count == 1, case .text(let t) = content[0], !content.isEmpty {
            try c.encode(t, forKey: .content)
        } else if !content.isEmpty {
            try c.encode(content, forKey: .content)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        toolCalls = try c.decodeIfPresent([ToolCallBlock].self, forKey: .toolCalls)

        // Content may be a plain string or an array of blocks
        if let text = try? c.decode(String.self, forKey: .content) {
            content = [.text(text)]
        } else {
            content = (try? c.decode([ContentBlock].self, forKey: .content)) ?? []
        }
    }
}

// MARK: - Content Blocks

public extension ChatMessage {

    enum ContentBlock: Codable, Sendable {
        case text(String)
        case image(ImageContent)
        case toolCall(ToolCallBlock)
        case toolResult(ToolResultBlock)
        case thinking(ThinkingBlock)
        case redactedThinking(String)

        private enum BlockType: String, Codable {
            case text, image, toolCall = "tool_call", toolResult = "tool_result"
            case thinking, redactedThinking = "redacted_thinking"
        }

        private enum CodingKeys: String, CodingKey {
            case type, value
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let t):
                try c.encode(BlockType.text, forKey: .type)
                try c.encode(t, forKey: .value)
            case .image(let img):
                try c.encode(BlockType.image, forKey: .type)
                try c.encode(img, forKey: .value)
            case .toolCall(let tc):
                try c.encode(BlockType.toolCall, forKey: .type)
                try c.encode(tc, forKey: .value)
            case .toolResult(let tr):
                try c.encode(BlockType.toolResult, forKey: .type)
                try c.encode(tr, forKey: .value)
            case .thinking(let t):
                try c.encode(BlockType.thinking, forKey: .type)
                try c.encode(t, forKey: .value)
            case .redactedThinking(let d):
                try c.encode(BlockType.redactedThinking, forKey: .type)
                try c.encode(d, forKey: .value)
            }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(BlockType.self, forKey: .type)
            switch type {
            case .text:          self = .text(try c.decode(String.self, forKey: .value))
            case .image:         self = .image(try c.decode(ImageContent.self, forKey: .value))
            case .toolCall:      self = .toolCall(try c.decode(ToolCallBlock.self, forKey: .value))
            case .toolResult:    self = .toolResult(try c.decode(ToolResultBlock.self, forKey: .value))
            case .thinking:      self = .thinking(try c.decode(ThinkingBlock.self, forKey: .value))
            case .redactedThinking: self = .redactedThinking(try c.decode(String.self, forKey: .value))
            }
        }
    }

    struct ImageContent: Codable, Sendable {
        public let url: String?
        public let mediaType: String?
        public let base64Data: String?

        public init(url: String? = nil, mediaType: String? = nil, base64Data: String? = nil) {
            self.url = url
            self.mediaType = mediaType
            self.base64Data = base64Data
        }
    }

    struct ToolCallBlock: Codable, Sendable {
        public let id: String
        public let name: String
        public var arguments: String

        public init(id: String, name: String, arguments: String) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    struct ToolResultBlock: Codable, Sendable {
        public let toolCallId: String
        public let content: String
        public var isError: Bool

        public init(toolCallId: String, content: String, isError: Bool = false) {
            self.toolCallId = toolCallId
            self.content = content
            self.isError = isError
        }
    }

    struct ThinkingBlock: Codable, Sendable {
        public var text: String
        public var signature: String?

        public init(text: String, signature: String? = nil) {
            self.text = text
            self.signature = signature
        }
    }
}
