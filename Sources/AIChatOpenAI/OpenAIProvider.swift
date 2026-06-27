import Foundation
import AIChatCore

/// ChatProvider for OpenAI and any OpenAI-compatible server (llama.cpp, OpenRouter, Groq, etc.).
public struct OpenAIProvider: ChatProvider {
    /// Stable provider identifier used by host applications.
    public let id: String
    /// Human-readable provider name for settings and UI.
    public let name: String

    private let builder: OpenAIRequestBuilder
    private let session: URLSession

    /// Creates an OpenAI-compatible provider.
    ///
    /// Configure `endpoint` to target compatible APIs such as OpenRouter, Groq,
    /// local `llama.cpp`, or other OpenAI wire-compatible servers.
    ///
    /// - Parameters:
    ///   - apiKey: API key. Pass `""` for llama.cpp and other unauthenticated servers.
    ///   - endpoint: Full URL including path. Defaults to OpenAI's chat completions endpoint.
    ///   - streamUsage: Set `false` for servers that don't support `stream_options` (e.g. llama.cpp).
    ///   - id: Stable provider identifier. Defaults to `"openai"`.
    ///   - name: Display name. Defaults to `"OpenAI"`.
    public init(
        apiKey: String = "",
        endpoint: URL? = nil,
        streamUsage: Bool = true,
        id: String = "openai",
        name: String = "OpenAI",
        session: URLSession = .shared
    ) {
        self.id = id
        self.name = name
        self.session = session
        self.builder = OpenAIRequestBuilder(
            endpoint: endpoint ?? URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiKey: apiKey,
            streamUsage: streamUsage
        )
    }

    // MARK: - Streaming

    /// Starts a streaming chat request and emits normalized stream events.
    ///
    /// - Parameters:
    ///   - messages: Ordered conversation history.
    ///   - model: Provider model identifier.
    ///   - options: Request options mapped into OpenAI-compatible fields.
    /// - Returns: An event stream for text, tool calls, usage, and completion.
    public func stream(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try builder.buildRequest(messages: messages, model: model, options: options, stream: true)
                    let (bytes, response) = try await session.bytes(for: request)
                    try validateResponse(response)

                    let sseEvents = SSEParser.events(from: SSEParser.lines(from: bytes))
                    let chatEvents = OpenAIStreamProcessor.process(events: sseEvents)

                    for try await event in chatEvents {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ChatError.cancelled)
                } catch let e as ChatError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: ChatError.networkError(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Non-streaming

    /// Executes a non-streaming chat completion request.
    ///
    /// - Parameters:
    ///   - messages: Ordered conversation history.
    ///   - model: Provider model identifier.
    ///   - options: Request options mapped into OpenAI-compatible fields.
    /// - Returns: A normalized completion result.
    /// - Throws: `ChatError` when request, decoding, or API validation fails.
    public func complete(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult {
        let request = try builder.buildRequest(messages: messages, model: model, options: options, stream: false)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)

        // Surface API-level errors
        if let errResp = try? JSONDecoder().decode(OAIErrorResponse.self, from: data) {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ChatError.serverError(statusCode: code, message: errResp.error.message)
        }

        let decoded: OAIResponse
        do { decoded = try JSONDecoder().decode(OAIResponse.self, from: data) }
        catch { throw ChatError.decodingError(error) }

        guard let choice = decoded.choices.first else {
            throw ChatError.streamError("Empty choices array in response")
        }

        var contentBlocks: [ChatMessage.ContentBlock] = []
        if let text = choice.message.content { contentBlocks.append(.text(text)) }
        if let reasoning = choice.message.reasoningContent { contentBlocks.append(.thinking(.init(text: reasoning))) }

        let toolCalls = choice.message.toolCalls?.map {
            ChatMessage.ToolCallBlock(id: $0.id, name: $0.function.name, arguments: $0.function.arguments)
        }

        let message = ChatMessage(
            role: .assistant,
            content: contentBlocks,
            toolCalls: toolCalls
        )

        let usage = decoded.usage.flatMap { u -> TokenUsage? in
            guard let p = u.promptTokens, let c = u.completionTokens, let t = u.totalTokens else { return nil }
            return TokenUsage(promptTokens: p, completionTokens: c, totalTokens: t)
        }

        return ChatCompletionResult(
            id: decoded.id,
            model: decoded.model,
            message: message,
            usage: usage,
            finishReason: finishReason(from: choice.finishReason)
        )
    }

    // MARK: - Helpers

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard 200...299 ~= http.statusCode else {
            throw ChatError.serverError(statusCode: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }

    private func finishReason(from raw: String?) -> ChatCompletionResult.FinishReason {
        switch raw {
        case "stop":           return .stop
        case "length":         return .length
        case "tool_calls":     return .toolCalls
        case "content_filter": return .contentFilter
        case let r?:           return .unknown(r)
        default:               return .stop
        }
    }
}
