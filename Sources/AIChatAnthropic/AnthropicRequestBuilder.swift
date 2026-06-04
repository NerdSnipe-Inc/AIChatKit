import Foundation
import AIChatCore

public struct AnthropicRequestBuilder: Sendable {
    private static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    private let endpoint: URL
    private let apiKey: String

    public init(apiKey: String, endpoint: URL? = nil) {
        self.apiKey = apiKey
        self.endpoint = endpoint ?? Self.defaultEndpoint
    }

    public func buildRequest(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions,
        stream: Bool
    ) throws -> URLRequest {
        // Split system messages from conversation history
        var systemBlocks: [AnthropicSystemBlock] = []
        var conversationMessages: [ChatMessage] = []

        if let prompt = options.systemPrompt {
            systemBlocks.append(AnthropicSystemBlock(type: "text", text: prompt))
        }

        for msg in messages {
            if msg.role == .system {
                let text = msg.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
                systemBlocks.append(AnthropicSystemBlock(type: "text", text: text))
            } else {
                conversationMessages.append(msg)
            }
        }

        let anthropicMessages = conversationMessages.compactMap(toAnthropicMessage)

        let thinkingConfig: AnthropicThinkingConfig? = options.thinkingBudget.map {
            AnthropicThinkingConfig(type: "enabled", budgetTokens: $0)
        }

        let body = AnthropicRequestBody(
            model: model,
            messages: anthropicMessages,
            maxTokens: options.maxTokens ?? 8192,
            stream: stream,
            system: systemBlocks.isEmpty ? nil : systemBlocks,
            temperature: options.temperature,
            thinking: thinkingConfig,
            tools: options.tools?.map(toAnthropicTool),
            topP: options.topP,
            stopSequences: options.stop
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json",    forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,                forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion,       forHTTPHeaderField: "anthropic-version")

        // Extended thinking requires the beta header
        if options.thinkingBudget != nil {
            request.setValue("interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        }

        options.extraHeaders?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: - Message conversion

    private func toAnthropicMessage(_ message: ChatMessage) -> AnthropicMessage? {
        let role: String
        switch message.role {
        case .user:       role = "user"
        case .assistant:  role = "assistant"
        case .tool:       role = "user"   // Tool results go back as user messages in Anthropic
        case .system:     return nil       // Handled separately
        }

        var blocks: [AnthropicContentBlock] = []

        // Tool result messages (ChatMessage with toolCallId)
        if message.role == .tool, let toolCallId = message.toolCallId {
            let text = message.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
            blocks.append(.toolResult(toolUseId: toolCallId, content: text, isError: false))
            return AnthropicMessage(role: "user", content: blocks)
        }

        // Regular content blocks
        for block in message.content {
            switch block {
            case .text(let t):
                blocks.append(.text(t))
            case .image(let img):
                if let url = img.url {
                    blocks.append(.imageUrl(url))
                } else if let mt = img.mediaType, let data = img.base64Data {
                    blocks.append(.image(mediaType: mt, data: data))
                }
            case .toolCall(let tc):
                // Parse arguments JSON string back into [String: AnyCodable] for Anthropic
                let input: [String: AnyCodable]
                if let data = tc.arguments.data(using: .utf8),
                   let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
                    input = dict
                } else {
                    input = [:]
                }
                blocks.append(.toolUse(id: tc.id, name: tc.name, input: input))
            case .toolResult(let tr):
                blocks.append(.toolResult(toolUseId: tr.toolCallId, content: tr.content, isError: tr.isError))
            case .thinking(let tb):
                // Preserve thinking blocks with signature for round-tripping (required by Anthropic)
                blocks.append(.thinking(thinking: tb.text, signature: tb.signature ?? ""))
            case .redactedThinking(let data):
                blocks.append(.redactedThinking(data: data))
            }
        }

        // Include tool calls from the toolCalls property
        for tc in message.toolCalls ?? [] {
            let input: [String: AnyCodable]
            if let data = tc.arguments.data(using: .utf8),
               let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
                input = dict
            } else {
                input = [:]
            }
            blocks.append(.toolUse(id: tc.id, name: tc.name, input: input))
        }

        guard !blocks.isEmpty else { return nil }
        return AnthropicMessage(role: role, content: blocks)
    }

    private func toAnthropicTool(_ def: ChatRequestOptions.ToolDefinition) -> AnthropicTool {
        let schema: [String: AnyCodable]?
        if let params = def.parameters,
           let data = try? JSONEncoder().encode(params),
           let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) {
            schema = dict
        } else {
            schema = nil
        }
        return AnthropicTool(name: def.name, description: def.description, inputSchema: schema)
    }
}
