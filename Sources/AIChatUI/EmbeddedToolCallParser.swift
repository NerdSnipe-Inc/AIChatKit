import Foundation

/// Recovers tool calls the model emitted as plain `<tool_call>{...}</tool_call>` text
/// instead of native Gemma tool tokens (common when a LoRA was trained on XML tool format).
public enum EmbeddedToolCallParser {
    public struct ParsedCall: Sendable {
        public let name: String
        public let arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public struct Result: Sendable {
        public let cleanedText: String
        public let calls: [ParsedCall]

        public init(cleanedText: String, calls: [ParsedCall]) {
            self.cleanedText = cleanedText
            self.calls = calls
        }
    }

    private static let blockPattern = #"<tool_call>\s*(\{[\s\S]*?\})\s*</tool_call>"#

    public static func parse(from text: String) -> Result {
        guard let regex = try? NSRegularExpression(pattern: blockPattern, options: []) else {
            return Result(cleanedText: text, calls: [])
        }

        var calls: [ParsedCall] = []
        var cleaned = text
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let jsonRange = match.range(at: 1)
            let fullRange = match.range(at: 0)
            let json = ns.substring(with: jsonRange)
            if let call = parseJSONObject(json) {
                calls.insert(call, at: 0)
            }
            cleaned = (cleaned as NSString).replacingCharacters(in: fullRange, with: "")
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(cleanedText: cleaned, calls: calls)
    }

    private static func parseJSONObject(_ json: String) -> ParsedCall? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String else { return nil }

        let args: String
        if let argObj = obj["arguments"] {
            if let argData = try? JSONSerialization.data(withJSONObject: argObj),
               let str = String(data: argData, encoding: .utf8) {
                args = str
            } else {
                args = "{}"
            }
        } else {
            args = "{}"
        }
        return ParsedCall(name: name, arguments: args)
    }
}
