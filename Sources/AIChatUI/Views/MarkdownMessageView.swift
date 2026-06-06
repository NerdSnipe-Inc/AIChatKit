import SwiftUI
import MarkdownUI
import Splash

/// Renders markdown with syntax-highlighted code blocks using swift-markdown-ui + Splash.
struct MarkdownMessageView: View {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownCodeSyntaxHighlighter(SplashHighlighter.shared)
            .markdownTextStyle { FontSize(15) }
            .markdownBlockStyle(\.codeBlock, body: codeBlock)
            .markdownBlockStyle(\.blockquote) { configuration in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(.secondary.opacity(0.4))
                        .frame(width: 3)
                    configuration.label
                        .padding(.leading, 10)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func codeBlock(_ configuration: CodeBlockConfiguration) -> some View {
        CodeBlockChrome(
            language: configuration.language,
            content: configuration.content,
            label: configuration.label
        )
    }
}

private struct CodeBlockChrome: View {
    let language: String?
    let content: String
    let label: CodeBlockConfiguration.Label
    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: copyCode) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(didCopy ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(didCopy ? "Copied" : "Copy code")
                .opacity(isHovering || didCopy ? 1 : 0.35)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            label
                .relativeLineSpacing(.em(0.2))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.85))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(.secondary.opacity(0.07))
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.secondary.opacity(0.12), lineWidth: 1)
        )
        .contextMenu {
            Button("Copy Code") { copyCode() }
        }
        .onHover { isHovering = $0 }
    }

    private func copyCode() {
        ChatClipboard.copy(content)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { didCopy = false }
        }
    }
}

final class SplashHighlighter: CodeSyntaxHighlighter {
    static let shared = SplashHighlighter()

    private let highlighter = SyntaxHighlighter(format: AttributedStringOutputFormat(
        theme: .init(
            font: .init(size: 13),
            plainTextColor: .init(white: 0.85, alpha: 1),
            tokenColors: [
                .keyword:    .init(red: 0.81, green: 0.53, blue: 0.96, alpha: 1),
                .string:     .init(red: 0.98, green: 0.67, blue: 0.47, alpha: 1),
                .type:       .init(red: 0.51, green: 0.85, blue: 0.77, alpha: 1),
                .call:       .init(red: 0.67, green: 0.88, blue: 0.57, alpha: 1),
                .number:     .init(red: 0.71, green: 0.84, blue: 0.98, alpha: 1),
                .comment:    .init(white: 0.5, alpha: 1),
                .property:   .init(red: 0.73, green: 0.73, blue: 1.0, alpha: 1),
                .dotAccess:  .init(red: 0.73, green: 0.73, blue: 1.0, alpha: 1),
                .preprocessing: .init(red: 0.95, green: 0.70, blue: 0.55, alpha: 1),
            ]
        )
    ))

    func highlightCode(_ content: String, language: String?) -> Text {
        let highlighted = highlighter.highlight(content)
        #if canImport(UIKit)
        guard let attributed = try? AttributedString(highlighted, including: \.uiKit) else {
            return Text(content)
        }
        #else
        guard let attributed = try? AttributedString(highlighted, including: \.appKit) else {
            return Text(content)
        }
        #endif
        return Text(attributed)
    }
}
