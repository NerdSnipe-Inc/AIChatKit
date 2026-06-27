import Foundation
import AIChatCore
import SwiftUI

/// The ViewModel for a conversation. Owns the provider, history, and all display state.
/// Drop one into your view with `@StateObject` and wire it to `ChatView`.
@MainActor
public final class ChatSession: ObservableObject {

    // MARK: - Public state

    @Published public var entries: [Entry] = []
    @Published public var isGenerating: Bool = false
    @Published public var error: Error? = nil

    // MARK: - Configuration

    public var provider: any ChatProvider
    public var model: String
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
    private var generationWasCancelled = false

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

    public struct KnowledgeRetrievalInjection: Sendable {
        public let query: String
        public let body: String
        public init(query: String, body: String) {
            self.query = query
            self.body = body
        }
    }

    public func send(_ text: String, knowledge: KnowledgeRetrievalInjection? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }

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
    }

    /// Programmatic tool call when the harness must execute a tool the model planned but did not emit.
    public func requestToolCall(name: String, arguments: String) {
        guard !isGenerating else { return }
        let id = UUID().uuidString
        let normalized = GemmaToolArguments.normalize(arguments)
        addToolCallEntry(id: id, name: name, arguments: normalized)
        appendAssistantToolCall(id: id, name: name, arguments: normalized)
    }

    /// Append a tool result to history and continue the conversation.
    public func submitToolResult(toolCallId: String, content: String, isError: Bool = false) {
        let msg = ChatMessage(toolCallId: toolCallId, content: content)
        history.append(msg)
        updateToolCallStatus(id: toolCallId, status: isError ? .failed : .succeeded, result: content)
        startGeneration()
    }

    public func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isGenerating = false
        removeActivity()
    }

    public func toggleKnowledgeRetrieval(id: UUID) {
        for i in entries.indices {
            if case .knowledgeRetrieval(var e) = entries[i], e.id == id {
                e.isExpanded.toggle()
                entries[i] = .knowledgeRetrieval(e)
                return
            }
        }
    }

    public func toggleThinking(id: UUID) {
        for i in entries.indices {
            if case .reasoning(var e) = entries[i], e.id == id {
                e.isExpanded.toggle()
                entries[i] = .reasoning(e)
                return
            }
        }
    }

    public func clearHistory() {
        guard !isGenerating else { return }
        streamTask?.cancel()
        streamTask = nil
        isGenerating = false
        entries = []
        history = []
    }

    /// Restore a persisted conversation into both display entries and provider history.
    public func loadSnapshot(entries: [Entry], history: [ChatMessage]) {
        streamTask?.cancel()
        streamTask = nil
        isGenerating = false
        error = nil
        activeReasoningId = nil
        activeAIId = nil
        reasoningStart = nil
        textEmitter = nil
        self.entries = entries
        self.history = history
    }

    // MARK: - Private: generation lifecycle

    private func startGeneration() {
        // Cancel any in-flight stream before starting a new one.
        // Without this, a second call (e.g. from submitToolResult while the first
        // stream's finishGeneration hasn't yet run) would leak the old Task and
        // both streams would write to history concurrently.
        streamTask?.cancel()
        streamTask = nil

        generationID &+= 1
        let myGenerationID = generationID

        isGenerating = true
        generationWasCancelled = false
        error = nil
        activeReasoningId = nil
        activeAIId = nil
        reasoningStart = nil

        let activityId = UUID()
        entries.append(.activity(ActivityEntry(id: activityId, text: "Thinking…")))

        let emitter = BalancedEmitter(duration: 1.0, frequency: 30) { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendToActiveAI(chunk)
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
                        self?.handle(event)
                    }
                    // Feed text through balanced emitter on each text event
                    if case .text(let t) = event {
                        await emitter.add(t)
                    }
                }
                await emitter.wait()
            } catch is CancellationError {
                await emitter.cancel()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.generationID == myGenerationID {
                        self.generationWasCancelled = true
                    }
                }
            } catch {
                await emitter.cancel()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Only store error if this generation wasn't superseded
                    if self.generationID == myGenerationID {
                        self.error = error
                    }
                }
            }
        }
    }

    private func handle(_ event: ChatStreamEvent) {
        switch event {
        case .text:
            // Actual text delivery is handled by the BalancedEmitter callback; here we just ensure entries exist
            removeActivity()
            ensureAIEntry()

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
            appendAssistantToolCall(id: id, name: name, arguments: normalized)

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
            // If a newer generation started while we were finishing, don't touch shared state.
            guard self.generationID == generationID else { return }
            if self.generationWasCancelled {
                self.generationWasCancelled = false
                self.removeActivity()
                self.isGenerating = false
                self.streamTask = nil
                return
            }
            // Mark reasoning entry as done (stops the thinking animation)
            if let rid = activeReasoningId {
                finaliseReasoningEntry(id: rid)
            }
            // Recover tool calls the model wrote as <tool_call> text (LoRA / training artifact).
            if let aid = activeAIId {
                recoverEmbeddedToolCalls(fromAIEntryId: aid)
                if let aid = activeAIId {
                    captureAssistantMessage(id: aid)
                }
            }
            removeActivity()
            // Surface any error inline (the top banner can be missed).
            let hasToolCalls = entries.contains { if case .toolCall = $0 { return true } else { return false } }
            let hasReasoningContent = entries.contains {
                if case .reasoning(let e) = $0 { return !e.text.isEmpty }
                return false
            }
            if let err = error, activeAIId == nil {
                let msg = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
                entries.append(.activity(ActivityEntry(id: UUID(), text: "⚠️ \(msg)", isError: true)))
            } else if error == nil && activeAIId == nil && activeReasoningId == nil && !hasToolCalls && !hasReasoningContent {
                entries.append(.activity(ActivityEntry(id: UUID(), text: "⚠️ \(provider.zeroResponseMessage)", isError: true)))
            }
            let hasRunningTools = entries.contains {
                if case .toolCall(let e) = $0 { return e.status == .running }
                return false
            }
            isGenerating = hasRunningTools
            if !hasRunningTools { streamTask = nil }
        }
    }

    // MARK: - Entry management helpers

    private func recoverEmbeddedToolCalls(fromAIEntryId id: UUID) -> Bool {
        guard let idx = entries.indices.first(where: {
            if case .aiMessage(let e) = entries[$0], e.id == id { return true } else { return false }
        }), case .aiMessage(var e) = entries[idx] else { return false }

        let parsed = GemmaOutputRecovery.parse(from: e.text, toolSchemas: options.nativeToolSpecs?.compactMap { $0 as? [String: Any] })
        guard !parsed.calls.isEmpty else { return false }

        e.text = parsed.cleanedText
        e.isStreaming = false
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
            appendAssistantToolCall(id: toolId, name: call.name, arguments: normalized)
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

    private func captureAssistantMessage(id: UUID) {
        guard let idx = entries.indices.first(where: {
            if case .aiMessage(let e) = entries[$0], e.id == id { return true } else { return false }
        }) else { return }
        if case .aiMessage(var e) = entries[idx] {
            e.isStreaming = false
            entries[idx] = .aiMessage(e)
        }

        // Build the assistant message for history
        let text = { () -> String in
            if case .aiMessage(let e) = entries[idx] { return e.text } else { return "" }
        }()

        // Pull thinking content from the reasoning entry (if any)
        var contentBlocks: [ChatMessage.ContentBlock] = []
        if let rid = activeReasoningId, let rIdx = entries.indices.first(where: {
            if case .reasoning(let e) = entries[$0], e.id == rid { return true } else { return false }
        }), case .reasoning(let re) = entries[rIdx] {
            contentBlocks.append(.thinking(.init(text: re.text, signature: re.thinkingSignature)))
        }
        if !text.isEmpty { contentBlocks.append(.text(text)) }

        history.append(ChatMessage(role: .assistant, content: contentBlocks))
    }

    private func removeActivity() {
        entries.removeAll { if case .activity = $0 { return true } else { return false } }
    }
}

