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

    /// Stable provider identifier used by host applications.
    public let id   = "foundation-models"
    /// Human-readable provider name for settings and UI.
    public let name = "Apple Intelligence"

    private let model: SystemLanguageModel
    private let generationOptions: GenerationOptions
    /// Tools available to the session, via Apple's own `Tool` protocol — a fundamentally different
    /// mechanism from `ChatRequestOptions.tools`/`ChatStreamEvent.toolCallComplete` (the
    /// provider-agnostic shape `MLXProvider` uses): a `LanguageModelSession` constructed with
    /// `tools:` calls them automatically and transparently during `streamResponse`/`respond`, so
    /// `stream(...)`/`performStream(...)` below need no tool-call event handling of their own —
    /// the streamed text already reflects whatever the model learned from any tool calls it made.
    /// Empty by default so every existing caller (which never passed this) is unaffected.
    private let tools: [any Tool]

    /// - Parameters:
    ///   - model: The on-device model. Defaults to `SystemLanguageModel.default`.
    ///   - generationOptions: Token sampling options. Defaults to `GenerationOptions()`.
    ///   - tools: `Tool`-conforming types this session may call during generation. Empty by
    ///     default. See this property's own doc comment for how this differs from
    ///     `ChatRequestOptions.tools`.
    public init(
        model: SystemLanguageModel = .default,
        generationOptions: GenerationOptions = GenerationOptions(),
        tools: [any Tool] = []
    ) {
        self.model = model
        self.generationOptions = generationOptions
        self.tools = tools
    }

    // MARK: - ChatProvider

    /// Starts a streaming response using Apple Foundation Models.
    ///
    /// - Parameters:
    ///   - messages: Ordered conversation history.
    ///   - model: Unused for this provider; included for `ChatProvider` conformance.
    ///   - options: Shared request options. `systemPrompt` is mapped into transcript instructions.
    /// - Returns: An async stream of normalized chat events.
    public func stream(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let llmModel     = self.model
        let genOptions   = self.generationOptions
        let systemPrompt = options.systemPrompt
        let sessionTools = self.tools

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

                    let session = LanguageModelSession(model: llmModel, tools: sessionTools, transcript: transcript)

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
                    // NOTE: PrivateCloudComputeLanguageModel exists in the compiled FoundationModels.tbd
                    // but is NOT exposed in the public `.swiftinterface` for macOS (verified against Xcode 26.5 SDK).
                    // It is private/unexposed API and must not be called via any workaround (e.g., @_silgen_name).
                    // Future escalation to PCC (32k context) remains possible once Apple makes it part of the
                    // public Swift interface. Check the next major Xcode/SDK release for changes.
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Executes a non-streaming completion by collecting streamed text deltas.
    ///
    /// - Parameters:
    ///   - messages: Ordered conversation history.
    ///   - model: Unused for this provider; included for protocol conformance.
    ///   - options: Shared request options.
    /// - Returns: A normalized completion result.
    /// - Throws: Generation or cancellation errors from Foundation Models APIs.
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
            let (delta, newPosition) = nextDelta(fullText: snapshot.content, position: position)
            if !delta.isEmpty {
                continuation.yield(.text(delta))
            }
            position = newPosition
        }
        continuation.yield(.done)
        continuation.finish()
    }

    /// Computes the unseen suffix of a cumulative snapshot given the last-seen end index.
    /// Pure diffing logic extracted from `performStream` so it's unit-testable without a live
    /// `LanguageModelSession` — every call site is exercised on real hardware, but this shape
    /// (cumulative-snapshot-to-delta) is exactly what a fixture string can verify offline.
    static func nextDelta(
        fullText: String,
        position: String.Index?
    ) -> (delta: String, newPosition: String.Index) {
        let start = position ?? fullText.startIndex
        return (String(fullText[start...]), fullText.endIndex)
    }

    // MARK: - Transcript construction

    /// Not `private` so `AIChatFoundationModelsTests` can verify role mapping and dropped-role
    /// behavior (`@testable import`) without needing a live Apple Intelligence session.
    static func buildTranscript(
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
    static func transcriptEntry(
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

    static func extractText(from message: ChatMessage) -> String? {
        let parts = message.content.compactMap { block -> String? in
            guard case .text(let t) = block else { return nil }
            return t
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
