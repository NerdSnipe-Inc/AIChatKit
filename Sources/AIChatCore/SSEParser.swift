import Foundation

/// Parses Server-Sent Events from a stream of text lines.
///
/// Conforms to the SSE spec (https://html.spec.whatwg.org/multipage/server-sent-events.html):
/// fields are separated by `:`, events are delimited by blank lines, `[DONE]` terminates the stream.
public struct SSEParser {

    /// A parsed Server-Sent Events frame.
    public struct Event: Sendable {
        /// Optional SSE `id` field. Persists across events per spec.
        public let id: String?
        /// Optional SSE `event` field.
        public let type: String?
        /// Concatenated payload from one or more `data:` lines.
        public let data: String
    }

    /// Reads `URLSession.AsyncBytes` byte-by-byte and yields one `String` per line,
    /// **including empty strings for blank lines**.
    ///
    /// `AsyncLineSequence` (`bytes.lines`) silently discards empty lines, which breaks
    /// SSE framing — the spec uses blank lines as event delimiters.  Use this instead of
    /// `bytes.lines` whenever the stream carries SSE events.
    public static func lines(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer: [UInt8] = []
                do {
                    for try await byte in bytes {
                        if byte == 0x0A { // \n
                            if buffer.last == 0x0D { buffer.removeLast() } // strip \r from \r\n
                            continuation.yield(String(bytes: buffer, encoding: .utf8) ?? "")
                            buffer = []
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(String(bytes: buffer, encoding: .utf8) ?? "")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Parse events from any async sequence of lines (use `SSEParser.lines(from:)` rather than
    /// `bytes.lines` to avoid silent blank-line dropping).
    public static func events<Lines: AsyncSequence & Sendable>(
        from lines: Lines
    ) -> AsyncThrowingStream<Event, Error> where Lines.Element == String {
        AsyncThrowingStream { continuation in
            let task = Task {
                var currentId: String? = nil
                var currentType: String? = nil
                var dataBuffer: [String] = []

                do {
                    for try await line in lines {
                        try Task.checkCancellation()

                        if line.isEmpty {
                            // Blank line = dispatch event (if data present)
                            if !dataBuffer.isEmpty {
                                let data = dataBuffer.joined(separator: "\n")
                                guard data != "[DONE]" else {
                                    continuation.finish()
                                    return
                                }
                                continuation.yield(Event(id: currentId, type: currentType, data: data))
                            }
                            dataBuffer = []
                            currentType = nil
                            // Note: `id` persists across events per spec
                        } else if line.hasPrefix(":") {
                            // Comment — skip
                        } else {
                            let (field, value) = parseField(line)
                            switch field {
                            case "data":  dataBuffer.append(value)
                            case "event": currentType = value
                            case "id":    currentId = value.isEmpty ? nil : value
                            default:      break
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ChatError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Private

    private static func parseField(_ line: String) -> (String, String) {
        guard let colonIndex = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let field = String(line[line.startIndex..<colonIndex])
        let rest  = line[line.index(after: colonIndex)...]
        let value = rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
        return (field, value)
    }
}
