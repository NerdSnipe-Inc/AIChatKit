# AIChatKit

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FNerdSnipe-Inc%2FAIChatKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/NerdSnipe-Inc/AIChatKit)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FNerdSnipe-Inc%2FAIChatKit%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/NerdSnipe-Inc/AIChatKit)

A Swift package that gives every app a single, unified chat interface across cloud and on-device AI providers. OpenAI, Anthropic, and Apple Intelligence all share the same protocol, message model, and optional SwiftUI components — swap providers with a one-line change.

**Platforms:** macOS 14+ · iOS 17+  
**Language:** Swift 5.10+

For on-device inference, add a companion package:
- **[AIChatKitMLX](https://github.com/NerdSnipe-Inc/AIChatKitMLX)** — Apple MLX models (Apple Silicon only, text + vision)

---

## Products

| Product | Description |
|---|---|
| `AIChatCore` | Protocol, message model, shared types |
| `AIChatOpenAI` | OpenAI-compatible provider (OpenAI, OpenRouter, llama-server, …) |
| `AIChatAnthropic` | Anthropic Messages API with extended thinking support |
| `AIChatFoundationModels` | Apple Intelligence on-device (macOS 26+ / iOS 26+) |
| `AIChatUI` | `ChatSession` ViewModel + `MarkdownMessageView` + optional `ChatView` drop-in |

---

## Installation

```swift
// Package.swift
.package(url: "https://github.com/NerdSnipe-Inc/AIChatKit", from: "0.1.0")

// Target dependencies — add only what you need
.product(name: "AIChatCore",             package: "AIChatKit"),
.product(name: "AIChatOpenAI",           package: "AIChatKit"),
.product(name: "AIChatAnthropic",        package: "AIChatKit"),
.product(name: "AIChatFoundationModels", package: "AIChatKit"),
.product(name: "AIChatUI",               package: "AIChatKit"),
```

---

## Quick start — custom UI (recommended)

Most apps have their own design system. Use `ChatSession` as the ViewModel and render `session.entries` in your own views:

```swift
import AIChatAnthropic
import AIChatUI

@StateObject private var session = ChatSession(
    provider: AnthropicProvider(apiKey: "sk-ant-…"),
    model: "claude-opus-4-8",
    options: ChatRequestOptions(
        maxTokens: 4096,
        systemPrompt: "You are a helpful assistant."
    )
)

var body: some View {
    ScrollView {
        ForEach(session.entries) { entry in
            switch entry {
            case .userMessage(let e):   MyUserBubble(text: e.text)
            case .aiMessage(let e):     MyAssistantBubble(text: e.text, isStreaming: e.isStreaming)
            case .reasoning(let e):     MyThinkingTile(entry: e)
            case .toolCall(let e):      MyToolCallRow(entry: e)
            case .activity(let e):      Text(e.text).foregroundStyle(.secondary)
            case .knowledgeRetrieval:   EmptyView()
            }
        }
    }
    TextField("Message", text: $input)
        .onSubmit { session.send(input); input = "" }
}
```

`session.send(_:)` is non-blocking. Entries append as tokens arrive. `session.isGenerating` tracks in-flight state.

---

## Drop-in UI

If you have no design requirements, `ChatView` handles everything:

```swift
import AIChatUI
import AIChatOpenAI

ChatView(session: ChatSession(
    provider: OpenAIProvider(apiKey: "sk-…"),
    model: "gpt-4o"
))
```

---

## Markdown rendering

`AIChatUI` exports `MarkdownMessageView` — a fully styled markdown renderer built on [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) and [Splash](https://github.com/JohnSundell/Splash). It handles fenced code blocks with syntax highlighting, a language label, and a copy button.

```swift
import AIChatUI

// In a custom AI bubble:
case .aiMessage(let e):
    MarkdownMessageView(text: e.text)
```

Supports: headings, bold/italic, inline code, fenced code blocks (syntax-highlighted), blockquotes, lists, tables, links.

---

## Restoring saved conversations

Use `loadSnapshot(entries:history:)` to restore a persisted conversation into both the display entries and provider history in a single call:

```swift
var snapshotEntries: [ChatSession.Entry] = []
var snapshotHistory: [ChatMessage] = []

for msg in storedMessages {
    if msg.role == "user" {
        snapshotEntries.append(.userMessage(ChatSession.UserEntry(id: msg.id, text: msg.content)))
        snapshotHistory.append(ChatMessage(id: msg.id, role: .user, content: msg.content))
    } else {
        snapshotEntries.append(.aiMessage(ChatSession.AIEntry(id: msg.id, text: msg.content, isStreaming: false)))
        snapshotHistory.append(ChatMessage(id: msg.id, role: .assistant, content: msg.content))
    }
}

session.loadSnapshot(entries: snapshotEntries, history: snapshotHistory)
// session.send() now has full history context
```

---

## Providers

### OpenAI

```swift
import AIChatOpenAI

let provider = OpenAIProvider(apiKey: "sk-…")

// OpenAI-compatible endpoint (OpenRouter, llama-server, Groq, …)
let provider = OpenAIProvider(
    apiKey: "your-key",
    endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
)

// Local llama-server — disable stream_options
let provider = OpenAIProvider(apiKey: "", endpoint: llamaURL, streamUsage: false)
```

### Anthropic

```swift
import AIChatAnthropic

let provider = AnthropicProvider(apiKey: "sk-ant-…")

// Extended thinking
ChatRequestOptions(maxTokens: 16000, thinkingBudget: 8000)
```

### Apple Intelligence (Foundation Models)

```swift
import AIChatFoundationModels
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
guard case .available = SystemLanguageModel.default.availability else { return }
let provider = FoundationModelsProvider()
```

Context window is **4,096 tokens** on-device. When the conversation exceeds this limit, `FoundationModelsProvider` surfaces `LanguageModelSession.GenerationError.exceededContextWindowSize`. Callers should catch this and either summarize history or switch to a higher-context provider (e.g. `MLXProvider` from AIChatKitMLX, or `PrivateCloudComputeLanguageModel` when it becomes available in the public SDK).

```swift
session.$error
    .sink { error in
        if let genError = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = genError {
            // switch to higher-context provider and restore history
        }
    }
```

---

## Tool use

```swift
import AIChatCore

let tool = ChatRequestOptions.ToolDefinition(
    name: "get_weather",
    description: "Get the current weather for a city.",
    parameters: .object(
        properties: ["city": .string(description: "City name")],
        required: ["city"]
    )
)

ChatRequestOptions(tools: [tool], toolChoice: .auto)
```

When a `.toolCall` entry has `status == .running`, execute the tool and call:

```swift
session.submitToolResult(toolCallId: entry.id, content: resultString)
```

---

## Error handling

`ChatSession` surfaces errors as `.activity` entries automatically. For custom error UI:

```swift
.onChange(of: session.error) { _, error in
    guard let error else { return }
    // show your own alert
}
```

---

## License

MIT
