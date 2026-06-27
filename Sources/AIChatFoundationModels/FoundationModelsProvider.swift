import Foundation
import AIChatCore
import FoundationModels

/// ChatProvider backed by Apple's on-device Foundation Models framework (Apple Intelligence).
///
/// Requires macOS 26.0+ or iOS 26.0+ with Apple Intelligence enabled on the device.
/// Check `SystemLanguageModel.default.availability` before instantiating.
///
/// Throws LanguageModelSession.GenerationError.exceededContextWindowSize when the conversation
/// exceeds the model's context window. Callers should catch this and summarize/truncate history.
@available(macOS 26.0, iOS 26.0, *)
public struct FoundationModelsProvider: ChatProvider {

    public let id   = "foundation-models"
    public let name = "Apple Intelligence"

    private let model: SystemLanguageModel
    private let generationOptions: GenerationOptions

    /// - Parameters:
    ///   - model: The on-device model. Defaults to `SystemLanguageModel.default`.
    ///   - generationOptions: Token sampling options. Defaults to `GenerationOptions()`.
    public init(
        model: SystemLanguageModel = .default,
        generationOptions: GenerationOptions = GenerationOptions()
    ) {
        self.model = model
        self.generationOptions = generationOptions
    }

    // MARK: - ChatProvider

    public func stream(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let llmModel     = self.model
        let genOptions   = self.generationOptions
        let systemPrompt = options.systemPrompt

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    guard
                        let lastUserMessage = messages.last(where: { $0.role == .user }),
                        let lastUserText    = Self.extractText(from: lastUserMessage)
                    else {
                        continuation.finish()
                        return
                    }

                    let transcript = Self.buildTranscript(
                        from: messages.dropLast(),
                        options: genOptions,
                        systemPrompt: systemPrompt
                    )

                    let session = LanguageModelSession(model: llmModel, transcript: transcript)

                    try await Self.performStream(
                        session: session,
                        prompt: lastUserText,
                        genOptions: genOptions,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    continuation.finish(throwing: ChatError.cancelled)
                } catch {
                    // LanguageModelSession.GenerationError.exceededContextWindowSize is handled
                    // by the caller (AlricChatEngine) — it switches to MLXProvider with progress UI.
                    // TODO: when PrivateCloudComputeLanguageModel ships in a public SDK build,
                    //       catch exceededContextWindowSize here and escalate to PCC (32k context)
                    //       before falling back to MLX. Check pcc.isAvailable before each call.
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func complete(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult {
        var fullText = ""
        for try await event in stream(messages: messages, model: model, options: options) {
            if case .text(let delta) = event { fullText += delta }
        }
        return ChatCompletionResult(
            id: nil,
            model: "apple-intelligence",
            message: ChatMessage(role: .assistant, content: fullText),
            usage: nil,
            finishReason: .stop
        )
    }

    // MARK: - Stream helper

    /// Drives a ResponseStream, emitting deltas, then `.done`, then finishing the continuation.
    /// Extracted so both on-device and PCC paths share identical streaming logic.
    private static func performStream(
        session: LanguageModelSession,
        prompt: String,
        genOptions: GenerationOptions,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        // ResponseStream<String> yields cumulative snapshots (not deltas).
        // Track the previous end index and emit only the new suffix each turn.
        var position: String.Index?
        for try await snapshot in session.streamResponse(to: Prompt(prompt), options: genOptions) {
            try Task.checkCancellation()
            let start = position ?? snapshot.content.startIndex
            let delta = String(snapshot.content[start...])
            if !delta.isEmpty {
                continuation.yield(.text(delta))
            }
            position = snapshot.content.endIndex
        }
        continuation.yield(.done)
        continuation.finish()
    }

    // MARK: - Transcript construction

    private static func buildTranscript(
        from messages: some Collection<ChatMessage>,
        options: GenerationOptions,
        systemPrompt: String?
    ) -> Transcript {
        var entries: [Transcript.Entry] = []

        if let sys = systemPrompt, let entry = transcriptEntry(role: "system", content: sys, options: options) {
            entries.append(entry)
        }

        for message in messages {
            guard
                let text  = extractText(from: message),
                let entry = transcriptEntry(role: message.role.rawValue, content: text, options: options)
            else { continue }
            entries.append(entry)
        }

        return Transcript(entries: entries)
    }

    /// Maps a role/content pair to the appropriate `Transcript.Entry` variant.
    /// Returns `nil` for roles that have no FoundationModels equivalent (e.g. `.tool`).
    private static func transcriptEntry(
        role: String,
        content: String,
        options: GenerationOptions
    ) -> Transcript.Entry? {
        switch role {
        case "system":
            return .instructions(.init(
                segments: [.text(.init(content: content))],
                toolDefinitions: []
            ))
        case "user":
            return .prompt(.init(
                segments: [.text(.init(content: content))],
                options: options
            ))
        case "assistant":
            return .response(.init(
                assetIDs: [],
                segments: [.text(.init(content: content))]
            ))
        default:
            return nil
        }
    }

    private static func extractText(from message: ChatMessage) -> String? {
        let parts = message.content.compactMap { block -> String? in
            guard case .text(let t) = block else { return nil }
            return t
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
