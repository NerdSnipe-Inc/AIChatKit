# AIChatKit — Implementation Guide for Claude Code

This file tells you exactly how to integrate AIChatKit into a macOS or iOS app. Read it before writing any code.

## The default: custom UI, our session management

Most apps should use `ChatSession` (from `AIChatUI`) for conversation state and drive their own SwiftUI views from it. Do **not** default to using `ChatView` — apps have their own design systems and `ChatView` is an opinionated default, not the primary integration path.

The three integration tiers, ordered from most common to least:

| Tier | What you import | What you get |
|---|---|---|
| **Custom UI** (default) | `AIChatUI` + a provider | `ChatSession` ViewModel, build your own views |
| **Drop-in UI** | `AIChatUI` + a provider | `ChatView` — use only when the app has no design system or explicitly requests it |
| **Raw streaming** | `AIChatCore` + a provider | `ChatProvider.stream()` directly — use only when `ChatSession` is genuinely too limiting |

---

## Package products

Add only what the target needs:

```swift
// Package.swift
.product(name: "AIChatCore",             package: "AiChatPackage")  // always needed
.product(name: "AIChatOpenAI",           package: "AiChatPackage")  // OpenAI / OpenRouter / llama-server
.product(name: "AIChatAnthropic",        package: "AiChatPackage")  // Anthropic
.product(name: "AIChatUI",               package: "AiChatPackage")  // ChatSession + ChatView
.product(name: "AIChatLlama",            package: "AiChatPackage")  // on-device llama.cpp GGUF (~500 MB binary)
.product(name: "AIChatMLX",              package: "AiChatPackage")  // Apple MLX, Apple Silicon only
.product(name: "AIChatFoundationModels", package: "AiChatPackage")  // Apple Intelligence, macOS/iOS 26+
```

`AIChatLlama` pulls a large binary XCFramework (~500 MB). `AIChatMLX` and `AIChatFoundationModels` are standard Swift packages with no binary blobs.

---

## Tier 1 — Custom UI with ChatSession (use this by default)

### Imports

```swift
import AIChatAnthropic   // or AIChatOpenAI or AIChatLlama
import AIChatUI          // for ChatSession
```

### Create a session

```swift
@StateObject private var session = ChatSession(
    provider: AnthropicProvider(apiKey: "sk-ant-…"),
    model: "claude-opus-4-8",
    options: ChatRequestOptions(
        maxTokens: 4096,
        temperature: 0.7,
        systemPrompt: "You are a helpful assistant."
    )
)
```

### ChatSession public API

```swift
// Send a user message — non-blocking, streams response into session.entries
session.send("Hello")

// Cancel an in-flight stream
session.cancel()

// Clear conversation history and all entries
session.clearHistory()

// Submit a tool result and continue the conversation
session.submitToolResult(toolCallId: id, content: resultString)

// Toggle expanded state of a reasoning/thinking tile
session.toggleThinking(id: entryId)
```

### Published properties

```swift
session.entries       // [ChatSession.Entry] — the conversation, append-only during streaming
session.isGenerating  // Bool — true while a stream is in flight
session.error         // Error? — set on request failure
```

### Rendering session.entries

Switch over every case. All entry types are `Identifiable`.

```swift
ScrollView {
    ForEach(session.entries) { entry in
        switch entry {
        case .userMessage(let e):
            // e.text: String
            MyUserBubble(text: e.text)

        case .aiMessage(let e):
            // e.text: String — grows token-by-token while e.isStreaming == true
            // e.isStreaming: Bool — false once the stream seals this message
            MyAssistantBubble(text: e.text, isStreaming: e.isStreaming)

        case .reasoning(let e):
            // e.text: String — the thinking/reasoning content
            // e.duration: TimeInterval — wall-clock seconds (set when isThinking becomes false)
            // e.isThinking: Bool — true while the thinking block is still open
            // e.isExpanded: Bool — UI toggle state; call session.toggleThinking(id: e.id) to flip
            MyThinkingTile(entry: e)

        case .toolCall(let e):
            // e.name: String — tool name
            // e.arguments: String — JSON-encoded arguments
            // e.status: .running | .succeeded | .failed
            // e.result: String? — set after submitToolResult is called
            MyToolCallRow(entry: e)

        case .activity(let e):
            // e.text: String — transient status ("Thinking…") or error banners
            // These appear and disappear automatically; don't try to control them
            Text(e.text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

### Tool calls in a custom UI

When a `.toolCall` entry has `status == .running`, your app must execute the tool and call `submitToolResult`. The session will then continue the conversation automatically.

```swift
case .toolCall(let e) where e.status == .running:
    Button("Run \(e.name)") {
        let result = myToolExecutor.run(name: e.name, arguments: e.arguments)
        session.submitToolResult(toolCallId: e.id, content: result)
    }
```

---

## Provider setup

### Anthropic

```swift
import AIChatAnthropic

