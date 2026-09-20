# ChatSession behaviour

`ChatSession` (AIChatUI) is a `@MainActor` view model: it owns the provider-facing `history`
(`[ChatMessage]`) and the display `entries` (`[Entry]`). Tests: `ChatSessionLifecycleTests`
(scripted provider, no model) and, against the real on-device model, the app repo's
`LiveSessionTests`.

## Entries

| Entry | Created when | Left in state |
|---|---|---|
| `.userMessage` | `send` accepted | permanent |
| `.knowledgeRetrieval` | `send(_, knowledge:)` | permanent |
| `.activity("Thinking…")` | generation starts | removed at first content / finish / cancel |
| `.reasoning` | first `.reasoning` event (inserted before the AI row) | `isThinking = false`, `duration` set |
| `.aiMessage` | first `.text` event | `isStreaming = false`, text = full raw stream |
| `.toolCall` | `.toolCallComplete`, recovered embedded call, `requestToolCall` | `.running` → `.succeeded` / `.failed` |
| `.activity(isError: true)` | error, no response, reasoning-only, redacted thinking | permanent inline notice |

Invariant when the session is idle (`isGenerating == false`): no `.aiMessage` is streaming, no
`.reasoning` is thinking, no transient (non-error) `.activity` remains, no `.toolCall` is `.running`.

## State machine

```
idle ──send──▶ streaming ──stream ends──▶ (tool calls pending?) ──no──▶ idle
                   │                              │yes
                   │cancel()                      ▼
                   ▼                    awaitingToolResults  (isGenerating == true,
                 idle                    isAwaitingToolResults == true)
                                              │ submitToolResult for the LAST pending call
                                              ▼
                                          streaming (next model pass)
```

* `isGenerating` is true while streaming **and** while awaiting tool results.
* `isAwaitingToolResults` is true only after the stream has ended and calls are unanswered —
  this is the signal for a host to run its tools.

## Tool loop

There is no built-in executor: the host watches for `.toolCall` entries with `.running` status
(or `isAwaitingToolResults`), runs the tool, and calls `submitToolResult(toolCallId:content:isError:)`.

* One model pass = one assistant history message holding thinking + text **and** all its
  `tool_calls`, followed by one `tool` message per call. This is the ordering OpenAI/Anthropic
  require and what MLX's template expects.
* A result may be submitted as soon as the entry appears, even mid-stream: it is queued and
  applied when the stream ends (the stream is never cancelled by a result).
* With N parallel calls the model is re-invoked only after the Nth result. Results may arrive in
  any order.
* Unknown or already-answered ids are ignored and reported via `session.error`
  (`ChatSessionError.unknownToolCall`). Empty content is replaced by a placeholder (some
  templates drop empty tool messages).
* `isError: true` marks the row `.failed`; the model still gets the text and can explain.
* Tool calls the model wrote as text (`call:name{…}`, `<tool_call>{json}</tool_call>`,
  ```` ```tool_code ````) are recovered at the end of the stream and behave like native ones.
  Prose that merely contains `call:` (“give me a call: 555…”, `recall:{…}`) is left alone.
* Arguments that are not a JSON object are shown raw in the row but sent to the provider as `{}`.
* `requestToolCall` (host-planned call) is only allowed when idle.

## Cancellation

`cancel()` (no-op when idle): stops the provider stream, orphans late callbacks, stops the
streaming/thinking animations, **keeps** the partial text visible and in history (so roles keep
alternating), and marks any pending tool call `.failed` with a synthetic “Cancelled by user.”
result so history never contains a tool call without an answer. `error` is not set. The session is
immediately reusable. If nothing had been produced, the user message stays unanswered and the next
`send` produces two consecutive user turns (not exercised against the live model).

## Other rules

* `send` returns `false` (and does nothing) for empty/whitespace text or while busy
  (streaming or awaiting tool results). Use `cancel()` first to interrupt.
* `clearHistory()` is ignored while streaming; while merely awaiting tool results it resets the
  session (pending calls discarded).
* Errors: `error` is set and an inline red activity row shows `errorDescription` (+
  `recoverySuggestion` when the error provides one). Partial text is kept and committed.
* No response: a whitespace-only reply → `provider.zeroResponseMessage`; reasoning but no answer
  → “finished thinking without writing an answer (token limit?)”.
* The final AI entry text is the raw stream, not what the paced `BalancedEmitter` had displayed.

## Known limits

* One generation at a time; there is no queue for messages sent while busy.
* No context-window management: very long histories are sent as-is (the provider reports the
  failure).
* A tool that never gets a result leaves the session in `awaitingToolResults` until the host
  answers, `cancel()`s or `clearHistory()`s.
* The thinking row is not expandable while the model is still thinking (`ThinkingTileView`).
* `GemmaCallSyntax` is duplicated in AIChatUI and AIChatKitMLX (independent releases); keep in sync.
