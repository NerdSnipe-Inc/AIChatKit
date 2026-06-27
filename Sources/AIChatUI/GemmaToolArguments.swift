import Foundation

/// Normalizes Gemma 4 native tool argument syntax into valid JSON for Swift tools.
public enum GemmaToolArguments {

    /// Returns valid JSON for tool execution, converting Gemma `call:name{key:<|"|>value<|"|>}` when needed.
    ///
    /// - Parameter raw: Raw argument payload produced by the model.
    /// - Returns: A normalized JSON object string.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        if isValidJSONObject(trimmed) { return trimmed }

        if let inline = extractInlineCallJSON(from: trimmed) {
            return inline
        }

        var body = trimmed
        if body.hasPrefix("{"), body.hasSuffix("}") {
            body = String(body.dropFirst().dropLast())
        }
        let converted = gemmaArgsToJSON(body)
        if isValidJSONObject(converted) { return converted }

        return trimmed
    }

    private static func isValidJSONObject(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func extractInlineCallJSON(from text: String) -> String? {
        guard let callRange = text.range(of: "call:") else { return nil }
        let tail = String(text[callRange.upperBound...])
        guard let braceStart = tail.firstIndex(of: "{"),
              let braceEnd = balancedBraceEnd(in: tail, from: braceStart) else { return nil }

        let argsBody = String(tail[tail.index(after: braceStart)..<braceEnd])
        let json = gemmaArgsToJSON(argsBody)
        return isValidJSONObject(json) ? json : nil
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

    static func gemmaArgsToJSON(_ body: String) -> String {
        var strings: [String] = []
        var working = body

        while let start = working.range(of: #"<|"|>"#) {
            guard let end = working.range(of: #"<|"|>"#, range: start.upperBound..<working.endIndex) else { break }
            strings.append(String(working[start.upperBound..<end.lowerBound]))
            working.replaceSubrange(start.lowerBound..<end.upperBound, with: "\u{0000}\(strings.count - 1)\u{0000}")
        }

        var json = working.replacingOccurrences(
            of: #"(^|[{,]\s*)(\w+)\s*:"#,
            with: "$1\"$2\":",
            options: .regularExpression
        )

        for (idx, value) in strings.enumerated() {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            json = json.replacingOccurrences(of: "\u{0000}\(idx)\u{0000}", with: "\"\(escaped)\"")
        }

        if !json.hasPrefix("{") { json = "{\(json)}" }
        return json
    }
}