let provider = AnthropicProvider(apiKey: "sk-ant-…")
```

Extended thinking (Claude 3.5+):

```swift
ChatRequestOptions(
    maxTokens: 16000,
    thinkingBudget: 8000   // enables extended thinking; must be < maxTokens
)
```

Thinking blocks appear as `.reasoning` entries in the session.

### OpenAI

```swift
import AIChatOpenAI

// OpenAI
let provider = OpenAIProvider(apiKey: "sk-…")

// Any OpenAI-compatible endpoint
let provider = OpenAIProvider(
    apiKey: "your-key",
    endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
)

// Local llama-server — no auth, stream_options not supported
let provider = OpenAIProvider(
    apiKey: "",
    endpoint: URL(string: "http://localhost:8080/v1/chat/completions")!,
    streamUsage: false
)
```

OpenAI o-series reasoning effort:

```swift
ChatRequestOptions(reasoningEffort: "high")  // "none"|"minimal"|"low"|"medium"|"high"|"xhigh"
```

### Apple MLX (on-device, Apple Silicon)

```swift
import AIChatMLX

// Hub model (downloaded and cached on first use)
let provider = MLXProvider()                                              // default: gemma-4-e4b-it-4bit
let provider = MLXProvider(modelId: "mlx-community/Qwen3-1.7B-4bit")

// Pre-downloaded local directory
let provider = MLXProvider(modelPath: URL(fileURLWithPath: "/path/to/dir"))
```

Show download progress before first inference:

```swift
try await provider.loadModel { progress in
    // progress.fractionCompleted: Double (0.0–1.0)
}
```

`MLXProvider` is an `actor`. The `model` parameter on `ChatSession` is ignored — model is fixed at init.

Requires Apple Silicon. Does not run on Intel Macs or Simulator.

### Apple Foundation Models (Apple Intelligence)

```swift
import AIChatFoundationModels
import FoundationModels

// Always check availability first — requires Apple Intelligence enabled in Settings
guard case .available = SystemLanguageModel.default.availability else { return }

@available(macOS 26.0, iOS 26.0, *)
let provider = FoundationModelsProvider()

// Custom generation options
@available(macOS 26.0, iOS 26.0, *)
let provider = FoundationModelsProvider(
    model: .default,
    generationOptions: GenerationOptions()
)
```

`FoundationModelsProvider` is a `struct`. The `model` parameter on `ChatSession` is ignored. Multi-turn history is replayed into the `LanguageModelSession` transcript on each call. Requires macOS 26.0+ / iOS 26.0+ with Apple Intelligence hardware and enabled in Settings.

### llama.cpp (on-device)

```swift
import AIChatLlama

let provider = LlamaProvider(
    modelPath:   "/path/to/model.gguf",  // must be a .gguf file the app can read
    contextSize: 8192,                   // KV cache window in tokens
    nGpuLayers:  99,                     // 99 = all layers on Metal GPU; -1 = CPU only
    maxTurns:    20                      // older turns are truncated beyond this
)
```

`LlamaProvider` is an `actor`. The model loads on first use and stays resident. GPU is automatically disabled on simulators — no conditional code needed.

The `model` parameter passed to `ChatSession` is ignored by `LlamaProvider`; pass any non-empty string.

---

## ChatRequestOptions — full reference

All providers share this struct. Each provider silently ignores fields it doesn't support.

```swift
ChatRequestOptions(
    // Universal
    maxTokens:       2048,
    temperature:     0.7,
    topP:            0.95,
    stop:            ["<|eot_id|>"],
    systemPrompt:    "You are a helpful assistant.",
    tools:           [myToolDefinition],
    toolChoice:      .auto,              // .none | .auto | .required | .function("name")
    extraHeaders:    ["X-Custom": "val"],

    // Anthropic only
    thinkingBudget:  8000,

    // OpenAI o-series only
    reasoningEffort: "high",

    // LlamaProvider only (ignored by cloud providers)
    topK:            40,
    minP:            0.05,
    penaltyRepeat:   1.1,
    penaltyFreq:     0.0,
    penaltyPresent:  0.0,

    // Set false for servers that don't support stream_options (llama-server, some OpenRouter models)
    streamUsage:     false
)
```

---

## Tool definitions

```swift
import AIChatCore

let myTool = ChatRequestOptions.ToolDefinition(
    name:        "get_weather",
    description: "Get the current weather for a city.",
    parameters:  .object(
        properties: [
            "city":  .string(description: "City name"),
            "units": .enum(description: "Units", values: [.string("celsius"), .string("fahrenheit")])
        ],
        required: ["city"]
    )
)

