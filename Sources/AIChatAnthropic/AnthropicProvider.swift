import Foundation
import AIChatCore

/// ChatProvider for the Anthropic Messages API. Supports extended thinking and tool use.
public struct AnthropicProvider: ChatProvider {
    /// Stable provider identifier used by host applications.
    public let id: String
    /// Human-readable provider name for settings and UI.
    public let name: String

    private let builder: AnthropicRequestBuilder
    private let session: URLSession

    /// Creates an Anthropic Messages API provider.
    ///
    /// - Parameters:
    ///   - apiKey: Anthropic API key sent as `x-api-key`.
    ///   - endpoint: Optional endpoint override for proxies or compatible gateways.
    ///   - id: Stable provider identifier.
    ///   - name: Display name for UI surfaces.
    ///   - session: URL session used to execute HTTP requests.
    public init(
        apiKey: String,
        endpoint: URL? = nil,
        id: String = "anthropic",
        name: String = "Anthropic",
        session: URLSession = .shared
    ) {
        self.id = id
        self.name = name
        self.session = session
        self.builder = AnthropicRequestBuilder(apiKey: apiKey, endpoint: endpoint)
    }

    // MARK: - Streaming

    /// Starts a streaming Anthropic message request.
    ///
    /// - Parameters:
    ///   - messages: Ordered conversation history.
    ///   - model: Anthropic model identifier.
    ///   - options: Shared request options.
    /// - Returns: An async stream of normalized chat events.
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

                    // For non-2xx responses, buffer the body to extract the Anthropic error message.
                    if let http = response as? HTTPURLResponse, !(200...299 ~= http.statusCode) {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 8192 { break }
                        }
                        let msg = Self.parseErrorBody(data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                        throw ChatError.serverError(statusCode: http.statusCode, message: msg)
                    }

                    // AsyncLineSequence (bytes.lines) silently drops blank lines, which breaks SSE
                    // framing — both OpenAI and Anthropic use blank lines as event delimiters.
                    let sseLines   = SSEParser.lines(from: bytes)
                    let sseEvents  = SSEParser.events(from: sseLines)
                    let chatEvents = AnthropicStreamProcessor.process(events: sseEvents)

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

    /// Executes a non-streaming Anthropic message request.
    ///
    /// - Parameters:
    ///   - messages: Ordered conversation history.
    ///   - model: Anthropic model identifier.
    ///   - options: Shared request options.
    /// - Returns: A normalized completion result.
    /// - Throws: `ChatError` for transport, API, or decoding failures.
    public func complete(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult {
        let request = try builder.buildRequest(messages: messages, model: model, options: options, stream: false)
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299 ~= http.statusCode) {
            let msg = Self.parseErrorBody(data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ChatError.serverError(statusCode: http.statusCode, message: msg)
        }

        let decoded: AnthropicResponse
        do { decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data) }
        catch { throw ChatError.decodingError(error) }

        var contentBlocks: [ChatMessage.ContentBlock] = []
        var toolCalls: [ChatMessage.ToolCallBlock] = []

        for block in decoded.content {
            switch block.type {
            case "text":
                if let t = block.text { contentBlocks.append(.text(t)) }
            case "thinking":
                if let t = block.thinking {
                    contentBlocks.append(.thinking(.init(text: t, signature: block.signature)))
                }
            case "redacted_thinking":
                if let d = block.data { contentBlocks.append(.redactedThinking(d)) }
            case "tool_use":
                if let id = block.id, let name = block.name {
                    let args: String
                    if let input = block.input, let data = try? JSONEncoder().encode(input),
                       let str = String(data: data, encoding: .utf8) {
                        args = str
                    } else {
                        args = "{}"
                    }
                    toolCalls.append(ChatMessage.ToolCallBlock(id: id, name: name, arguments: args))
                }
            default:
                break
            }
        }

        let message = ChatMessage(
            role: .assistant,
            content: contentBlocks,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )

        let usage = decoded.usage.flatMap { u -> TokenUsage? in
            guard let input = u.inputTokens, let output = u.outputTokens else { return nil }
            return TokenUsage(promptTokens: input, completionTokens: output, totalTokens: input + output)
        }

        return ChatCompletionResult(
            id: decoded.id,
            model: decoded.model,
            message: message,
            usage: usage,
            finishReason: finishReason(from: decoded.stopReason)
        )
    }

    // MARK: - Helpers

    /// Extracts the `error.message` string from an Anthropic error body, e.g.:
    /// `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`
    static func parseErrorBody(_ data: Data) -> String? {
        struct Body: Decodable {
            struct Inner: Decodable { let message: String }
            let error: Inner
        }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error.message
    }

    private func finishReason(from raw: String?) -> ChatCompletionResult.FinishReason {
        switch raw {
        case "end_turn":   return .stop
        case "max_tokens": return .length
        case "tool_use":   return .toolCalls
        case let r?:       return .unknown(r)
        default:           return .stop
        }
    }
}
