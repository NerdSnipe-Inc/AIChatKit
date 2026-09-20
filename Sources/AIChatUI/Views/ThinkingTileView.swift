import SwiftUI
import AIChatCore

/// Collapsible thinking/reasoning tile. Shows "Thinking…" with animation during generation,
/// then "Thought for Xs" with expandable full content when done.
///
/// **Design (intentional, not a defect):** while `entry.isThinking` the tile is a live,
/// non-interactive indicator. The streamed reasoning text is not rendered and taps are ignored,
/// so the row never reflows while tokens arrive. `ChatSession` creates the entry collapsed
/// (`isExpanded == false`) and never auto-expands it; once thinking finishes the tile shows
/// "Thought for Xs" with a preview, and the user may expand it (`ChatSession.toggleThinking`).
/// The rules live in ``ThinkingTilePresentation`` so they are unit-tested.
public struct ThinkingTileView: View {
    /// Reasoning entry rendered by this tile.
    public let entry: ChatSession.ReasoningEntry
    /// Callback invoked when the tile expansion toggles.
    public let onToggle: () -> Void

    /// Creates a reasoning tile.
    ///
    /// - Parameters:
    ///   - entry: Reasoning entry to display.
    ///   - onToggle: Expansion toggle handler.
    public init(entry: ChatSession.ReasoningEntry, onToggle: @escaping () -> Void) {
        self.entry = entry
        self.onToggle = onToggle
    }

    /// Tile body with compact pill and optional expanded reasoning text.
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pillButton
            if ThinkingTilePresentation.showsExpandedContent(entry) {
                expandedContent
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.1), value: entry.isExpanded)
    }

    // MARK: - Pill

    private var pillButton: some View {
        Button(action: {
            guard ThinkingTilePresentation.isToggleEnabled(entry) else { return }
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
        ThinkingTilePresentation.pillLabel(entry)
    }

    private var previewText: String {
        ThinkingTilePresentation.previewText(entry)
    }
}

// MARK: - Presentation rules

/// Pure presentation rules for ``ThinkingTileView`` (kept separate so they are testable headlessly).
enum ThinkingTilePresentation {
    /// Pill label: "Thinking…" while streaming, "Thought for Ns" afterwards.
    static func pillLabel(_ entry: ChatSession.ReasoningEntry) -> String {
        entry.isThinking ? "Thinking…" : "Thought for \(Int(entry.duration))s"
    }

    /// Full reasoning text is shown only when finished AND expanded.
    static func showsExpandedContent(_ entry: ChatSession.ReasoningEntry) -> Bool {
        entry.isExpanded && !entry.isThinking
    }

    /// Taps toggle expansion only once thinking has finished.
    static func isToggleEnabled(_ entry: ChatSession.ReasoningEntry) -> Bool {
        !entry.isThinking
    }

    /// Last 50 characters of the reasoning on a single line, shown in the collapsed pill.
    static func previewText(_ entry: ChatSession.ReasoningEntry) -> String {
        String(entry.text.suffix(50)).replacingOccurrences(of: "\n", with: " ")
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
