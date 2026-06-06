import Foundation

/// Implemented by every backend: OpenAI, Anthropic, llama.cpp, MLX, etc.
public protocol ChatProvider: Sendable {
    /// A stable identifier (e.g. "openai", "anthropic", "llama").
    var id: String { get }
    /// Human-readable name shown in UI.
    var name: String { get }
    /// Message shown when the model returns no output at all.
    /// Override in API-backed providers to mention key settings; override in local providers
    /// to avoid confusing users with API-key references.
    var zeroResponseMessage: String { get }

    /// Returns an async stream of events for a streaming completion request.
    func stream(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error>

    /// Returns a single completion result (non-streaming).
    func complete(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult
}

public extension ChatProvider {
    var zeroResponseMessage: String {
        "No response — check your API key in Settings (⌘,)"
    }
}
