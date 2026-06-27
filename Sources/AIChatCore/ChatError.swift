import Foundation

/// Errors surfaced by `ChatProvider` implementations and stream processors.
///
/// These values normalize provider-specific failures so callers can present a
/// consistent UI regardless of backend.
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
}

extension ChatError: LocalizedError {
    /// A human-readable description suitable for chat error banners.
    public var errorDescription: String? {
        switch self {
        case .networkError(let e):            return "Network error: \(e.localizedDescription)"
        case .serverError(let code, let msg): return "Server error \(code): \(msg)"
        case .decodingError(let e):           return "Decoding error: \(e.localizedDescription)"
        case .streamError(let msg):           return "Stream error: \(msg)"
        case .cancelled:                      return "Request cancelled"
        case .invalidConfiguration(let msg):  return "Invalid configuration: \(msg)"
        }
    }
}
