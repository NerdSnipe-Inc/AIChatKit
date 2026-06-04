import Foundation
import AIChatCore

public struct OpenAIRequestBuilder: Sendable {
    private let endpoint: URL
    private let apiKey: String
    private let streamUsage: Bool

    public init(endpoint: URL, apiKey: String, streamUsage: Bool = true) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.streamUsage = streamUsage
    }

    public func buildRequest(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions,
        stream: Bool
    ) throws -> URLRequest {
        let body = OAIRequestBody(
            model: model,
            messages: messages.compactMap(toOAIMessage),
            stream: stream,
            streamOptions: (stream && streamUsage) ? OAIStreamOptions(includeUsage: true) : nil,
            temperature: options.temperature,
            topP: options.topP,
            maxTokens: options.maxTokens,
            stop: options.stop,
            tools: options.tools.map { $0.map(toOAITool) },
            toolChoice: options.toolChoice.map(toOAIToolChoice),
            reasoningEffort: options.reasoningEffort
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        options.extraHeaders?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: - Message conversion

    private func toOAIMessage(_ message: ChatMessage) -> OAIMessage? {
        switch message.role {
        case .system:
            let text = message.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
            return OAIMessage(role: "system", content: .text(text), toolCalls: nil, toolCallId: nil, name: nil)

        case .user:
            let content = buildUserContent(message.content)
            return OAIMessage(role: "user", content: content, toolCalls: nil, toolCallId: nil, name: nil)

        case .assistant:
            let textBlocks = message.content.compactMap { block -> String? in
                if case .text(let t) = block { return t } else { return nil }
            }
            let text = textBlocks.isEmpty ? nil : textBlocks.joined()
            let oaiToolCalls = (message.toolCalls ?? []).map { tc in
                OAIToolCall(id: tc.id, type: "function",
                            function: OAIToolCall.OAIFunctionCall(name: tc.name, arguments: tc.arguments))
            }
            return OAIMessage(
                role: "assistant",
                content: text.map { .text($0) },
                toolCalls: oaiToolCalls.isEmpty ? nil : oaiToolCalls,
                toolCallId: nil,
                name: nil
            )

        case .tool:
            let text = message.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
            return OAIMessage(role: "tool", content: .text(text), toolCalls: nil, toolCallId: message.toolCallId, name: nil)
        }
    }

    private func buildUserContent(_ blocks: [ChatMessage.ContentBlock]) -> OAIContent {
        // Single plain text → string shorthand
        if blocks.count == 1, case .text(let t) = blocks[0] {
            return .text(t)
        }

        let parts: [OAIPart] = blocks.compactMap { block in
            switch block {
            case .text(let t):
                return OAIPart(type: "text", text: t, imageUrl: nil)
            case .image(let img):
                if let url = img.url {
                    return OAIPart(type: "image_url", text: nil, imageUrl: OAIImageUrl(url: url, detail: "auto"))
                } else if let mediaType = img.mediaType, let data = img.base64Data {
                    let url = "data:\(mediaType);base64,\(data)"
                    return OAIPart(type: "image_url", text: nil, imageUrl: OAIImageUrl(url: url, detail: "auto"))
                }
                return nil
            default:
                return nil  // thinking / tool blocks not sent as user content
            }
        }
        return .parts(parts)
    }

    // MARK: - Tool conversion

    private func toOAITool(_ def: ChatRequestOptions.ToolDefinition) -> OAITool {
        OAITool(
            type: "function",
            function: OAITool.OAIToolFunction(
                name: def.name,
                description: def.description,
                parameters: def.parameters,
                strict: def.strict
            )
        )
    }

    private func toOAIToolChoice(_ choice: ChatRequestOptions.ToolChoiceOption) -> OAIToolChoice {
        switch choice {
        case .none:          return OAIToolChoice(value: .none)
        case .auto:          return OAIToolChoice(value: .auto)
        case .required:      return OAIToolChoice(value: .required)
        case .function(let n): return OAIToolChoice(value: .function(n))
        }
    }
}
