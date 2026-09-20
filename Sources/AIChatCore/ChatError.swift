import Foundation

/// Errors surfaced by `ChatProvider` implementations and stream processors.
///
/// These values normalize provider-specific failures so callers can present a
/// consistent UI regardless of backend. Use ``errorDescription`` and ``recoverySuggestion``
/// for user-facing text and ``debugDescription`` (with `ChatLog.debugMode`) for diagnostics.
public enum ChatError: Error, Sendable {
    /// Wraps networking failures from `URLSession`.
    case networkError(Error)
    /// Indicates a non-2xx HTTP response from a provider endpoint.
    case serverError(statusCode: Int, message: String)
    /// Indicates malformed payloads or schema mismatches during decoding.
    case decodingError(Error)
    /// Indicates protocol or stream framing failures.
    case streamError(String)
    /// Indicates a user-initiated or task-initiated cancellation.
    case cancelled
    /// Indicates invalid provider configuration before a request is sent.
    case invalidConfiguration(String)

    // MARK: Local-model failures

    /// The model id does not exist on the hub, or is not present on disk.
    case modelNotFound(modelId: String)
    /// Downloading model files failed (offline, timeout, auth, disk space).
    case modelDownloadFailed(modelId: String, underlying: Error)
    /// The device ran out of (GPU/unified) memory loading or running the model.
    case outOfMemory(underlying: Error?)
    /// Model files were found but could not be loaded (corrupt weights, mismatched config).
    case modelLoadFailed(modelId: String, underlying: Error)
    /// The model architecture or format is not supported by the installed runtime.
    case unsupportedModel(modelId: String, reason: String)
    /// The chat template failed to render the conversation.
    case templateError(underlying: Error)
    /// The model emitted a tool call that could not be parsed.
    case toolCallParseFailed(String)
    /// Generation failed after the model was loaded.
    case generationFailed(underlying: Error)
}

extension ChatError: LocalizedError {
    /// A plain-English, user-facing description suitable for chat error banners.
    public var errorDescription: String? {
        switch self {
        case .networkError(let e):            return "Network error: \(e.localizedDescription)"
        case .serverError(let code, let msg): return "Server error \(code): \(msg)"
        case .decodingError(let e):           return "Decoding error: \(e.localizedDescription)"
        case .streamError(let msg):           return "Stream error: \(msg)"
        case .cancelled:                      return "Request cancelled"
        case .invalidConfiguration(let msg):  return "Invalid configuration: \(msg)"
        case .modelNotFound(let id):
            return "The model \"\(id)\" could not be found, or you don't have access to it."
        case .modelDownloadFailed(let id, let e):
            return "Downloading the model \"\(id)\" failed: \(Self.brief(e))"
        case .outOfMemory:
            return "Not enough memory to run this model."
        case .modelLoadFailed(let id, let e):
            return "The model \"\(id)\" was found but could not be loaded: \(Self.brief(e))"
        case .unsupportedModel(let id, let reason):
            return "The model \"\(id)\" is not supported: \(reason)"
        case .templateError:
            return "The conversation could not be formatted for this model."
        case .toolCallParseFailed:
            return "The model produced a tool call that could not be understood."
        case .generationFailed(let e):
            return "The model failed while generating a reply: \(Self.brief(e))"
        }
    }

    /// Why the failure happened, without the fix.
    public var failureReason: String? {
        switch self {
        case .modelNotFound:            return "The model id is not on the Hugging Face hub or in the local cache."
        case .modelDownloadFailed:      return "The model files could not be fetched."
        case .outOfMemory:              return "The model's weights or its KV cache did not fit in available memory."
        case .modelLoadFailed:          return "The downloaded files are incomplete, corrupt, or do not match the model config."
        case .unsupportedModel:         return "The installed MLX runtime does not know this architecture."
        case .templateError:            return "The model's chat template rejected the messages or tool definitions."
        case .toolCallParseFailed:      return "The tool-call text did not match the expected format."
        case .generationFailed:         return "An error was raised by the MLX runtime during decoding."
        case .networkError:             return "A network request failed."
        case .serverError:              return "The provider returned an error response."
        case .decodingError:            return "The provider's response did not match the expected schema."
        case .streamError:              return "The response stream was malformed or ended unexpectedly."
        case .cancelled:                return "The request was cancelled."
        case .invalidConfiguration:     return "The provider was configured incorrectly."
        }
    }

