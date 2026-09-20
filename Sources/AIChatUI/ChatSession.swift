import Foundation
import AIChatCore
import SwiftUI

/// The ViewModel for a conversation. Owns the provider, history, and all display state.
/// Drop one into your view with `@StateObject` and wire it to `ChatView`.
@MainActor
public final class ChatSession: ObservableObject {

    // MARK: - Public state

    /// Display entries rendered by `ConversationView`.
    @Published public var entries: [Entry] = []
    /// Indicates whether the session is currently generating a response.
    @Published public var isGenerating: Bool = false
    /// Last surfaced error for inline/banner presentation.
    @Published public var error: Error? = nil

    // MARK: - Configuration

    /// Provider implementation handling requests for this session.
    public var provider: any ChatProvider
    /// Active model identifier passed to `provider`.
    public var model: String
    /// Request options used for each generation.
    public var options: ChatRequestOptions

    // MARK: - Private state

    private var history: [ChatMessage] = []
    private var streamTask: Task<Void, Never>?
    private var textEmitter: BalancedEmitter?

    // IDs of entries in the current generation pass
    private var activeReasoningId: UUID?
    private var activeAIId: UUID?
    private var reasoningStart: Date?
    // Incremented on every startGeneration; lets finishGeneration detect if it was superseded.
    private var generationID: Int = 0
    /// True from `startGeneration` until the provider stream ends (or `cancel()`).
    private var isStreamActive = false
    /// Full text streamed this turn (authoritative; the entry text is paced by the emitter).
    private var rawText = ""
    /// Tool calls emitted this turn, committed to history with the assistant text.
    private var pendingToolCalls: [ChatMessage.ToolCallBlock] = []
    /// Tool results submitted by the host while the stream was still running.
    private var pendingToolResults: [ChatMessage] = []

    /// Creates a chat session view model.
    ///
    /// - Parameters:
    ///   - provider: Backend provider implementation.
    ///   - model: Model identifier understood by `provider`.
    ///   - options: Shared request options for generation.
    public init(
        provider: any ChatProvider,
        model: String,
        options: ChatRequestOptions = ChatRequestOptions()
    ) {
        self.provider = provider
        self.model = model
        self.options = options
    }

    // MARK: - Public API

    /// Optional retrieval context injected ahead of a user message.
    public struct KnowledgeRetrievalInjection: Sendable {
        /// User query or retrieval label shown in UI.
        public let query: String
        /// Retrieved context body injected into provider history.
        public let body: String
        /// Creates retrieval context injected with a user message.
        ///
        /// - Parameters:
        ///   - query: Retrieval query or label.
        ///   - body: Retrieved knowledge text.
        public init(query: String, body: String) {
            self.query = query
            self.body = body
        }
    }

    /// Sends a user message and starts generation.
    ///
    /// When `knowledge` is provided, retrieved context is rendered as a separate
    /// entry and prepended to the provider-facing user message payload.
    ///
    /// The message is ignored (and `false` returned) when it is empty/whitespace-only or
    /// when the session is busy — either streaming a reply or waiting for the host to
    /// answer pending tool calls. See `docs/CHAT_SESSION_BEHAVIOUR.md`.
    ///
    /// - Parameters:
    ///   - text: User-authored message text.
    ///   - knowledge: Optional retrieval context to inject.
    /// - Returns: `true` when the message was accepted and generation started.
    @discardableResult
    public func send(_ text: String, knowledge: KnowledgeRetrievalInjection? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isGenerating else { return false }

        let userId = UUID()
        entries.append(.userMessage(UserEntry(id: userId, text: trimmed)))

        if let knowledge, !knowledge.body.isEmpty {
            entries.append(.knowledgeRetrieval(KnowledgeRetrievalEntry(
                id: UUID(),
                query: knowledge.query,
                body: knowledge.body
            )))
            let augmented = """
            ## Retrieved Knowledge (automatic)

            \(knowledge.body)

            ## User Message

            \(trimmed)
            """
            history.append(ChatMessage(id: userId, role: .user, content: augmented))
        } else {
            history.append(ChatMessage(id: userId, role: .user, content: trimmed))
        }

        startGeneration()
        return true
    }

