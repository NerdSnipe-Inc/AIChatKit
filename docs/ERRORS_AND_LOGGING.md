# Errors and Logging

## Debug logging

`ChatLog` (AIChatCore) wraps `os.Logger` with subsystem `cc.nerdsnipe.AIChatKit` and categories
`core`, `mlx`, `model`, `stream`, `tools`, `network`, `persona`.

- `.info` / `.warning` / `.error`: lifecycle and classified failures. Never contain message content.
- `.debug`: request shapes, token counts, timings, raw stream events and the full underlying error
  chain. Emitted only when debug mode is on; interpolated content is `.private`.

### Enable debug mode

Any one of:

```swift
ChatLog.debugMode = true          // in code (wins over everything else)
```
```sh
AICHAT_DEBUG=1 open MyApp.app      # environment variable (Xcode: scheme > Run > Arguments)
defaults write <bundle-id> AICHAT_DEBUG -bool YES   # UserDefaults
```

### Watch the log

```sh
log stream --predicate 'subsystem == "cc.nerdsnipe.AIChatKit"' --level debug
# one category:
log stream --predicate 'subsystem == "cc.nerdsnipe.AIChatKit" AND category == "model"' --level debug
```

Private (`.private`) fields show as `<private>` unless the app is run under Xcode or you install a
logging profile; that is deliberate because they may contain user text.

## ChatError

Every case has `errorDescription` (user-facing), `failureReason`, `recoverySuggestion`, and
`debugDescription` (includes the underlying error chain). `ChatError.classify(_:modelId:phase:)`
maps raw errors (Hub/HTTP, `URLError`, Metal/MLX allocation failures, decoding) onto these cases;
`MLXProvider` applies it in `loadModel`, `stream` and `complete`.

| Case | Typical cause | User message | How to debug |
|---|---|---|---|
| `modelNotFound(modelId:)` | Typo in model id, private/deleted repo (Hub 404) | "The model "x" could not be found." + check id | Open `https://huggingface.co/<id>`; debug log `model` category shows the Hub error |
| `modelDownloadFailed(modelId:underlying:)` | Offline, timeout, 401/403 gated repo, disk full | "Downloading the model failed: ..." + check connection/disk | `debugDescription` shows the `URLError` code; check HF token for gated models |
| `outOfMemory(underlying:)` | Weights or KV cache exceed unified memory | "Not enough memory to run this model." + smaller model | Compare `MLXProvider.residentWeightBytes`; look for `kIOGPU...OutOfMemory` in chain |
| `modelLoadFailed(modelId:underlying:)` | Corrupt/incomplete cache, config mismatch | "found but could not be loaded" + re-download | Delete `~/.cache/huggingface/hub/models--<org>--<name>`; read chain |
| `unsupportedModel(modelId:reason:)` | Architecture unknown to the MLX runtime | "is not supported" + update or choose another | Check mlx-swift-lm version supports the architecture |
| `templateError(underlying:)` | Jinja chat template rejects roles/tools | "conversation could not be formatted" | Debug log `stream` shows the request shape (roles, tool count) |
| `toolCallParseFailed(_)` | Model emitted malformed tool-call text | "tool call could not be understood" | Raw events in debug log; the payload is not in the user message |
| `generationFailed(underlying:)` | Runtime error during decoding | "failed while generating a reply" | Chain in `debugDescription` |
| `networkError`, `serverError`, `decodingError`, `streamError`, `invalidConfiguration` | Unchanged cloud-provider / setup cases | Unchanged text; now also carry `recoverySuggestion` | Provider logs |
| `cancelled` | Task cancelled / stream dropped | Not an error; do not show | Debug log `Operation cancelled` |

### Cancellation

Cancelling the consuming task (or dropping the stream) cancels generation and finishes the stream
with `ChatError.cancelled`. UI code should treat `.cancelled` as a normal stop, not a failure.

### Adding cases

New cases were added to a public enum; exhaustive `switch`es over `ChatError` in client code need
a `default:` (or the new cases). Prefer showing `errorDescription` plus `recoverySuggestion`.
