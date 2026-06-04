import SwiftUI
import AIChatCore

struct ConversationView: View {
    @ObservedObject var session: ChatSession

    var body: some View {
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

        case .activity(let e):
            ActivityRow(text: e.text)
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
        }
    }
}

private struct AIMessageRow: View {
    let entry: ChatSession.AIEntry

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if entry.text.isEmpty && entry.isStreaming {
                // Still receiving first token
                ProgressView().scaleEffect(0.6)
                    .frame(width: 24, height: 24)
            } else {
                MarkdownMessageView(text: entry.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 48)
        }
    }
}

private struct ActivityRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.6)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