    /// An actionable next step for the user.
    public var recoverySuggestion: String? {
        switch self {
        case .modelNotFound:
            return "Check the model id for typos (expected form: \"org/name\"). Private or gated models need a Hugging Face access token."
        case .modelDownloadFailed:
            return "Check your internet connection and free disk space, then try again. Private models need a Hugging Face access token."
        case .outOfMemory:
            return "Quit other apps, or choose a smaller or more heavily quantized model."
        case .modelLoadFailed:
            return "Delete the model's cached files and download it again."
        case .unsupportedModel:
            return "Update the app, or choose a different model."
        case .templateError:
            return "Try a new conversation. If it persists, the model's chat template may not support tools or system prompts."
        case .toolCallParseFailed:
            return "Try sending the message again."
        case .generationFailed:
            return "Try again. If it keeps failing, reload the model."
        case .networkError:
            return "Check your internet connection and try again."
        case .serverError(let code, _):
            return (code == 401 || code == 403) ? "Check your API key." : "Try again in a moment."
        case .decodingError, .streamError:
            return "Try again. If it persists, enable debug logging (AICHAT_DEBUG=1) and file a report."
        case .cancelled:
            return nil
        case .invalidConfiguration:
            return "Review the provider settings."
        }
    }

    private static func brief(_ error: Error) -> String {
        if let chat = error as? ChatError, let d = chat.errorDescription { return d }
        // `localizedDescription` on a Swift-native error that isn't `LocalizedError` (e.g. the Hub's
        // `HTTPClientError`) collapses to "The operation couldn't be completed. (… error 1.)" —
        // useless for debugging. Prefer the type's own readable description when it has one.
        if error is LocalizedError { return error.localizedDescription }
        if let described = error as? CustomStringConvertible { return described.description }
        return error.localizedDescription
    }

    /// The HTTP status embedded in a Hub/HTTP error description such as
    /// "Response error (Status 404): …", or `nil` when there isn't one.
    static func httpStatus(in text: String) -> Int? {
        // Matches "Status 404", "status=401" and the Hub's own "HubApi.httpStatusCode(404)".
        guard let range = text.range(of: #"status(?: ?code)?[ :=(]+(\d{3})"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(text[range].filter(\.isNumber))
    }
}

extension ChatError: CustomDebugStringConvertible {
    /// Full diagnostic text including the underlying error chain. Intended for logs, not UI.
    public var debugDescription: String {
        var text = "ChatError.\(caseName): \(errorDescription ?? "")"
        if let reason = failureReason { text += "\n  reason: \(reason)" }
        if let e = underlyingError { text += "\n  underlying:\n" + ChatLog.errorChain(e).split(separator: "\n").map { "    \($0)" }.joined(separator: "\n") }
        return text
    }

    /// The wrapped error, when this case carries one.
    public var underlyingError: Error? {
        switch self {
        case .networkError(let e), .decodingError(let e),
             .modelDownloadFailed(_, let e), .modelLoadFailed(_, let e),
             .templateError(let e), .generationFailed(let e):
            return e
        case .outOfMemory(let e): return e
        default: return nil
        }
    }

    /// Stable case name for logs and tests.
    public var caseName: String {
        switch self {
        case .networkError: return "networkError"
        case .serverError: return "serverError"
        case .decodingError: return "decodingError"
        case .streamError: return "streamError"
        case .cancelled: return "cancelled"
        case .invalidConfiguration: return "invalidConfiguration"
        case .modelNotFound: return "modelNotFound"
        case .modelDownloadFailed: return "modelDownloadFailed"
        case .outOfMemory: return "outOfMemory"
        case .modelLoadFailed: return "modelLoadFailed"
        case .unsupportedModel: return "unsupportedModel"
        case .templateError: return "templateError"
        case .toolCallParseFailed: return "toolCallParseFailed"
        case .generationFailed: return "generationFailed"
        }
    }
}

// MARK: - Classification

extension ChatError {
    /// Phase in which a raw local-model error occurred; steers classification of ambiguous errors.
    public enum Phase: Sendable { case load, generate }

