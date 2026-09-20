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
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    private static func extractInlineCallJSON(from text: String) -> String? {
        guard let idx = GemmaCallSyntax.nextCallCandidate(in: text),
              case .complete(let call, _) = GemmaCallSyntax.scan(text, at: idx) else { return nil }
        return call.argumentsJSON
    }

    static func gemmaArgsToJSON(_ body: String) -> String {
        GemmaCallSyntax.argumentsJSON(from: body) ?? "{\(body)}"
    }
}
