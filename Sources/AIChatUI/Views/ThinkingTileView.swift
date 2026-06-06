import SwiftUI
import AIChatCore

/// Collapsible thinking/reasoning tile. Shows "Thinking…" with animation during generation,
/// then "Thought for Xs" with expandable full content when done.
public struct ThinkingTileView: View {
    public let entry: ChatSession.ReasoningEntry
    public let onToggle: () -> Void

    public init(entry: ChatSession.ReasoningEntry, onToggle: @escaping () -> Void) {
        self.entry = entry
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pillButton
            if entry.isExpanded && !entry.isThinking {
                expandedContent
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.1), value: entry.isExpanded)
    }

    // MARK: - Pill

    private var pillButton: some View {
        Button(action: {
            guard !entry.isThinking else { return }
            onToggle()
        }) {
            HStack(spacing: 8) {
                if entry.isThinking {
                    ThinkingDotsView()
                        .frame(width: 24, height: 12)
                } else {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(pillLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !entry.isThinking && !entry.text.isEmpty {
                    Spacer(minLength: 0)
                    // Truncated preview when collapsed
                    if !entry.isExpanded {
                        Text(previewText)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(maxWidth: 120, alignment: .trailing)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(entry.isExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.secondary.opacity(0.08), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded content

    private var expandedContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(.secondary.opacity(0.35))
                .frame(width: 2)
                .padding(.vertical, 2)

            Text(entry.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 6)
        .padding(.top, 8)
    }

    // MARK: - Computed

    private var pillLabel: String {
        entry.isThinking ? "Thinking…" : "Thought for \(Int(entry.duration))s"
    }

    private var previewText: String {
        String(entry.text.suffix(50))
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Animated dots

struct ThinkingDotsView: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .opacity(phase == i ? 1.0 : 0.3)
                    .scaleEffect(phase == i ? 1.2 : 1.0)
            }
        }
        .onAppear { animateDots() }
    }

    private func animateDots() {
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                phase = (phase + 1) % 3
            }
        }
    }
}
