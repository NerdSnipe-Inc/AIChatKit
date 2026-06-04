import Foundation

public enum ChatError: Error, Sendable {
    case networkError(Error)
    case serverError(statusCode: Int, message: String)
    case decodingError(Error)
    case streamError(String)
    case cancelled
    case invalidConfiguration(String)
}

extension ChatError: LocalizedError {
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
