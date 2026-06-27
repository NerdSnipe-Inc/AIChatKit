import Foundation
import JSONSchema

/// Options shared by all providers.
///
/// Each provider reads the subset it supports and ignores unsupported fields. This
/// keeps call sites provider-agnostic while still exposing backend-specific tuning knobs.
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

    /// Creates a provider-agnostic options payload for chat generation.
    ///
    /// - Parameters:
    ///   - maxTokens: Maximum completion tokens.
    ///   - temperature: Sampling temperature.
    ///   - topP: Nucleus sampling probability mass.
    ///   - stop: Stop sequences.
    ///   - tools: Tool definitions exposed to the model.
    ///   - toolChoice: Tool call policy for the model.
    ///   - reasoningEffort: OpenAI reasoning effort level.
    ///   - thinkingBudget: Anthropic extended-thinking token budget.
    ///   - streamUsage: Whether to request usage chunks in streaming mode.
    ///   - systemPrompt: Optional top-level system prompt.
    ///   - extraHeaders: Additional request headers merged into provider requests.
    ///   - nativeToolSpecs: Native tool specs for local providers.
    ///   - topK: Top-k sampling configuration for local inference.
    ///   - minP: Min-p sampling configuration for local inference.
    ///   - penaltyRepeat: Repetition penalty for local inference.
    ///   - penaltyFreq: Frequency penalty for local inference.
    ///   - penaltyPresent: Presence penalty for local inference.
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

    /// A tool definition surfaced to model APIs that support tool/function calling.
    struct ToolDefinition: Sendable, Encodable {
        /// Tool/function identifier exposed to the model.
        public let name: String
        /// Natural-language guidance used by the model for tool selection.
        public let description: String?
        /// JSON schema for the tool input object.
        public let parameters: JSONSchema?
        /// Optional strict-schema flag for compatible providers.
        public let strict: Bool?

        /// Creates a tool definition for provider tool-calling APIs.
        ///
        /// - Parameters:
        ///   - name: Tool/function identifier.
        ///   - description: Human-readable tool description.
        ///   - parameters: JSON schema describing the tool arguments.
        ///   - strict: Whether schema adherence is required by the provider.
        public init(name: String, description: String? = nil, parameters: JSONSchema? = nil, strict: Bool? = nil) {
            self.name = name
            self.description = description
            self.parameters = parameters
            self.strict = strict
        }
    }

    /// Controls how the provider may select tools for a completion.
    enum ToolChoiceOption: Sendable {
        /// Disables tool invocation for this request.
        case none
        /// Lets the model decide whether to call a tool.
        case auto
        /// Requires at least one tool invocation.
        case required
        /// Forces a call to a specific function name.
        case function(String)
    }
}

// MARK: - ChatCompletionResult

public struct ChatCompletionResult: Sendable {
    /// Provider response identifier, when supplied.
    public let id: String?
    /// Model identifier that produced the completion.
    public let model: String
    /// Final assistant message content.
    public let message: ChatMessage
    /// Optional token usage payload.
    public let usage: TokenUsage?
    /// Provider-normalized finish reason.
    public let finishReason: FinishReason

    /// Normalized stop reason for non-streaming completions.
    public enum FinishReason: Sendable {
        /// Model reached a natural stopping point.
        case stop
        /// Model stopped due to token limit.
        case length
        /// Model ended to hand back one or more tool calls.
        case toolCalls
        /// Provider content policy filter interrupted generation.
        case contentFilter
        /// Provider-specific stop reason not covered by known cases.
        case unknown(String)
    }

    /// Creates a normalized non-streaming completion result.
    ///
    /// - Parameters:
    ///   - id: Provider response identifier.
    ///   - model: Model identifier used for the completion.
    ///   - message: Final assistant message payload.
    ///   - usage: Optional token usage metadata.
    ///   - finishReason: Provider-normalized completion stop reason.
    public init(id: String?, model: String, message: ChatMessage, usage: TokenUsage?, finishReason: FinishReason) {
        self.id = id
        self.model = model
        self.message = message
        self.usage = usage
        self.finishReason = finishReason
    }
}