// MARK: - Entry types

public extension ChatSession {

    enum Entry: Identifiable {
        case userMessage(UserEntry)
        case aiMessage(AIEntry)
        case reasoning(ReasoningEntry)
        case toolCall(ToolCallEntry)
        case activity(ActivityEntry)
        case knowledgeRetrieval(KnowledgeRetrievalEntry)

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

    struct UserEntry: Identifiable {
        public let id: UUID
        public var text: String

        public init(id: UUID, text: String) {
            self.id = id
            self.text = text
        }
    }

    struct AIEntry: Identifiable {
        public let id: UUID
        public var text: String
        public var isStreaming: Bool

        public init(id: UUID, text: String, isStreaming: Bool) {
            self.id = id
            self.text = text
            self.isStreaming = isStreaming
        }
    }

    struct ReasoningEntry: Identifiable {
        public let id: UUID
        public var text: String
        public var duration: TimeInterval
        public var isExpanded: Bool
        public var isThinking: Bool
        /// Anthropic thinking signature — preserved for multi-turn round-tripping.
        public var thinkingSignature: String?
    }

    struct ToolCallEntry: Identifiable {
        public let id: String
        public var name: String
        public var arguments: String
        public var status: Status
        public var result: String?

        public enum Status { case running, succeeded, failed }

        public init(id: String, name: String, arguments: String, status: Status, result: String?) {
            self.id = id
            self.name = name
            self.arguments = arguments
            self.status = status
            self.result = result
        }
    }

    struct KnowledgeRetrievalEntry: Identifiable {
        public let id: UUID
        public var query: String
        public var body: String
        public var isExpanded: Bool = false

        public init(id: UUID, query: String, body: String, isExpanded: Bool = false) {
            self.id = id
            self.query = query
            self.body = body
            self.isExpanded = isExpanded
        }
    }

    struct ActivityEntry: Identifiable {
        public let id: UUID
        public var text: String
        public var isError: Bool = false
    }
}