    /// Maps an arbitrary error thrown by MLX / Hub / Foundation into a specific ``ChatError``.
    ///
    /// Already-classified `ChatError`s pass through; `CancellationError` and `URLError.cancelled`
    /// become ``cancelled``. Unknown load errors become ``modelLoadFailed`` and unknown
    /// generation errors ``generationFailed``, so nothing stays opaque.
    public static func classify(_ error: Error, modelId: String, phase: Phase) -> ChatError {
        if let chat = error as? ChatError { return chat }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return .cancelled }

        // Search the whole chain (message + domain) since MLX/Hub errors are often untyped.
        var chain: [NSError] = []
        var cur: NSError? = ns
        while let e = cur, chain.count < 8 { chain.append(e); cur = e.userInfo[NSUnderlyingErrorKey] as? NSError }
        let text = chain.map { "\($0.domain) \($0.localizedDescription) \(String(describing: $0.userInfo[NSLocalizedFailureReasonErrorKey] ?? ""))" }
            .joined(separator: " | ").lowercased()
        let typeText = String(describing: type(of: error)).lowercased() + " " + String(describing: error).lowercased()
        let all = text + " | " + typeText

        func has(_ needles: String...) -> Bool { needles.contains { all.contains($0) } }

        if has("out of memory", "outofmemory", "failed to allocate", "insufficient memory",
               "kiogpucommandbufferallocationfail", "metal allocation", "cannot allocate memory", "std::bad_alloc") {
            return .outOfMemory(underlying: error)
        }
        if has("chat template", "jinja", "template") && (has("error", "fail", "unable", "cannot") || phase == .generate) {
            return .templateError(underlying: error)
        }
        if has("unsupported model type", "unsupportedmodeltype", "unsupported model", "nomodelfactoryavailable",
               "no model factory", "unknown model type", "unsupported architecture") {
            return .unsupportedModel(modelId: modelId, reason: "the installed MLX runtime has no loader for this architecture")
        }
        // The Hub answers 401 (not 404) for a repo that doesn't exist when the caller is
        // unauthenticated, so 401/403/404 are all reported as "not found or no access" rather than
        // as a connectivity problem. `HTTPClientError` bridges to an opaque NSError, so the status
        // is recovered from its Swift description.
        if phase == .load, let status = httpStatus(in: String(describing: error)) ?? httpStatus(in: all),
           [401, 403, 404].contains(status) {
            return .modelNotFound(modelId: modelId)
        }
        if let chain = chain.first(where: { $0.domain == NSURLErrorDomain }), phase == .load {
            _ = chain
            return .modelDownloadFailed(modelId: modelId, underlying: error)
        }
        // Only real Hub "no such repo" signals map here. A bare "not found" / "does not exist" is far
        // too broad — e.g. "weight key X not found" or a missing local file is a load failure whose
        // cause must be kept (`.modelNotFound` carries no underlying error, so misfiling those
        // silently discards the real reason).
        if has("repository not found", "repo not found", "revision not found", "invalid repository", "http 404") {
            // A missing local file during load means damaged/missing weights, not a bad id.
            if phase == .load, ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
                return .modelLoadFailed(modelId: modelId, underlying: error)
            }
            return .modelNotFound(modelId: modelId)
        }
        if has("401", "403", "unauthorized", "forbidden", "gated", "access token", "authentication") && phase == .load {
            return .modelDownloadFailed(modelId: modelId, underlying: error)
        }
        if has("offline", "timed out", "network connection", "could not connect", "no space left", "not enough space",
               "hf hub", "hub api", "download") && phase == .load {
            return .modelDownloadFailed(modelId: modelId, underlying: error)
        }
        if error is DecodingError { return phase == .load ? .modelLoadFailed(modelId: modelId, underlying: error) : .decodingError(error) }
        switch phase {
        case .load:     return .modelLoadFailed(modelId: modelId, underlying: error)
        case .generate: return .generationFailed(underlying: error)
        }
    }
}
