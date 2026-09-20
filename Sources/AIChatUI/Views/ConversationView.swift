import SwiftUI
import AIChatCore

/// Scrollable conversation timeline bound to a `ChatSession`.
public struct ConversationView: View {
    /// Session backing the rendered conversation entries.
    @ObservedObject public var session: ChatSession

    /// Creates a conversation view bound to a session.
    ///
    /// - Parameter session: Session view model that provides timeline entries.
    public init(session: ChatSession) {
        self.session = session
    }

    /// Conversation list body with automatic scroll-to-bottom behavior.
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(session.entries, id: \.id) { entry in
                        entryRow(for: entry)
                            .id(entry.id)
                    }
                    // Invisible bottom anchor for auto-scroll
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: session.entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // Also scroll when streaming text changes the last AI entry
            .onChange(of: lastAIText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Row dispatch

    @ViewBuilder
    private func entryRow(for entry: ChatSession.Entry) -> some View {
        switch entry {
        case .userMessage(let e):
            UserMessageRow(entry: e)

        case .reasoning(let e):
            ThinkingTileView(entry: e) { session.toggleThinking(id: e.id) }
                .frame(maxWidth: .infinity, alignment: .leading)

        case .aiMessage(let e):
            AIMessageRow(entry: e)

        case .toolCall(let e):
            ToolCallView(entry: e)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .knowledgeRetrieval(let e):
            KnowledgeRetrievalView(entry: e) {
                session.toggleKnowledgeRetrieval(id: e.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .activity(let e):
            ActivityRow(entry: e)
        }
    }

    private var lastAIText: String {
        for entry in session.entries.reversed() {
            if case .aiMessage(let e) = entry { return e.text }
        }
        return ""
    }
}

// MARK: - Row types

/// Presentation rules for a user-message row, kept out of the view so they can be unit-tested.
enum UserMessagePresentation {
    /// Shown under a message the user cancelled before the model produced anything. Such a turn is
    /// dropped from the history sent to the provider on later turns (see ``ChatSession``), so the
    /// caption says what the user actually needs to know: the model won't see it.
    static let cancelledCaption = "Cancelled — the model won't see this message"

    /// Caption under the bubble, or `nil` for a normal message.
    static func caption(for entry: ChatSession.UserEntry) -> String? {
        entry.isCancelled ? cancelledCaption : nil
    }

    /// Bubble opacity: a cancelled message is dimmed so it reads as abandoned.
    static func bubbleOpacity(for entry: ChatSession.UserEntry) -> Double {
        entry.isCancelled ? 0.55 : 1
    }

    /// VoiceOver label, so the cancelled state isn't conveyed by dimming alone.
    static func accessibilityLabel(for entry: ChatSession.UserEntry) -> String {
        entry.isCancelled ? "\(entry.text). \(cancelledCaption)." : entry.text
    }
}

struct UserMessageRow: View {
    let entry: ChatSession.UserEntry

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.text)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.blue.opacity(0.85), in: .rect(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
                    .opacity(UserMessagePresentation.bubbleOpacity(for: entry))
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy") { ChatClipboard.copy(entry.text) }
                    }
                if let caption = UserMessagePresentation.caption(for: entry) {
                    Label(caption, systemImage: "xmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(UserMessagePresentation.accessibilityLabel(for: entry))
        }
    }
}

private struct AIMessageRow: View {
    let entry: ChatSession.AIEntry
    @State private var isHovering = false
    @State private var didCopy = false

    private var canCopy: Bool { !entry.text.isEmpty }

    var body: some View {
        Group {
            if entry.text.isEmpty && entry.isStreaming {
                ProgressView().scaleEffect(0.6)
                    .frame(width: 24, height: 24, alignment: .leading)
            } else {
                MarkdownMessageView(text: entry.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu {
                        if canCopy {
                            Button("Copy") { copyMessage() }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if canCopy {
                            MessageCopyButton(isHovering: isHovering, didCopy: didCopy) {
                                copyMessage()
                            }
                            .padding(.leading, 4)
                        }
                    }
            }
        }
        .onHover { isHovering = $0 }
    }

    private func copyMessage() {
        ChatClipboard.copy(entry.text)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { didCopy = false }
        }
    }
}

private struct MessageCopyButton: View {
    let isHovering: Bool
    let didCopy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(didCopy ? Color.green : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(didCopy ? "Copied" : "Copy message")
        .opacity(isHovering || didCopy ? 1 : 0.45)
        .accessibilityLabel("Copy message")
    }
}

private struct ActivityRow: View {
    let entry: ChatSession.ActivityEntry

    var body: some View {
        HStack(spacing: 6) {
            if !entry.isError {
                ProgressView().scaleEffect(0.6)
            }
            Text(entry.text)
                .font(.subheadline)
                .foregroundStyle(entry.isError ? .primary : .secondary)
        }
    }
}
