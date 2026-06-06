import Foundation
import JSONSchema

/// Options shared by all providers. Each provider uses what it supports and ignores the rest.
public struct ChatRequestOptions: Sendable {
    /// Max tokens to generate. Maps to `max_tokens` for OpenAI/llama.cpp.
    public var maxTokens: Int?
    /// Sampling temperature (0–2). Most providers support this.
    public var temperature: Double?
    /// Nucleus sampling probability mass.
    public var topP: Double?
    /// Stop sequences.
    public var stop: [String]?
    /// Tools the model may call.
    public var tools: [ToolDefinition]?
    /// Controls which tool (if any) is called.
    public var toolChoice: ToolChoiceOption?
    /// Reasoning effort for OpenAI o-series: "none" | "minimal" | "low" | "medium" | "high" | "xhigh".
    public var reasoningEffort: String?
    /// Anthropic extended thinking budget (tokens). Enables thinking when set.
    public var thinkingBudget: Int?
    /// Whether to request usage stats in streamed responses via `stream_options`.
    /// Set to `false` for llama.cpp which doesn't support `stream_options`. Default: `true`.
    public var streamUsage: Bool
    /// System prompt text. Sent as a system message (OpenAI) or `system` param (Anthropic).
    public var systemPrompt: String?
    /// Additional HTTP headers merged into the request.
    public var extraHeaders: [String: String]?
    /// Native tool specs for local-inference providers (MLX, llama.cpp).
    /// Passed directly to the model's chat template as the `tools=` array.
    /// API providers (OpenAI, Anthropic) use `tools: [ToolDefinition]` instead.
    public var nativeToolSpecs: [[String: any Sendable]]?

    // MARK: - Local-inference sampling (llama.cpp / LlamaProvider)
    // These are ignored by HTTP-based providers (OpenAI, Anthropic).

    /// Top-k sampling — keep only the K highest-logit candidates. 0 = disabled.
    /// Default used by `LlamaProvider`: 40.
    public var topK: Int?
    /// Min-p sampling — drop tokens whose probability < minP × top-token probability.
    /// Default used by `LlamaProvider`: 0.05.
    public var minP: Double?
    /// Repetition penalty multiplier applied to already-seen tokens (1.0 = disabled).
    /// Default used by `LlamaProvider`: 1.1.
    public var penaltyRepeat: Double?
    /// Frequency penalty — additional penalty per occurrence count (0 = disabled).
    /// Default used by `LlamaProvider`: 0.0.
    public var penaltyFreq: Double?
    /// Presence penalty — flat penalty for any token that has appeared (0 = disabled).
    /// Default used by `LlamaProvider`: 0.0.
    public var penaltyPresent: Double?

    public init(
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        stop: [String]? = nil,
        tools: [ToolDefinition]? = nil,
        toolChoice: ToolChoiceOption? = nil,
        reasoningEffort: String? = nil,
        thinkingBudget: Int? = nil,
        streamUsage: Bool = true,
        systemPrompt: String? = nil,
        extraHeaders: [String: String]? = nil,
        nativeToolSpecs: [[String: any Sendable]]? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        penaltyRepeat: Double? = nil,
        penaltyFreq: Double? = nil,
        penaltyPresent: Double? = nil
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.stop = stop
        self.tools = tools
        self.toolChoice = toolChoice
        self.reasoningEffort = reasoningEffort
        self.thinkingBudget = thinkingBudget
        self.streamUsage = streamUsage
        self.systemPrompt = systemPrompt
        self.extraHeaders = extraHeaders
        self.nativeToolSpecs = nativeToolSpecs
        self.topK = topK
        self.minP = minP
        self.penaltyRepeat = penaltyRepeat
        self.penaltyFreq = penaltyFreq
        self.penaltyPresent = penaltyPresent
    }
}

// MARK: - Tool Definition

public extension ChatRequestOptions {

    struct ToolDefinition: Sendable, Encodable {
        public let name: String
        public let description: String?
        public let parameters: JSONSchema?
        public let strict: Bool?

        public init(name: String, description: String? = nil, parameters: JSONSchema? = nil, strict: Bool? = nil) {
            self.name = name
            self.description = description
            self.parameters = parameters
            self.strict = strict
        }
    }

    enum ToolChoiceOption: Sendable {
        case none
        case auto
        case required
        case function(String)
    }
}

// MARK: - ChatCompletionResult

public struct ChatCompletionResult: Sendable {
    public let id: String?
    public let model: String
    public let message: ChatMessage
    public let usage: TokenUsage?
    public let finishReason: FinishReason

    public enum FinishReason: Sendable {
        case stop
        case length
        case toolCalls
        case contentFilter
        case unknown(String)
    }

    public init(id: String?, model: String, message: ChatMessage, usage: TokenUsage?, finishReason: FinishReason) {
        self.id = id
        self.model = model
        self.message = message
        self.usage = usage
        self.finishReason = finishReason
    }
}
