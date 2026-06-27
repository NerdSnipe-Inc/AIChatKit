import Foundation

/// Recovers tool calls and strips Gemma 4 channel markup leaked into assistant text.
public enum GemmaOutputRecovery {

    /// Parse tool calls from assistant text. Handles three formats:
    ///   1. Inline `call:name{...}` (Gemma 4 native)
    ///   2. `<tool_call>{JSON}</tool_call>` XML blocks
    ///   3. ` ```tool_code\nname(args)\n``` ` Python blocks (Gemma 4 Jinja fallback)
    /// `toolSchemas` — optional OpenAI-style spec array for resolving positional Python args.
    public static func parse(
        from text: String,
        toolSchemas: [[String: Any]]? = nil
    ) -> EmbeddedToolCallParser.Result {
        var working = stripChannelMarkup(text)
        var calls: [EmbeddedToolCallParser.ParsedCall] = []

        // 1. Extract tool_code Python blocks first (strips them from text before other passes).
        let pythonResult = extractToolCodeBlocks(from: working, schemas: toolSchemas)
        working = pythonResult.cleaned
        calls.append(contentsOf: pythonResult.calls)

        // 2. Inline call:name{...} format.
        while let (call, rest) = extractInlineCall(from: working) {
            calls.append(call)
            working = rest
        }

        // 3. XML <tool_call>{JSON}</tool_call> format.
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

    // MARK: - tool_code block recovery

    private struct ToolCodeResult {
        let cleaned: String
        let calls: [EmbeddedToolCallParser.ParsedCall]
    }

    /// Extracts ` ```tool_code\n...\n``` ` blocks from text, parses Python-style function
    /// calls inside them, and returns the cleaned text with blocks removed.
    private static func extractToolCodeBlocks(
        from text: String,
        schemas: [[String: Any]]?
    ) -> ToolCodeResult {
        // Match fenced code blocks with language "tool_code" (case-insensitive).
        let pattern = #"```tool_code\s*\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return ToolCodeResult(cleaned: text, calls: [])
        }

        var calls: [EmbeddedToolCallParser.ParsedCall] = []
        var cleaned = text
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let bodyRange = match.range(at: 1)
            let blockRange = match.range(at: 0)
            let body = ns.substring(with: bodyRange)

            // Parse every Python-style function call in the block body.
            let parsed = parsePythonCalls(from: body, schemas: schemas)
            calls.insert(contentsOf: parsed, at: 0)
            cleaned = (cleaned as NSString).replacingCharacters(in: blockRange, with: "")
        }

        return ToolCodeResult(
            cleaned: cleaned.trimmingCharacters(in: .whitespacesAndNewlines),
            calls: calls
        )
    }

    /// Parses one or more Python-style `funcName(...)` calls from a block of text.
    private static func parsePythonCalls(
        from text: String,
        schemas: [[String: Any]]?
    ) -> [EmbeddedToolCallParser.ParsedCall] {
        // Match: identifier followed by ( ... )
        let pattern = #"(\w+)\s*\(([^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        return matches.compactMap { match -> EmbeddedToolCallParser.ParsedCall? in
            guard match.numberOfRanges > 2 else { return nil }
            let name = ns.substring(with: match.range(at: 1))
            let argsRaw = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }

            let argsJSON = pythonArgsToJSON(argsRaw, toolName: name, schemas: schemas)
            return EmbeddedToolCallParser.ParsedCall(name: name, arguments: argsJSON)
        }
    }

    /// Converts a Python arg string to JSON. Handles:
    ///   - Keyword args:  `query="value", key2="v2"` → `{"query":"value","key2":"v2"}`
    ///   - Positional str: `"value"` → first required param name from schema, else `"query"`
    private static func pythonArgsToJSON(
        _ argsRaw: String,
        toolName: String,
        schemas: [[String: Any]]?
    ) -> String {
        let trimmed = argsRaw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "{}" }

        // Try keyword args first: key="value" or key='value' pairs.
        let kwPattern = #"(\w+)\s*=\s*(?:"([^"\\]*(\\.[^"\\]*)*)"|'([^'\\]*(\\.[^'\\]*)*)')"#
        if let kwRegex = try? NSRegularExpression(pattern: kwPattern) {
            let ns = trimmed as NSString
            let matches = kwRegex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                var dict: [String: String] = [:]
                for m in matches {
                    let key = ns.substring(with: m.range(at: 1))
                    // Group 2 = double-quoted value, group 4 = single-quoted value
                    let val = m.range(at: 2).location != NSNotFound
                        ? ns.substring(with: m.range(at: 2))
                        : (m.range(at: 4).location != NSNotFound ? ns.substring(with: m.range(at: 4)) : "")
                    dict[key] = val
                }
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let str = String(data: data, encoding: .utf8) {
                    return str
                }
            }
        }

        // Positional single string arg: "value" or 'value'.
        let posPattern = #"^(?:"([^"\\]*(\\.[^"\\]*)*)"|'([^'\\]*(\\.[^'\\]*)*)')\s*$"#
        if let posRegex = try? NSRegularExpression(pattern: posPattern),
           let match = posRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) {
            let ns = trimmed as NSString
            let value = match.range(at: 1).location != NSNotFound
                ? ns.substring(with: match.range(at: 1))
                : (match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : trimmed)

            // Look up the first required parameter name from the tool schema.
            let paramName = firstParamName(for: toolName, schemas: schemas) ?? "query"
            if let data = try? JSONSerialization.data(withJSONObject: [paramName: value]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }

        return "{}"
    }

    /// Returns the first required (or first defined) parameter name for a tool from its schema.
    private static func firstParamName(
        for toolName: String,
        schemas: [[String: Any]]?
    ) -> String? {
        guard let schemas else { return nil }
        for spec in schemas {
            guard let fn = spec["function"] as? [String: Any],
                  fn["name"] as? String == toolName,
                  let params = fn["parameters"] as? [String: Any],
                  let props = params["properties"] as? [String: Any]
            else { continue }

            // Prefer the first required param, then any param.
            let required = (params["required"] as? [String]) ?? []
            if let first = required.first { return first }
            return props.keys.first
        }
        return nil
    }

}
