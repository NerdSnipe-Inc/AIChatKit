import Foundation

/// Events emitted by a provider during streaming. Both OpenAI and Anthropic map to this unified set.
public enum ChatStreamEvent: Sendable, Equatable {
    /// A text delta to append to the current assistant message.
    case text(String)
    /// A reasoning/thinking delta (streamed before the answer).
    case reasoning(String)
    /// A complete Anthropic thinking block — text + signature for round-tripping.
    case thinkingBlockComplete(thinking: String, signature: String)
    /// An Anthropic redacted thinking block (encrypted, must be preserved verbatim).
    case redactedThinking(data: String)
    /// A complete tool call ready for execution.
    case toolCallComplete(id: String, name: String, arguments: String)
    /// Token usage statistics (typically in the final chunk).
    case usage(TokenUsage)
    /// Stream finished normally.
    case done
}

public struct TokenUsage: Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}
