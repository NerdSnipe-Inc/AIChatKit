# Changelog

All notable changes to AIChatKit are documented in this file. Each version has a matching
[GitHub release](https://github.com/NerdSnipe-Inc/AIChatKit/releases) with the same notes.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0] - 2026-09-27

Gemma text tool-call parsing moves out of `AIChatUI` into AIChatKitMLX, and a turn that fails before
any output no longer leaves two user messages in a row.

### Breaking
- **Removed** `GemmaOutputRecovery`, `GemmaToolArguments` and `EmbeddedToolCallParser` (all were public
  in `AIChatUI`).
- `ChatSession` no longer parses tool calls out of assistant text (`call:name{…}`,
  `<tool_call>{json}</tool_call>`, ` ```tool_code `). Text a provider streams as text is shown as text.
  A provider that talks to a model which writes calls as text must turn them into `.toolCallComplete`
  events itself. **AIChatKitMLX 1.4.0+ does this for Gemma**, at stream level.
- `ChatSession` no longer rewrites tool-call arguments. It trims them, treats blank as `{}`, and still
  sends anything that is not a JSON object to the provider as `{}`.

### Fixed
- A turn that ends in an error, or an empty reply, before any output is now dropped from the history
  sent to the provider, the same way a cancel before output is. Previously the next `send` could send
  two consecutive user turns, which strict chat templates (Gemma) reject. Errors *after* partial
  output are unchanged: the partial reply is committed, so roles already alternate.

### Added
- `ChatSession.UserEntry.isFailed` (default `false`): set on such a turn. `ConversationView` shows it
  dimmed with the caption “Not answered — the model won't see this message” and a matching VoiceOver
  label (`UserMessagePresentation.failedCaption`).
- `docs/CHAT_SESSION_BEHAVIOUR.md` documents the thinking tile and where tool-call parsing lives.

### Changed
- README: “Known limits” is now “Upgrade notes”. Swift / platform / license badges.

### Upgrading from 1.x
1. **Using AIChatKitMLX with Gemma?** Update it to **1.4.0 or later** in the same change. With an older
   AIChatKitMLX, a Gemma model that writes `<tool_call>` XML or `tool_code` blocks would show them as
   plain text, because 2.0.0 no longer recovers them in the UI.
2. **Called `GemmaOutputRecovery`, `GemmaToolArguments` or `EmbeddedToolCallParser` directly?** They are
   gone. Use a provider that emits `.toolCallComplete` (AIChatKitMLX 1.4.0+ for Gemma), or copy the
   parser into your own provider.
3. **Draw your own user-message rows?** Treat `UserEntry.isFailed` like `isCancelled`: the message was
   never answered and is not in the provider history. Resending it retries.
4. **Depend on other NerdSnipe packages?** They must allow AIChatKit 2.x. Compatible releases:
   AIChatKitMLX 1.4.0, AiPersona 1.1.1, GHLAIService 0.2.1. AIChatKitLlama 1.0.2 and earlier require
   AIChatKit `<2.0.0`.
5. Nothing else in the public API changed.

## [1.3.0] - 2026-09-20

### Added
- `ConversationView` shows a user message that was cancelled before the model produced anything: the
  bubble is dimmed and captioned “Cancelled — the model won't see this message”, with a matching
  VoiceOver label. Such a message is dropped from the history sent to the provider on later turns
  (1.2.0); this makes that visible. The rules live in `UserMessagePresentation` and are unit-tested.
  Hosts that draw their own rows can read `ChatSession.UserEntry.isCancelled`.
- README “Known limits” section.

### Notes
- `BalancedEmitterTests` is no longer flaky (test-only change).

## [1.2.0] - 2026-09-20

### Fixed
- Cancelling before the model has produced any output no longer leaves two consecutive user turns in
  the history sent to the provider on the next `send`. Local chat templates (Gemma) expect strict
  user/assistant alternation. The unanswered trailing user turn is dropped from the provider history
  and stays in the transcript, marked `UserEntry.isCancelled`. Cancels that had partial text,
  reasoning or tool calls behave as before.

### Added
- `ChatSession.UserEntry.isCancelled` (defaults to `false`).

### Changed
- `ThinkingTileView`: no behaviour change. The design (collapsed and non-expandable while the model is
  still thinking, expandable once finished) is documented in code and in
  `docs/CHAT_SESSION_BEHAVIOUR.md`, and its presentation rules are unit-tested.

### Known limit
- A turn that ends in an error or a zero-response message still keeps its user turn. *Fixed in 2.0.0.*

## [1.1.2] - 2026-09-20

### Fixed
- Regression in 1.1.1: the Hugging Face hub's untyped 404/401/403 form (`HubApi.httpStatusCode(404)`)
  was no longer recognised, so a genuinely missing model was reported as a load failure instead of
  “not found”. `ChatError.httpStatus(in:)` now matches it. **Skip 1.1.1.**

## [1.1.1] - 2026-09-20

### Fixed
- `ChatError.classify` no longer reports a model that is present but fails to load as “model not
  found”. Only real Hugging Face “no such repository” signals (HTTP 401/403/404, “repository not
  found”, “revision not found”) map to `.modelNotFound`; a generic “not found” (for example a missing
  weight key) is now `.modelLoadFailed` with the underlying error preserved. *Regressed the hub's
  untyped 404; fixed in 1.1.2.*

## [1.1.0] - 2026-09-20

### Added
- `ChatLog`: `os.Logger`-based logging (subsystem `cc.nerdsnipe.AIChatKit`) with a runtime debug mode
  (`AICHAT_DEBUG=1`, a UserDefaults key, or `ChatLog.debugMode`). Message content is logged only at
  `.debug` and marked private.
- Eight new `ChatError` cases for local-model failures: `modelNotFound`, `modelDownloadFailed`,
  `outOfMemory`, `modelLoadFailed`, `unsupportedModel`, `templateError`, `toolCallParseFailed`,
  `generationFailed`. Each has `errorDescription`, `failureReason`, `recoverySuggestion` and a
  `debugDescription` with the underlying error chain. `ChatError.classify(_:modelId:phase:)` maps raw
  MLX / Hugging Face / Foundation errors onto them.
- `FoundationModelsProvider` accepts Apple `Tool` instances.
- `ChatSession.ActivityEntry` has a public initializer.
- `docs/ERRORS_AND_LOGGING.md`, `docs/CHAT_SESSION_BEHAVIOUR.md`.

### Fixed
- `ChatSession` tool loop: assistant text and tool calls are one history message followed by the tool
  results; parallel tool calls re-invoke the model only after the last result; unknown or duplicate
  tool results are rejected with a specific error; cancelling leaves no stuck rows and keeps partial
  text; blank or reasoning-only replies show a specific message.
- Gemma tool-call recovery and argument parsing is string-aware: braces and quotes inside arguments no
  longer break it, and prose like “call: 555” is no longer treated as a call.
- A missing or inaccessible Hugging Face model now reads “could not be found, or you don't have
  access to it” instead of a connectivity error.

### Upgrading from 1.0.x
- The new `ChatError` cases mean an exhaustive `switch` over `ChatError` needs a `default:`.
- `ChatSession.send` now returns a `Bool` (`@discardableResult`; was `Void`).

## [1.0.3] - 2026-08-20

### Changed
- `FoundationModelsProvider` testability refactor; `ChatSessionTests` fix.

## [1.0.2] - 2026-08-07

### Fixed
- `AIChatUI`: Sendable-safe tool schema types; the recover-tool-calls result is discardable.

### Changed
- Docs: clarify that `PrivateCloudComputeLanguageModel` is private API.

## [1.0.1] - 2026-06-27

### Added
- Swift DocC comments across the public APIs of `AIChatCore`, `AIChatOpenAI`, `AIChatAnthropic`,
  `AIChatFoundationModels` and `AIChatUI`.

### Changed
- `.spi.yml` optimised for faster Swift Package Index builds.

## [1.0.0] - 2026-06-27

First stable release.

- **AIChatCore**: unified chat protocol, message model, tool types.
- **AIChatOpenAI**: OpenAI-compatible streaming (OpenAI, OpenRouter, llama-server, …).
- **AIChatAnthropic**: Anthropic Messages API with extended thinking.
- **AIChatFoundationModels**: Apple Intelligence on-device (macOS 26+ / iOS 26+).
- **AIChatUI**: `ChatSession`, `MarkdownMessageView`, optional `ChatView`.
- MIT license and Swift Package Index manifest; Gemma output recovery and Foundation Models provider
  refinements.

## 0.1.x

Pre-release versions (0.1.0 on 2026-06-04, 0.1.1 on 2026-06-27).

[Unreleased]: https://github.com/NerdSnipe-Inc/AIChatKit/compare/2.0.0...HEAD
[2.0.0]: https://github.com/NerdSnipe-Inc/AIChatKit/compare/1.3.0...2.0.0
[1.3.0]: https://github.com/NerdSnipe-Inc/AIChatKit/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/NerdSnipe-Inc/AIChatKit/compare/1.1.2...1.2.0
[1.1.2]: https://github.com/NerdSnipe-Inc/AIChatKit/compare/1.1.1...1.1.2
[1.1.1]: https://github.com/NerdSnipe-Inc/AIChatKit/compare/1.1.0...1.1.1
[1.1.0]: https://github.com/NerdSnipe-Inc/AIChatKit/compare/1.0.3...1.1.0
[1.0.3]: https://github.com/NerdSnipe-Inc/AIChatKit/compare/1.0.2...1.0.3
[1.0.2]: https://github.com/NerdSnipe-Inc/AIChatKit/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/NerdSnipe-Inc/AIChatKit/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/NerdSnipe-Inc/AIChatKit/releases/tag/1.0.0