    /// Programmatic tool call when the harness must execute a tool the model planned but did not emit.
    ///
    /// - Parameters:
    ///   - name: Tool/function name.
    ///   - arguments: JSON-like argument payload to normalize and store.
    public func requestToolCall(name: String, arguments: String) {
        guard !isGenerating else { return }
        let id = UUID().uuidString
        let normalized = GemmaToolArguments.normalize(arguments)
        addToolCallEntry(id: id, name: name, arguments: normalized)
        appendAssistantToolCall(id: id, name: name, arguments: historyArguments(normalized))
    }

    /// `true` when the model has finished streaming and one or more tool calls are waiting
    /// for the host to call ``submitToolResult(toolCallId:content:isError:)``.
    public var isAwaitingToolResults: Bool {
        !isStreamActive && hasRunningToolCalls
    }

    /// Records a tool result and, once every pending tool call of the turn has been answered,
    /// continues the conversation so the model can use the results.
    ///
    /// Safe to call as soon as a `.toolCall` entry appears, even while the model is still
    /// streaming: the result is queued and applied when the stream ends. With several parallel
    /// tool calls the model is only re-invoked after the last one is answered. Results for
    /// unknown or already-answered tool call ids are ignored and reported through ``error``.
    ///
    /// - Parameters:
    ///   - toolCallId: Identifier for the pending tool call.
    ///   - content: Tool output content. Empty output is replaced by a placeholder because
    ///     some chat templates drop empty tool messages.
    ///   - isError: Marks the tool call as failed when `true`.
    public func submitToolResult(toolCallId: String, content: String, isError: Bool = false) {
        guard runningToolCall(id: toolCallId) != nil else {
            error = ChatSessionError.unknownToolCall(id: toolCallId)
            return
        }
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (isError ? "Tool failed with no output." : "(tool returned no output)")
            : content
        updateToolCallStatus(id: toolCallId, status: isError ? .failed : .succeeded, result: body)
        let msg = ChatMessage(toolCallId: toolCallId, content: body)
        if isStreamActive {
            // The assistant turn that issued this call hasn't been committed to history yet.
            pendingToolResults.append(msg)
            return
        }
        history.append(msg)
        if !hasRunningToolCalls { startGeneration() }
    }

    /// Cancels any active generation and tool wait, leaving the session idle and reusable.
    ///
    /// Whatever the model streamed so far stays visible (its rows stop animating) and is kept in
    /// the provider history so the next turn stays coherent. Tool calls that were still pending
    /// are marked failed with a "cancelled" result.
    public func cancel() {
        let wasActive = isStreamActive || isGenerating
        guard wasActive else { return }
        streamTask?.cancel()
        streamTask = nil
        generationID &+= 1          // orphan the old task's late callbacks
        textEmitter = nil
        isStreamActive = false
        finaliseStreamedEntries()
        commitAssistantTurn()
        pendingToolResults.removeAll()
        failRunningToolCalls(reason: "Cancelled by user.")
        discardUnansweredUserTurn()
        removeActivity()
        isGenerating = false
        ChatLog.info(.core, "session cancelled")
    }

    /// Toggles expansion for a knowledge-retrieval entry.
    ///
    /// - Parameter id: Identifier for the target retrieval entry.
    public func toggleKnowledgeRetrieval(id: UUID) {
        for i in entries.indices {
            if case .knowledgeRetrieval(var e) = entries[i], e.id == id {
                e.isExpanded.toggle()
                entries[i] = .knowledgeRetrieval(e)
                return
            }
        }
    }

    /// Toggles expansion for a reasoning/thinking entry.
    ///
    /// - Parameter id: Identifier for the target reasoning entry.
    public func toggleThinking(id: UUID) {
        for i in entries.indices {
            if case .reasoning(var e) = entries[i], e.id == id {
                e.isExpanded.toggle()
                entries[i] = .reasoning(e)
                return
            }
        }
    }

    /// Clears conversation entries and provider history. Ignored while the model is streaming;
    /// allowed while merely waiting on tool results (pending calls are discarded).
    public func clearHistory() {
        guard !isStreamActive else { return }
        streamTask?.cancel()
        streamTask = nil
        generationID &+= 1
        isGenerating = false
        resetTurnState()
        error = nil
        entries = []
        history = []
    }

