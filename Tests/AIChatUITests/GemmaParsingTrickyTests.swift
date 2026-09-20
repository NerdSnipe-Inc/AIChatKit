import XCTest
@testable import AIChatUI

/// Tricky inputs for the text-level Gemma tool-call recovery (`GemmaToolArguments`,
/// `GemmaOutputRecovery`): quoting, nesting, multiple calls, prose that merely looks like a call.
final class GemmaParsingTrickyTests: XCTestCase {

    private func obj(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            XCTFail("not a JSON object: \(json)", file: file, line: line); return [:]
        }
        return o
    }

    // MARK: GemmaToolArguments

    func test_normalize_stringWithBracesCommasAndQuotes() {
        let raw = "{code:<|\"|>if (a) { b(\"x\", 1); }<|\"|>,n:2}"
        let o = obj(GemmaToolArguments.normalize(raw))
        XCTAssertEqual(o["code"] as? String, "if (a) { b(\"x\", 1); }")
        XCTAssertEqual(o["n"] as? Int, 2)
    }

    func test_normalize_nestedObjectsAndArrays() {
        let o = obj(GemmaToolArguments.normalize(#"{a:{b:{c:<|"|>deep<|"|>}},list:[1,2,<|"|>three<|"|>]}"#))
        XCTAssertEqual(((o["a"] as? [String: Any])?["b"] as? [String: Any])?["c"] as? String, "deep")
        XCTAssertEqual((o["list"] as? [Any])?.count, 3)
    }

    func test_normalize_backslashesAndNewlinesInStrings() {
        let o = obj(GemmaToolArguments.normalize("{p:<|\"|>C:\\dir\\file\nline2<|\"|>}"))
        XCTAssertEqual(o["p"] as? String, "C:\\dir\\file\nline2")
    }

    func test_normalize_validJSONPassesThroughUntouched() {
        let raw = #"{"a":1,"b":[true,null]}"#
        XCTAssertEqual(GemmaToolArguments.normalize(raw), raw)
    }

    func test_normalize_truncatedJSON_isNotClaimedValid() {
        // Cannot be repaired into an object; callers (ChatSession) sanitise it for providers.
        let out = GemmaToolArguments.normalize(#"{"city": "Par"#)
        XCTAssertNil(try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    func test_normalize_emptyAndWhitespace() {
        XCTAssertEqual(GemmaToolArguments.normalize(""), "{}")
        XCTAssertEqual(GemmaToolArguments.normalize("  \n"), "{}")
    }

    func test_normalize_jsonArrayIsNotAValidArgumentObject() {
        // A top-level array must not be passed through as "valid arguments".
        let out = GemmaToolArguments.normalize("[1,2,3]")
        XCTAssertNil(try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    // MARK: GemmaOutputRecovery

    func test_recovery_multipleInlineCalls() {
        let r = GemmaOutputRecovery.parse(from: #"call:a{x:<|"|>1<|"|>} call:b{y:<|"|>2<|"|>}"#)
        XCTAssertEqual(r.calls.map(\.name), ["a", "b"])
        XCTAssertTrue(r.cleanedText.isEmpty)
    }

    func test_recovery_stringArgContainingBraceDoesNotTruncateCall() {
        let r = GemmaOutputRecovery.parse(from: "call:w{body:<|\"|>}{<|\"|>,k:1} tail")
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(obj(r.calls[0].arguments)["body"] as? String, "}{")
        XCTAssertEqual(r.cleanedText, "tail")
    }

    func test_recovery_proseWithCallColonIsUntouched() {
        for prose in ["Give me a call: 555-1234", "I recall:{not a call}", "callback:{x:1}", "Please call: {now}"] {
            let r = GemmaOutputRecovery.parse(from: prose)
            XCTAssertTrue(r.calls.isEmpty, "\(prose) was treated as a tool call")
            XCTAssertEqual(r.cleanedText, prose)
        }
    }

    func test_recovery_xmlToolCallWithEscapedQuotesAndNestedJSON() {
        let src = #"<tool_call>{"name":"save","arguments":{"text":"He said \"hi\"","meta":{"tags":["a","b"]}}}</tool_call>"#
        let r = GemmaOutputRecovery.parse(from: src)
        XCTAssertEqual(r.calls.count, 1)
        let a = obj(r.calls[0].arguments)
        XCTAssertEqual(a["text"] as? String, #"He said "hi""#)
        XCTAssertEqual((a["meta"] as? [String: Any])?["tags"] as? [String], ["a", "b"])
    }

    func test_recovery_multipleXmlCalls_keepOrder() {
        let src = #"<tool_call>{"name":"a","arguments":{}}</tool_call>between<tool_call>{"name":"b","arguments":{}}</tool_call>"#
        let r = GemmaOutputRecovery.parse(from: src)
        XCTAssertEqual(r.calls.map(\.name), ["a", "b"])
        XCTAssertEqual(r.cleanedText, "between")
    }

    func test_recovery_plainAnswerWithBracesAndAngleBrackets_isUntouched() {
        let text = "Use `{ key: value }` and <b>bold</b>; a < b | c."
        let r = GemmaOutputRecovery.parse(from: text)
        XCTAssertTrue(r.calls.isEmpty)
        XCTAssertEqual(r.cleanedText, text)
    }
}
