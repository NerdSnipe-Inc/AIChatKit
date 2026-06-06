import SwiftUI

public struct KnowledgeRetrievalView: View {
    public let entry: ChatSession.KnowledgeRetrievalEntry
    public var onToggle: () -> Void

    public init(entry: ChatSession.KnowledgeRetrievalEntry, onToggle: @escaping () -> Void) {
        self.entry = entry
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "books.vertical.fill")
                        .foregroundStyle(.teal)
                    Text("Knowledge retrieved")
                        .font(.subheadline.weight(.medium))
                    Text(entry.query)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: entry.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if entry.isExpanded {
                Text(entry.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.teal.opacity(0.08), in: .rect(cornerRadius: 10))
            }
        }
        .padding(.vertical, 2)
    }
}