    /// Restore a persisted conversation into both display entries and provider history.
    ///
    /// - Parameters:
    ///   - entries: Display entries to restore.
    ///   - history: Provider-facing message history to restore.
    public func loadSnapshot(entries: [Entry], history: [ChatMessage]) {
        streamTask?.cancel()
        streamTask = nil
        generationID &+= 1
        isGenerating = false
        isStreamActive = false
        error = nil
        resetTurnState()
        textEmitter = nil
        self.entries = entries
        self.history = history
    }

    // MARK: - Private: generation lifecycle

    private func resetTurnState() {
        activeReasoningId = nil
        activeAIId = nil
        reasoningStart = nil
        rawText = ""
        pendingToolCalls = []
        pendingToolResults = []
        isStreamActive = false
    }

    private func startGeneration() {
        // Cancel any in-flight stream before starting a new one.
        streamTask?.cancel()
        streamTask = nil

        generationID &+= 1
        let myGenerationID = generationID

        isGenerating = true
        error = nil
        resetTurnState()
        isStreamActive = true

        let activityId = UUID()
        entries.append(.activity(ActivityEntry(id: activityId, text: "Thinking…")))

        let emitter = BalancedEmitter(duration: 1.0, frequency: 30) { [weak self] chunk in
            Task { @MainActor [weak self] in
                // Drop chunks from a superseded/cancelled generation so they can't leak
                // into the next reply's entry.
                guard let self, self.generationID == myGenerationID else { return }
                self.appendToActiveAI(chunk)
            }
        }
        textEmitter = emitter

        let snapHistory = history
        let provider = provider
        let model = model
        let options = options

        streamTask = Task.detached { [weak self, emitter] in
            defer {
                Task { @MainActor [weak self] in
                    await self?.finishGeneration(emitter: emitter, generationID: myGenerationID)
                }
            }

            do {
                let stream = provider.stream(messages: snapHistory, model: model, options: options)
                for try await event in stream {
                    try Task.checkCancellation()
                    await MainActor.run { [weak self] in
                        guard let self, self.generationID == myGenerationID else { return }
                        self.handle(event)
                    }
                    // Feed text through balanced emitter on each text event
                    if case .text(let t) = event {
                        await emitter.add(t)
                    }
                }
                await emitter.wait()
            } catch is CancellationError {
                await emitter.cancel()
            } catch {
                await emitter.cancel()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Only store error if this generation wasn't superseded
                    if self.generationID == myGenerationID {
                        ChatLog.error(.core, "stream failed: \(error.localizedDescription)")
                        self.error = error
                    }
                }
            }
        }
    }

    private func handle(_ event: ChatStreamEvent) {
        switch event {
        case .text(let t):
            // Display delivery is paced by the BalancedEmitter callback; `rawText` is the
            // authoritative full text (used to finalise the entry, recover tool calls, and
            // build history) so a slow emitter can never truncate what we commit.
            removeActivity()
            ensureAIEntry()
            rawText += t

        case .reasoning(let delta):
            removeActivity()
            ensureReasoningEntry()
            appendToActiveReasoning(delta)

        case .thinkingBlockComplete(let thinking, let signature):
            // Store the complete thinking block in history so it can be round-tripped to Anthropic
            finaliseThinkingBlock(thinking: thinking, signature: signature)

        case .redactedThinking(let data):
            appendRedactedThinking(data: data)

        case .toolCallComplete(let id, let name, let args):
            removeActivity()
            let normalized = GemmaToolArguments.normalize(args)
            addToolCallEntry(id: id, name: name, arguments: normalized)
            pendingToolCalls.append(.init(id: id, name: name, arguments: historyArguments(normalized)))

        case .usage:
            break

        case .done:
            break
        }
    }

    private func finishGeneration(emitter: BalancedEmitter, generationID: Int) async {
        await emitter.wait()
        await MainActor.run { [weak self] in
            guard let self else { return }
            // Superseded or cancelled: `cancel()` already finalised everything.
            guard self.generationID == generationID else { return }
            self.completeTurn()
        }
    }

    /// Finalises the just-finished stream: entries, history commit, error/empty-response
    /// surfacing, and (when every pending tool call was already answered) auto-continuation.
    private func completeTurn() {
        isStreamActive = false
        streamTask = nil
        textEmitter = nil

        finaliseStreamedEntries()
        // Recover tool calls the model wrote as <tool_call> text (LoRA / training artifact).
        if let aid = activeAIId { recoverEmbeddedToolCalls(fromAIEntryId: aid) }
        removeActivity()

        let hasText = !rawTextCleaned.isEmpty
        let hasReasoning = reasoningText?.isEmpty == false
        let hasToolCalls = !pendingToolCalls.isEmpty

        // A whitespace-only reply is not a reply: drop the empty bubble.
        if !hasText, let aid = activeAIId {
            entries.removeAll { if case .aiMessage(let e) = $0 { return e.id == aid } else { return false } }
            activeAIId = nil
        }

        commitAssistantTurn()

        if let err = error {
            let msg = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            var line = "⚠️ \(msg)"
            if let suggestion = (err as? LocalizedError)?.recoverySuggestion, !suggestion.isEmpty {
                line += " \(suggestion)"
            }
            entries.append(.activity(ActivityEntry(id: UUID(), text: line, isError: true)))
        } else if !hasText && !hasToolCalls {
            if hasReasoning {
                ChatLog.warning(.core, "model produced reasoning but no answer")
                entries.append(.activity(ActivityEntry(
                    id: UUID(),
                    text: "⚠️ The model finished thinking without writing an answer (it may have hit the token limit). Try again, or raise the max-token setting.",
                    isError: true
                )))
            } else {
                entries.append(.activity(ActivityEntry(id: UUID(), text: "⚠️ \(provider.zeroResponseMessage)", isError: true)))
            }
        }

        // Apply tool results the host submitted while we were still streaming.
        if !pendingToolResults.isEmpty {
            history.append(contentsOf: pendingToolResults)
            pendingToolResults = []
        }

        if hasRunningToolCalls {
            isGenerating = true          // waiting for the host's submitToolResult
        } else if error == nil, hasToolCalls {
            startGeneration()            // every call was answered during streaming
        } else {
            isGenerating = false
        }
    }

    // MARK: - Entry management helpers

    private var hasRunningToolCalls: Bool {
        entries.contains { if case .toolCall(let e) = $0 { return e.status == .running } else { return false } }
    }

    private func runningToolCall(id: String) -> ToolCallEntry? {
        for entry in entries { if case .toolCall(let e) = entry, e.id == id, e.status == .running { return e } }
        return nil
    }

    private var rawTextCleaned: String { rawText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var reasoningText: String? {
        guard let rid = activeReasoningId else { return nil }
        for entry in entries { if case .reasoning(let e) = entry, e.id == rid { return e.text } }
        return nil
    }

    /// Stops the streaming/thinking animations and makes the AI entry text authoritative.
    private func finaliseStreamedEntries() {
        if let rid = activeReasoningId { finaliseReasoningEntry(id: rid) }
        if let aid = activeAIId {
            for i in entries.indices {
                if case .aiMessage(var e) = entries[i], e.id == aid {
                    e.text = rawText
                    e.isStreaming = false
                    entries[i] = .aiMessage(e)
                    break
                }
            }
        }
    }

    /// Writes the current turn (thinking + text + any tool calls) to history as ONE assistant
    /// message. Tool calls and text share a message so providers that require
    /// `assistant(text, tool_calls) → tool(result)` ordering (OpenAI, Anthropic) stay valid.
    private func commitAssistantTurn() {
        var blocks: [ChatMessage.ContentBlock] = []
        if let thinking = reasoningText, !thinking.isEmpty {
            var sig: String?
            if let rid = activeReasoningId {
                for entry in entries { if case .reasoning(let e) = entry, e.id == rid { sig = e.thinkingSignature } }
            }
            blocks.append(.thinking(.init(text: thinking, signature: sig)))
        }
        let text = rawTextCleaned.isEmpty ? "" : rawText
        if !text.isEmpty { blocks.append(.text(text)) }
        let calls = pendingToolCalls
        pendingToolCalls = []
        rawText = ""
        guard !blocks.isEmpty || !calls.isEmpty else { return }
        history.append(ChatMessage(role: .assistant, content: blocks, toolCalls: calls.isEmpty ? nil : calls))
    }

    /// Cancelled before the model produced anything: the trailing user turn has no reply. Keeping it
    /// would make the next request two consecutive user turns, which strict chat templates (Gemma)
    /// reject or mishandle. The turn is dropped from provider history but stays in the transcript,
    /// marked `isCancelled`.
    private func discardUnansweredUserTurn() {
        guard let last = history.last, last.role == .user else { return }
        history.removeLast()
        for i in entries.indices {
            if case .userMessage(var u) = entries[i], u.id == last.id {
                u.isCancelled = true
                entries[i] = .userMessage(u)
                break
            }
        }
        ChatLog.info(.core, "dropped unanswered user turn from provider history after cancel")
    }

    /// Marks every running tool call failed and records a matching result in history so a
    /// later turn never sees a tool call without an answer.
    private func failRunningToolCalls(reason: String) {
        for i in entries.indices {
            if case .toolCall(var e) = entries[i], e.status == .running {
                e.status = .failed
                e.result = reason
                entries[i] = .toolCall(e)
                history.append(ChatMessage(toolCallId: e.id, content: reason))
            }
        }
    }

    @discardableResult
    private func recoverEmbeddedToolCalls(fromAIEntryId id: UUID) -> Bool {
        guard let idx = entries.indices.first(where: {
            if case .aiMessage(let e) = entries[$0], e.id == id { return true } else { return false }
        }), case .aiMessage(var e) = entries[idx] else { return false }

        let parsed = GemmaOutputRecovery.parse(from: e.text, toolSchemas: options.nativeToolSpecs)
        guard !parsed.calls.isEmpty else { return false }

        e.text = parsed.cleanedText
        e.isStreaming = false
        rawText = parsed.cleanedText
        if e.text.isEmpty {
            entries.remove(at: idx)
            activeAIId = nil
        } else {
            entries[idx] = .aiMessage(e)
        }

        for call in parsed.calls {
            let toolId = UUID().uuidString
            let normalized = GemmaToolArguments.normalize(call.arguments)
            addToolCallEntry(id: toolId, name: call.name, arguments: normalized)
            pendingToolCalls.append(.init(id: toolId, name: call.name, arguments: historyArguments(normalized)))
        }
        return true
    }

    private func ensureAIEntry() {
        guard activeAIId == nil else { return }
        let id = UUID()
        activeAIId = id
        entries.append(.aiMessage(AIEntry(id: id, text: "", isStreaming: true)))
    }

    private func ensureReasoningEntry() {
        guard activeReasoningId == nil else { return }
        reasoningStart = Date()
        let id = UUID()
        activeReasoningId = id
        // Insert reasoning BEFORE the AI entry (or at end if AI entry doesn't exist yet)
        let aiIdx = entries.indices.last { if case .aiMessage = entries[$0] { return true } else { return false } }
        let entry = Entry.reasoning(ReasoningEntry(id: id, text: "", duration: 0, isExpanded: false, isThinking: true))
        if let idx = aiIdx {
            entries.insert(entry, at: idx)
        } else {
            entries.append(entry)
        }
    }

    private func appendToActiveAI(_ text: String) {
        guard let id = activeAIId else { return }
        for i in entries.indices {
            if case .aiMessage(var e) = entries[i], e.id == id {
                e.text += text
                entries[i] = .aiMessage(e)
                return
            }
        }
    }

    private func appendToActiveReasoning(_ text: String) {
        guard let id = activeReasoningId else { return }
        for i in entries.indices {
            if case .reasoning(var e) = entries[i], e.id == id {
                e.text += text
                entries[i] = .reasoning(e)
                return
            }
        }
    }

    private func finaliseReasoningEntry(id: UUID) {
        let duration = reasoningStart.map { Date().timeIntervalSince($0) } ?? 0
        for i in entries.indices {
            if case .reasoning(var e) = entries[i], e.id == id {
                e.isThinking = false
                e.duration = duration
                entries[i] = .reasoning(e)
                return
            }
        }
    }

    private func finaliseThinkingBlock(thinking: String, signature: String) {
        // Update the thinking block stored in the current reasoning entry (for history replay)
        guard let id = activeReasoningId else { return }
        for i in entries.indices {
            if case .reasoning(var e) = entries[i], e.id == id {
                e.thinkingSignature = signature
                entries[i] = .reasoning(e)
                return
            }
        }
    }

    private func appendRedactedThinking(data: String) {
        entries.append(.activity(ActivityEntry(id: UUID(), text: "🔒 Thinking (redacted)")))
    }

    private func addToolCallEntry(id: String, name: String, arguments: String) {
        let entry = ToolCallEntry(id: id, name: name, arguments: arguments, status: .running, result: nil)
        entries.append(.toolCall(entry))
    }

    private func updateToolCallStatus(id: String, status: ToolCallEntry.Status, result: String?) {
        for i in entries.indices {
            if case .toolCall(var e) = entries[i], e.id == id {
                e.status = status
                e.result = result
                entries[i] = .toolCall(e)
                return
            }
        }
    }

    /// Provider-facing arguments must be a JSON object (OpenAI/Anthropic reject anything else, and
    /// MLX silently drops the whole call). The entry keeps the raw text for display/debugging.
    private func historyArguments(_ normalized: String) -> String {
        if let d = normalized.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) is [String: Any] {
            return normalized
        }
        ChatLog.warning(.tools, "tool call arguments are not a JSON object; sending {} to the provider")
        return "{}"
    }

    private func appendAssistantToolCall(id: String, name: String, arguments: String) {
        let block = ChatMessage.ToolCallBlock(id: id, name: name, arguments: arguments)
        // Accumulate into a single assistant message with all tool calls
        if let last = history.last, last.role == .assistant,
           let existing = last.toolCalls, !existing.isEmpty {
            // Append to existing tool call message
            history[history.count - 1] = ChatMessage(
                id: last.id, role: .assistant, content: last.content,
                toolCalls: existing + [block]
            )
        } else {
            history.append(ChatMessage(role: .assistant, content: [], toolCalls: [block]))
        }
    }

    private func removeActivity() {
        entries.removeAll { if case .activity = $0 { return true } else { return false } }
    }
}

