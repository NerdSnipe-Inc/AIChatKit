import SwiftUI
import AIChatCore

struct ComposerView: View {
    @ObservedObject var session: ChatSession
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            textEditor
            sendOrStopButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Text input

    private var textEditor: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text("Message…")
                    .foregroundStyle(.tertiary)
                    .font(.body)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 36, maxHeight: 120)
                .fixedSize(horizontal: false, vertical: true)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .onSubmit { submitIfReady() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Send / stop button

    private var sendOrStopButton: some View {
        Button(action: { session.isGenerating ? session.cancel() : submitIfReady() }) {
            Image(systemName: session.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(canSend ? .blue : .secondary)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !session.isGenerating)
        .keyboardShortcut(.return, modifiers: .command)
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isGenerating
    }

    private func submitIfReady() {
        guard canSend else { return }
        let message = text
        text = ""
        session.send(message)
        focused = true
    }
}
