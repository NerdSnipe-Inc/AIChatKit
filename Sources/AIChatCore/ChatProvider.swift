import Foundation

/// The provider contract implemented by every chat backend.
///
/// Conforming types translate `ChatMessage` values to provider-specific wire formats
/// and emit normalized `ChatStreamEvent` values for the UI and orchestration layers.
public protocol ChatProvider: Sendable {
    /// A stable identifier (e.g. "openai", "anthropic", "llama").
    var id: String { get }
    /// Human-readable name shown in UI.
    var name: String { get }
    /// Message shown when the model returns no output at all.
    /// Override in API-backed providers to mention key settings; override in local providers
    /// to avoid confusing users with API-key references.
    var zeroResponseMessage: String { get }

    /// Starts a streaming completion request.
    ///
    /// Implementations should map provider events into normalized `ChatStreamEvent`
    /// values and finish the stream when the provider signals completion.
    ///
    /// - Parameters:
    ///   - messages: Ordered conversation history, including the latest user message.
    ///   - model: Provider model identifier to use for generation.
    ///   - options: Shared request options interpreted by the provider.
    /// - Returns: An async stream of incremental chat events.
    func stream(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error>

    /// Executes a non-streaming completion request.
    ///
    /// - Parameters:
    ///   - messages: Ordered conversation history, including the latest user message.
    ///   - model: Provider model identifier to use for generation.
    ///   - options: Shared request options interpreted by the provider.
    /// - Returns: The completed assistant message and optional usage metadata.
    /// - Throws: `ChatError` when the request fails, or provider-specific errors.
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
