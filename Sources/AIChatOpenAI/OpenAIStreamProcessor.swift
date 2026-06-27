import Foundation
import AIChatCore

/// Converts a stream of SSE events from an OpenAI-compatible endpoint into `ChatStreamEvent` values.
public struct OpenAIStreamProcessor {

    /// Converts OpenAI SSE payloads into normalized `ChatStreamEvent` values.
    ///
    /// - Parameter events: SSE events emitted by `SSEParser.events(from:)`.
    /// - Returns: An async stream of normalized chat events.
    public static func process<S: AsyncSequence & Sendable>(
        events: S
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> where S.Element == SSEParser.Event {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Accumulate tool call fragments keyed by index
                var toolAccumulators: [Int: ToolAccumulator] = [:]

                do {
                    for try await event in events {
                        try Task.checkCancellation()

                        guard let data = event.data.data(using: .utf8) else { continue }

                        // Attempt to decode as error first
                        if let errorResp = try? JSONDecoder().decode(OAIErrorResponse.self, from: data) {
                            throw ChatError.serverError(statusCode: 0, message: errorResp.error.message)
                        }

                        let chunk: OAIChunk
                        do {
                            chunk = try JSONDecoder().decode(OAIChunk.self, from: data)
                        } catch {
                            throw ChatError.decodingError(error)
                        }

                        // Usage chunk (can appear on its own in the final message)
                        if let usage = chunk.usage,
                           let prompt = usage.promptTokens,
                           let completion = usage.completionTokens,
                           let total = usage.totalTokens {
                            continuation.yield(.usage(TokenUsage(
                                promptTokens: prompt,
                                completionTokens: completion,
                                totalTokens: total
                            )))
                        }

                        for choice in chunk.choices ?? [] {
                            let delta = choice.delta

                            // Text content
                            if let text = delta.content, !text.isEmpty {
                                continuation.yield(.text(text))
                            }

                            // Reasoning content (DeepSeek, QwQ, etc.)
                            if let reasoning = delta.reasoningContent, !reasoning.isEmpty {
                                continuation.yield(.reasoning(reasoning))
                            }

                            // Tool call deltas
                            for tcDelta in delta.toolCalls ?? [] {
                                let idx = tcDelta.index
                                var acc = toolAccumulators[idx] ?? ToolAccumulator()
                                if let id   = tcDelta.id               { acc.id   = id }
                                if let name = tcDelta.function?.name   { acc.name = name }
                                if let args = tcDelta.function?.arguments { acc.arguments += args }
                                toolAccumulators[idx] = acc
                            }

                            // Finalise tool calls on finish_reason
                            if let reason = choice.finishReason, reason == "tool_calls" {
                                for (_, acc) in toolAccumulators.sorted(by: { $0.key < $1.key }) {
                                    continuation.yield(.toolCallComplete(
                                        id: acc.id,
                                        name: acc.name,
                                        arguments: acc.arguments
                                    ))
                                }
                                toolAccumulators = [:]
                            }
                        }
                    }

                    // Flush any remaining tool calls (some servers omit finish_reason:"tool_calls")
                    for (_, acc) in toolAccumulators.sorted(by: { $0.key < $1.key }) where !acc.name.isEmpty {
                        continuation.yield(.toolCallComplete(id: acc.id, name: acc.name, arguments: acc.arguments))
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

    private struct ToolAccumulator {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }
}
