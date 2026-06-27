import SwiftUI
import AIChatCore

/// Displays a tool call with status colour coding and expandable result.
public struct ToolCallView: View {
    /// Tool call entry displayed by this row.
    public let entry: ChatSession.ToolCallEntry
    @State private var isExpanded = false

    /// Creates a tool-call row view.
    ///
    /// - Parameter entry: Tool-call entry to render.
    public init(entry: ChatSession.ToolCallEntry) {
        self.entry = entry
    }

    /// Row body containing status pill and optional details panel.
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pill
            if isExpanded {
                detail
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25, bounce: 0.1), value: isExpanded)
    }

    // MARK: - Pill

    private var pill: some View {
        Button(action: {
            guard entry.status != .running else { return }
            isExpanded.toggle()
        }) {
            HStack(spacing: 8) {
                statusIcon
                    .font(.subheadline)
                    .foregroundStyle(statusColor)

                Text(statusLabel)
                    .font(.subheadline)
                    .foregroundStyle(entry.status == .running ? .primary : .secondary)
                    .lineLimit(1)

                if entry.status != .running {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(statusColor.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(statusColor.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail panel

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !entry.arguments.isEmpty && entry.arguments != "{}" {
                Label("Arguments", systemImage: "curlybraces")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(formattedJSON(entry.arguments))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
            }
            if let result = entry.result {
                Label("Result", systemImage: "arrow.turn.down.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(result)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
            }
        }
        .padding(.leading, 12)
        .padding(.top, 8)
    }

    // MARK: - Computed

    private var statusColor: Color {
        switch entry.status {
        case .running:   .blue
        case .succeeded: .green
        case .failed:    .red
        }
    }

    private var statusIcon: Image {
        switch entry.status {
        case .running:   Image(systemName: "hourglass")
        case .succeeded: Image(systemName: "checkmark.seal.fill")
        case .failed:    Image(systemName: "xmark.seal.fill")
        }
    }

    private var statusLabel: String {
        switch entry.status {
        case .running:   "Calling \(entry.name)…"
        case .succeeded: "\(entry.name) completed"
        case .failed:    "\(entry.name) failed"
        }
    }

    private func formattedJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let str = String(data: pretty, encoding: .utf8) else { return raw }
        return str
    }
}
