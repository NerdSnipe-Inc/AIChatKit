import Foundation
import AIChatCore

/// Converts Anthropic streaming SSE payloads into normalized `ChatStreamEvent` values.
public struct AnthropicStreamProcessor {

    /// Processes Anthropic SSE events into AIChatKit stream events.
    ///
    /// - Parameter events: SSE events emitted by `SSEParser.events(from:)`.
    /// - Returns: An async stream of normalized chat events.
    public static func process<S: AsyncSequence & Sendable>(
        events: S
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> where S.Element == SSEParser.Event {
        AsyncThrowingStream { continuation in
            let task = Task {
                var currentBlockType: String? = nil
                var currentToolId: String? = nil
                var currentToolName: String? = nil
                var toolArguments = ""
                var thinkingText = ""
                var thinkingSignature = ""

                do {
                    for try await event in events {
                        try Task.checkCancellation()

                        guard let data = event.data.data(using: .utf8) else { continue }
                        let payload: AnthropicStreamEvent
                        do { payload = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data) }
                        catch { throw ChatError.decodingError(error) }

                        switch payload.type {

                        case "content_block_start":
                            guard let block = payload.contentBlock else { break }
                            currentBlockType = block.type
                            switch block.type {
                            case "tool_use":
                                currentToolId = block.id
                                currentToolName = block.name
                                toolArguments = ""
                            case "thinking":
                                thinkingText = block.thinking ?? ""
                                thinkingSignature = ""
                                if let initial = block.thinking, !initial.isEmpty {
                                    continuation.yield(.reasoning(initial))
                                }
                            case "redacted_thinking":
                                if let encryptedData = block.data {
                                    continuation.yield(.redactedThinking(data: encryptedData))
                                }
                            default:
                                break
                            }

                        case "content_block_delta":
                            guard let delta = payload.delta else { break }
                            switch delta.type {
                            case "text_delta":
                                if let text = delta.text, !text.isEmpty {
                                    continuation.yield(.text(text))
                                }
                            case "thinking_delta":
                                if let thinking = delta.thinking, !thinking.isEmpty {
                                    continuation.yield(.reasoning(thinking))
                                    thinkingText += thinking
                                }
                            case "signature_delta":
                                if let sig = delta.signature { thinkingSignature += sig }
                            case "input_json_delta":
                                if let partial = delta.partialJson { toolArguments += partial }
                            default:
                                break
                            }

                        case "content_block_stop":
                            switch currentBlockType {
                            case "tool_use":
                                if let name = currentToolName {
                                    continuation.yield(.toolCallComplete(
                                        id: currentToolId ?? "",
                                        name: name,
                                        arguments: toolArguments
                                    ))
                                }
                                currentToolId = nil; currentToolName = nil; toolArguments = ""
                            case "thinking":
                                if !thinkingSignature.isEmpty {
                                    continuation.yield(.thinkingBlockComplete(
                                        thinking: thinkingText,
                                        signature: thinkingSignature
                                    ))
                                }
                                thinkingText = ""; thinkingSignature = ""
                            default:
                                break
                            }
                            currentBlockType = nil

                        case "message_delta":
                            if let delta = payload.delta,
                               let usage = (delta as AnyObject) as? AnthropicStreamEvent.Delta {
                                _ = usage // usage tracked separately if needed
                            }

                        case "error":
                            let msg = payload.error?.message ?? "Unknown Anthropic API error"
                            throw ChatError.serverError(statusCode: 0, message: "Anthropic API error: \(msg)")

                        default:
                            break
                        }
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
}