// MARK: - Entry types

public extension ChatSession {

    /// Display model for timeline rows rendered by AIChatUI.
    enum Entry: Identifiable {
        case userMessage(UserEntry)
        case aiMessage(AIEntry)
        case reasoning(ReasoningEntry)
        case toolCall(ToolCallEntry)
        case activity(ActivityEntry)
        case knowledgeRetrieval(KnowledgeRetrievalEntry)

        /// Stable row identifier used by SwiftUI lists.
        public var id: String {
            switch self {
            case .userMessage(let e):  "user-\(e.id)"
            case .aiMessage(let e):    "ai-\(e.id)"
            case .reasoning(let e):    "reasoning-\(e.id)"
            case .toolCall(let e):     "tool-\(e.id)"
            case .activity(let e):     "activity-\(e.id)"
            case .knowledgeRetrieval(let e): "knowledge-\(e.id)"
            }
        }
    }

    /// User-authored message row.
    struct UserEntry: Identifiable {
        /// Stable identifier for this row.
        public let id: UUID
        /// User message text.
        public var text: String
        /// True when the user cancelled before the model produced anything: the message was never
        /// answered and is not part of the provider history.
        public var isCancelled: Bool = false

        /// Creates a user-message entry.
        ///
        /// - Parameters:
        ///   - id: Stable row identifier.
        ///   - text: User message text.
        public init(id: UUID, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// Assistant message row.
    struct AIEntry: Identifiable {
        /// Stable identifier for this row.
        public let id: UUID
        /// Assistant text content.
        public var text: String
        /// Indicates whether this row is still receiving stream deltas.
        public var isStreaming: Bool

        /// Creates an assistant-message entry.
        ///
        /// - Parameters:
        ///   - id: Stable row identifier.
        ///   - text: Assistant message text.
        ///   - isStreaming: Streaming state for UI affordances.
        public init(id: UUID, text: String, isStreaming: Bool) {
            self.id = id
            self.text = text
            self.isStreaming = isStreaming
        }
    }

    /// Model reasoning row shown before or alongside assistant output.
    struct ReasoningEntry: Identifiable {
        /// Stable identifier for this row.
        public let id: UUID
        /// Reasoning text content.
        public var text: String
        /// Duration in seconds for the completed reasoning phase.
        public var duration: TimeInterval
        /// Whether the row is expanded in UI.
        public var isExpanded: Bool
        /// Whether the model is still actively reasoning.
        public var isThinking: Bool
        /// Anthropic thinking signature — preserved for multi-turn round-tripping.
        public var thinkingSignature: String?

        /// Public memberwise initializer — a `public struct` with public stored properties
        /// otherwise only gets an `internal` synthesized init, which blocks a host app that
        /// drives its own generation loop (rather than `ChatSession` itself) from constructing
        /// an entry to hand to `ThinkingTileView`.
        public init(
            id: UUID, text: String, duration: TimeInterval = 0,
            isExpanded: Bool = false, isThinking: Bool = false, thinkingSignature: String? = nil
        ) {
            self.id = id
            self.text = text
            self.duration = duration
            self.isExpanded = isExpanded
            self.isThinking = isThinking
            self.thinkingSignature = thinkingSignature
        }
    }

    /// Tool invocation row with execution status and optional result.
    struct ToolCallEntry: Identifiable {
        /// Provider-generated tool call identifier.
        public let id: String
        /// Tool/function name.
        public var name: String
        /// Normalized JSON tool arguments.
        public var arguments: String
        /// Current execution status.
        public var status: Status
        /// Optional tool result text.
        public var result: String?

        /// Status lifecycle for a tool call.
        public enum Status { case running, succeeded, failed }

        /// Creates a tool-call entry.
        ///
        /// - Parameters:
        ///   - id: Tool call identifier.
        ///   - name: Tool/function name.
        ///   - arguments: JSON argument payload.
        ///   - status: Initial execution status.
        ///   - result: Optional initial result text.
        public init(id: String, name: String, arguments: String, status: Status, result: String?) {
            self.id = id
            self.name = name
            self.arguments = arguments
            self.status = status
            self.result = result
        }
    }

    /// Retrieval context row rendered when external knowledge is injected.
    struct KnowledgeRetrievalEntry: Identifiable {
        /// Stable identifier for this row.
        public let id: UUID
        /// Retrieval query or label.
        public var query: String
        /// Retrieved context body.
        public var body: String
        /// Whether the body is expanded in UI.
        public var isExpanded: Bool = false

        /// Creates a knowledge-retrieval entry.
        ///
        /// - Parameters:
        ///   - id: Stable row identifier.
        ///   - query: Retrieval query or label.
        ///   - body: Retrieved context content.
        ///   - isExpanded: Initial expansion state.
        public init(id: UUID, query: String, body: String, isExpanded: Bool = false) {
            self.id = id
            self.query = query
            self.body = body
            self.isExpanded = isExpanded
        }
    }

    /// Transient activity row for thinking and inline errors.
    struct ActivityEntry: Identifiable {
        /// Stable identifier for this row.
        public let id: UUID
        /// Activity text shown to the user.
        public var text: String
        /// Whether the activity represents an error.
        public var isError: Bool = false

        /// Public so a host app (or coordinator) can append its own inline error/status row.
        public init(id: UUID = UUID(), text: String, isError: Bool = false) {
            self.id = id
            self.text = text
            self.isError = isError
        }
    }
}

// MARK: - Session errors

/// Errors raised by `ChatSession` itself (as opposed to the provider).
public enum ChatSessionError: Error, LocalizedError, Sendable {
    /// `submitToolResult` was called with an id that has no pending tool call.
    case unknownToolCall(id: String)

    /// User-facing description.
    public var errorDescription: String? {
        switch self {
        case .unknownToolCall(let id):
            return "Tool result ignored: no pending tool call with id \"\(id)\" (already answered, cancelled, or never issued)."
        }
    }
}
