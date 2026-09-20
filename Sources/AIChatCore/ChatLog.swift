import Foundation
import os

/// Logging facility shared by every AIChatKit module.
///
/// Built on `os.Logger` (subsystem `cc.nerdsnipe.AIChatKit`, one logger per ``Category``).
/// Message *content* is never logged at `.info` or above; anything that could contain user text
/// is only emitted at `.debug`, and only while ``debugMode`` is on.
///
/// Enable verbose output with any of:
/// - code: `ChatLog.debugMode = true`
/// - environment: `AICHAT_DEBUG=1`
/// - defaults: `defaults write <bundle-id> AICHAT_DEBUG -bool YES`
///
/// Stream it with:
/// `log stream --predicate 'subsystem == "cc.nerdsnipe.AIChatKit"' --level debug`
public enum ChatLog {
    /// The `os.Logger` subsystem used by all AIChatKit loggers.
    public static let subsystem = "cc.nerdsnipe.AIChatKit"

    /// Logical areas of the kit, each with its own `os.Logger` category.
    public enum Category: String, CaseIterable, Sendable {
        case core, mlx, model, stream, tools, network, persona
    }

    /// UserDefaults key and environment variable name that enable debug mode.
    public static let debugKey = "AICHAT_DEBUG"

    private static let override = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Whether verbose `.debug` logging (request shapes, token counts, timings, raw stream
    /// events, error chains) is on. An explicit assignment wins; otherwise `AICHAT_DEBUG`
    /// (environment, then UserDefaults) decides.
    public static var debugMode: Bool {
        get {
            if let explicit = override.withLock({ $0 }) { return explicit }
            return isTruthy(ProcessInfo.processInfo.environment[debugKey])
                || UserDefaults.standard.bool(forKey: debugKey)
        }
        set { override.withLock { $0 = newValue } }
    }

    /// Clears an explicit ``debugMode`` assignment so the env var / defaults apply again.
    public static func resetDebugMode() { override.withLock { $0 = nil } }

    static func isTruthy(_ value: String?) -> Bool {
        guard let v = value?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(v)
    }

    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) }
    )

    /// The underlying `os.Logger` for a category.
    public static func logger(_ category: Category) -> Logger { loggers[category]! }

    /// Non-sensitive lifecycle information (model loaded, stream finished).
    public static func info(_ category: Category, _ message: String) {
        logger(category).info("\(message, privacy: .public)")
    }

    /// Warnings that did not fail the operation (adapter skipped, fallback used).
    public static func warning(_ category: Category, _ message: String) {
        logger(category).warning("\(message, privacy: .public)")
    }

    /// Failures. Logs the classified summary publicly and the full underlying chain only in debug mode.
    public static func error(_ category: Category, _ message: String, underlying: Error? = nil) {
        logger(category).error("\(message, privacy: .public)")
        if let underlying, debugMode {
            logger(category).debug("underlying: \(errorChain(underlying), privacy: .private)")
        }
    }

    /// Verbose output; a no-op unless ``debugMode`` is on. The autoclosure is not evaluated otherwise.
    /// Interpolated content is marked `.private` since it may include user text.
    public static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        guard debugMode else { return }
        let text = message()
        logger(category).debug("\(text, privacy: .private)")
    }

    /// Renders an error and every `NSUnderlyingError` beneath it, one per line, with domain/code.
    public static func errorChain(_ error: Error) -> String {
        var lines: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 8 {
            lines.append("[\(depth)] \(type(of: error)) \(e.domain)#\(e.code): \(e.localizedDescription)")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return lines.joined(separator: "\n")
    }
}
