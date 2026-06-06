import SwiftUI
import AIChatCore

public struct ConversationView: View {
    @ObservedObject public var session: ChatSession

    public init(session: ChatSession) {
        self.session = session
    }

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

private struct UserMessageRow: View {
    let entry: ChatSession.UserEntry

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(entry.text)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.blue.opacity(0.85), in: .rect(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy") { ChatClipboard.copy(entry.text) }
                }
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
