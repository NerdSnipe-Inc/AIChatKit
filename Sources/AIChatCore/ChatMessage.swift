import Foundation

/// A message in a conversation. Works with OpenAI, Anthropic, and any compatible provider.
public struct ChatMessage: Codable, Sendable, Identifiable {
    /// Stable client-side identifier for the message.
    public let id: UUID
    /// Sender role for this message.
    public let role: Role
    /// Ordered content blocks that compose the message payload.
    public var content: [ContentBlock]
    /// Present when `role == .tool` — the ID of the tool call being answered.
    public let toolCallId: String?
    /// Present on assistant messages that contain tool calls.
    public let toolCalls: [ToolCallBlock]?

    /// Supported message roles across AIChatKit providers.
    public enum Role: String, Codable, Sendable {
        /// High-priority system instruction content.
        case system
        /// End-user authored content.
        case user
        /// Assistant model response content.
        case assistant
        /// Tool execution result content.
        case tool
    }

    // MARK: - Init

    /// Creates a message with explicit role and content blocks.
    ///
    /// - Parameters:
    ///   - id: Stable message identifier. Defaults to a new UUID.
    ///   - role: Sender role for the message.
    ///   - content: Ordered content blocks.
    ///   - toolCallId: Tool call identifier when replying as `.tool`.
    ///   - toolCalls: Tool calls emitted by assistant responses.
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

    /// Creates a message from a single text block.
    ///
    /// - Parameters:
    ///   - id: Stable message identifier. Defaults to a new UUID.
    ///   - role: Sender role for the message.
    ///   - content: Plain text payload.
    public init(id: UUID = UUID(), role: Role, content: String) {
        self.init(id: id, role: role, content: [.text(content)])
    }

    /// Creates a tool-result message.
    ///
    /// - Parameters:
    ///   - id: Stable message identifier. Defaults to a new UUID.
    ///   - toolCallId: Tool call identifier being answered.
    ///   - content: Tool result text content.
    public init(id: UUID = UUID(), toolCallId: String, content: String) {
        self.init(id: id, role: .tool, content: [.text(content)], toolCallId: toolCallId)
    }

    /// Creates a system message helper.
    ///
    /// - Parameter text: System instruction content.
    /// - Returns: A `.system` chat message.
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

    /// Provider-agnostic content blocks supported by AIChatKit.
    enum ContentBlock: Codable, Sendable {
        /// Plain text content.
        case text(String)
        /// Image reference content.
        case image(ImageContent)
        /// Assistant-issued tool call.
        case toolCall(ToolCallBlock)
        /// Tool execution result payload.
        case toolResult(ToolResultBlock)
        /// Non-user-visible model reasoning content.
        case thinking(ThinkingBlock)
        /// Opaque encrypted/redacted thinking payload.
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

    /// Image content payload used in multimodal requests.
    struct ImageContent: Codable, Sendable {
        /// Remote URL for image input.
        public let url: String?
        /// MIME media type for inline base64 image data.
        public let mediaType: String?
        /// Base64-encoded image bytes for inline image payloads.
        public let base64Data: String?

        /// Creates image content for a URL or inline base64 payload.
        ///
        /// - Parameters:
        ///   - url: Remote image URL.
        ///   - mediaType: MIME media type for inline data.
        ///   - base64Data: Base64 image bytes when sending inline.
        public init(url: String? = nil, mediaType: String? = nil, base64Data: String? = nil) {
            self.url = url
            self.mediaType = mediaType
            self.base64Data = base64Data
        }
    }

    /// Tool invocation requested by the assistant.
    struct ToolCallBlock: Codable, Sendable {
        /// Provider-generated tool call identifier.
        public let id: String
        /// Tool/function name to execute.
        public let name: String
        /// JSON-encoded tool arguments.
        public var arguments: String

        /// Creates a normalized tool-call block.
        ///
        /// - Parameters:
        ///   - id: Tool call identifier.
        ///   - name: Tool/function name.
        ///   - arguments: JSON-encoded argument object.
        public init(id: String, name: String, arguments: String) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    /// Tool execution output sent back to the model.
    struct ToolResultBlock: Codable, Sendable {
        /// Tool call identifier this result belongs to.
        public let toolCallId: String
        /// Tool result content, typically plain text or serialized JSON.
        public let content: String
        /// Indicates whether the tool execution failed.
        public var isError: Bool

        /// Creates a tool-result block.
        ///
        /// - Parameters:
        ///   - toolCallId: Tool call identifier being answered.
        ///   - content: Tool result payload.
        ///   - isError: Indicates failure output when `true`.
        public init(toolCallId: String, content: String, isError: Bool = false) {
            self.toolCallId = toolCallId
            self.content = content
            self.isError = isError
        }
    }

    /// Anthropic-compatible thinking block that can be round-tripped.
    struct ThinkingBlock: Codable, Sendable {
        /// Model reasoning text content.
        public var text: String
        /// Optional signature required for Anthropic thinking replay.
        public var signature: String?

        /// Creates a thinking content block.
        ///
        /// - Parameters:
        ///   - text: Model reasoning text.
        ///   - signature: Optional provider signature for replay.
        public init(text: String, signature: String? = nil) {
            self.text = text
            self.signature = signature
        }
    }
}
