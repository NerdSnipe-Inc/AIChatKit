import Foundation

/// Recovers tool calls and strips Gemma 4 channel markup leaked into assistant text.
public enum GemmaOutputRecovery {

    public static func parse(from text: String) -> EmbeddedToolCallParser.Result {
        var working = stripChannelMarkup(text)
        var calls: [EmbeddedToolCallParser.ParsedCall] = []

        while let (call, rest) = extractInlineCall(from: working) {
            calls.append(call)
            working = rest
        }

        let xml = EmbeddedToolCallParser.parse(from: working)
        calls.append(contentsOf: xml.calls)
        return EmbeddedToolCallParser.Result(
            cleanedText: xml.cleanedText,
            calls: calls
        )
    }

    public static func stripChannelMarkup(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "<|channel>thought", with: "")
        s = s.replacingOccurrences(of: "<channel|>", with: "")
        s = s.replacingOccurrences(of: "<|tool_call>", with: "")
        s = s.replacingOccurrences(of: "<tool_call|>", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractInlineCall(from text: String) -> (EmbeddedToolCallParser.ParsedCall, String)? {
        guard let range = text.range(of: "call:") else { return nil }
        let prefix = String(text[..<range.lowerBound])
        let tail = String(text[range.lowerBound...])
        guard let braceStart = tail.firstIndex(of: "{"),
              let braceEnd = balancedBraceEnd(in: tail, from: braceStart) else { return nil }

        let nameStart = tail.index(tail.startIndex, offsetBy: 5)
        let name = String(tail[nameStart..<braceStart])
        guard !name.isEmpty else { return nil }

        let argsBody = String(tail[tail.index(after: braceStart)..<braceEnd])
        let json = GemmaToolArguments.normalize("{\(argsBody)}")

        let rest = prefix + String(tail[tail.index(after: braceEnd)...])
        return (EmbeddedToolCallParser.ParsedCall(name: name, arguments: json), rest)
    }

    private static func balancedBraceEnd(in text: String, from start: String.Index) -> String.Index? {
        guard text[start] == "{" else { return nil }
        var depth = 0
        var i = start
        while i < text.endIndex {
            if text[i] == "{" { depth += 1 }
            else if text[i] == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

}
