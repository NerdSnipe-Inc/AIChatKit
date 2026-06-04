import SwiftUI
import AIChatCore

/// Drop-in SwiftUI chat interface.
///
/// Usage:
/// ```swift
/// let provider = OpenAIProvider(apiKey: "sk-…")
/// let session  = ChatSession(provider: provider, model: "gpt-4o")
///
/// ChatView(session: session)
/// ```
public struct ChatView: View {
    @ObservedObject public var session: ChatSession

    public init(session: ChatSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            ConversationView(session: session)
            Divider()
            ComposerView(session: session)
        }
        .background(.background)
        .overlay(alignment: .top) {
            if let error = session.error {
                ErrorBanner(message: error.localizedDescription) {
                    session.error = nil
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
                .padding(.horizontal, 16)
            }
        }
        .animation(.spring(duration: 0.3), value: session.error != nil)
    }
}

// MARK: - Error banner

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.red.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.red.opacity(0.2), lineWidth: 1)
        )
    }
}