// Pass to options
ChatRequestOptions(tools: [myTool], toolChoice: .auto)
```

---

## Error handling

`session.error` is set automatically when a stream fails. `ChatSession` also appends a visible `.activity` entry with the error text, so the user always sees something without extra code.

For custom error UI, observe `session.error`:

```swift
.onChange(of: session.error) { _, error in
    guard let error else { return }
    // show your own alert or inline error state
}
```

`ChatError` cases:

```swift
switch error as? ChatError {
case .serverError(let code, let message):   // HTTP 4xx/5xx from the API
case .networkError(let underlying):          // URLSession-level failure
case .decodingError(let underlying):         // JSON parsing failure
case .streamError(let message):              // SSE/stream protocol error
case .invalidConfiguration(let message):     // bad API key, missing model path, etc.
case .cancelled:                             // session.cancel() was called
}
```

---

## Tier 2 — Drop-in ChatView (only when explicitly requested)

```swift
import AIChatUI
import AIChatAnthropic

struct ContentView: View {
    @StateObject private var session = ChatSession(
        provider: AnthropicProvider(apiKey: "sk-ant-…"),
        model: "claude-opus-4-8"
    )

    var body: some View {
        ChatView(session: session)
    }
}
```

`ChatView` renders all entry types, handles streaming display, shows thinking tiles, and surfaces errors. Use it only when the app has no design requirements of its own.

---

## Tier 3 — Raw streaming (rarely needed)

Use `ChatProvider.stream()` directly when `ChatSession` is too limiting — e.g. you need to intercept every token for real-time audio synthesis or custom history management.

```swift
import AIChatCore
import AIChatAnthropic

let provider = AnthropicProvider(apiKey: "sk-ant-…")
var history: [ChatMessage] = []

let stream = provider.stream(
    messages: history,
    model: "claude-opus-4-8",
    options: ChatRequestOptions(systemPrompt: "You are helpful.")
)

var assistantText = ""
for try await event in stream {
    switch event {
    case .text(let delta):
        assistantText += delta

    case .reasoning(let delta):
        // thinking content (Anthropic extended thinking)
        break

    case .thinkingBlockComplete(let thinking, let signature):
        // complete thinking block — preserve for multi-turn round-tripping
        break

    case .toolCallComplete(let id, let name, let arguments):
        // execute tool, then append result to history and stream again
        break

    case .usage(let tokens):
        // tokens.promptTokens, tokens.completionTokens, tokens.totalTokens
        break

    case .done:
        break
    }
}

// Append assistant message to history for the next turn
history.append(ChatMessage(role: .assistant, content: assistantText))
```

### ChatMessage construction

```swift
// User message
ChatMessage(role: .user, content: "Hello")

// System message
ChatMessage.system("You are a helpful assistant.")

// Tool result
ChatMessage(toolCallId: "call_abc123", content: "72°F, sunny")

// Multi-block content (thinking + text, for Anthropic multi-turn)
ChatMessage(
    role: .assistant,
    content: [
        .thinking(.init(text: thinkingText, signature: thinkingSignature)),
        .text(responseText)
    ]
)
```

---

## Custom provider

Conform to `ChatProvider` to add any backend:

```swift
import AIChatCore

struct MyProvider: ChatProvider {
    let id   = "my-provider"
    let name = "My Backend"

    func stream(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.text("Hello"))
                continuation.finish()
            }
        }
    }

    func complete(
        messages: [ChatMessage],
        model: String,
        options: ChatRequestOptions
    ) async throws -> ChatCompletionResult {
        ChatCompletionResult(
            id: nil, model: model,
            message: ChatMessage(role: .assistant, content: "Hello"),
            usage: nil, finishReason: .stop
        )
    }
}
```

---

## Common mistakes to avoid

- **Don't store API keys in source code.** Read them from the Keychain or an environment variable.
- **Don't call `session.send()` while `session.isGenerating == true`.** The method is a no-op in that state, but guard it in the UI anyway.
- **Don't ignore `.activity` entries.** They include error banners the user needs to see.
- **Don't pass `streamUsage: true` (the default) to llama.cpp server.** It doesn't support `stream_options`. Use `OpenAIProvider(apiKey: "", endpoint: …, streamUsage: false)`.
- **Don't set `thinkingBudget` without also setting `maxTokens` above the budget.** Anthropic requires `maxTokens > thinkingBudget`.
- **Don't omit `AIChatLlama` from `.gitignore` or try to commit the resolved XCFramework.** It's ~500 MB.
- **`LlamaProvider` is an actor.** Do not call it directly from `@MainActor` synchronous context.
- **`MLXProvider` is an actor.** Same isolation rules as `LlamaProvider`. Call `loadModel()` before first use if you want to show download progress.
- **`MLXProvider` requires Apple Silicon.** Do not add `AIChatMLX` to targets that must run on Intel Macs or Simulator.
- **`FoundationModelsProvider` requires macOS 26+ / iOS 26+.** Wrap all usage in `@available(macOS 26.0, iOS 26.0, *)` and always check `SystemLanguageModel.default.availability` before instantiating.
- **`ChatSession` is `@MainActor`.** All access to `session.entries`, `session.isGenerating`, etc. must happen on the main actor.
