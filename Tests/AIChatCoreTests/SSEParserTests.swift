import XCTest
@testable import AIChatCore

final class SSEParserTests: XCTestCase {

    // Helper: feed lines into parser and collect events
    private func parse(lines: [String]) async throws -> [SSEParser.Event] {
        var events: [SSEParser.Event] = []
        let stream = SSEParser.events(from: AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
        for try await event in stream { events.append(event) }
        return events
    }

    func test_simpleDataEvent() async throws {
        let events = try await parse(lines: ["data: hello", ""])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "hello")
    }

    func test_eventWithTypeAndId() async throws {
        let events = try await parse(lines: [
            "id: 42",
            "event: message",
            "data: world",
            ""
        ])
        XCTAssertEqual(events[0].id, "42")
        XCTAssertEqual(events[0].type, "message")
        XCTAssertEqual(events[0].data, "world")
    }

    func test_commentsAreSkipped() async throws {
        let events = try await parse(lines: [
            ": this is a comment",
            "data: real",
            ""
        ])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "real")
    }

    func test_doneTerminatesStream() async throws {
        let events = try await parse(lines: [
            "data: chunk1",
            "",
            "data: [DONE]",
            ""
        ])
        // [DONE] should not be emitted as an event
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "chunk1")
    }

    func test_multipleEventsInSequence() async throws {
        let events = try await parse(lines: [
            "data: one",
            "",
            "data: two",
            "",
            "data: three",
            ""
        ])
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.data), ["one", "two", "three"])
    }

    func test_multiLineData_joinsWithNewline() async throws {
        let events = try await parse(lines: [
            "data: line1",
            "data: line2",
            ""
        ])
        XCTAssertEqual(events[0].data, "line1\nline2")
    }

    func test_dataColonWithNoSpace() async throws {
        // "data:" with no following space should still work
        let events = try await parse(lines: ["data:hello", ""])
        XCTAssertEqual(events[0].data, "hello")
    }

    func test_emptyLinesWithoutDataDoNotEmitEvent() async throws {
        let events = try await parse(lines: ["", "", "data: actual", ""])
        XCTAssertEqual(events.count, 1)
    }
}
