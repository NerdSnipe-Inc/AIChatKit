import XCTest
@testable import AIChatUI
import AIChatCore

/// Provider that plays back one script per `stream` call and records the messages it was sent.
final class ScriptedProvider: ChatProvider, @unchecked Sendable {
    enum Step { case event(ChatStreamEvent), pause(ms: Int), fail(Error), hang }
    let id = "scripted"
    let name = "Scripted"
    var zeroResponseMessage: String { "scripted: no response" }

    private let lock = NSLock()
    private var scripts: [[Step]]
    private(set) var received: [[ChatMessage]] = []

    init(_ scripts: [[Step]]) { self.scripts = scripts }

    var callCount: Int { lock.withLock { received.count } }

    func stream(messages: [ChatMessage], model: String, options: ChatRequestOptions)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let script: [Step] = lock.withLock {
            received.append(messages)
            return scripts.isEmpty ? [] : scripts.removeFirst()
        }
        return AsyncThrowingStream { c in
            let task = Task {
                for step in script {
                    switch step {
                    case .event(let e): c.yield(e)
                    case .pause(let ms): try? await Task.sleep(for: .milliseconds(ms))
                    case .fail(let err): c.finish(throwing: err); return
                    case .hang:
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                        c.finish(); return
                    }
                    if Task.isCancelled { c.finish(); return }
                }
                c.yield(.done)
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    func complete(messages: [ChatMessage], model: String, options: ChatRequestOptions) async throws -> ChatCompletionResult {
        ChatCompletionResult(id: nil, model: model, message: ChatMessage(role: .assistant, content: ""), usage: nil, finishReason: .stop)
    }
}

@MainActor
final class ChatSessionLifecycleTests: XCTestCase {
    typealias S = ScriptedProvider.Step

    // MARK: helpers

    private func wait(_ session: ChatSession, timeout: Double = 5, until cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cond(), "condition not met within \(timeout)s")
    }
    private func idle(_ s: ChatSession) async { await wait(s) { !s.isGenerating || s.isAwaitingToolResults } }
    private func fullyIdle(_ s: ChatSession) async { await wait(s) { !s.isGenerating } }

    private func ai(_ s: ChatSession) -> [ChatSession.AIEntry] {
        s.entries.compactMap { if case .aiMessage(let e) = $0 { return e } else { return nil } }
    }
    private func tools(_ s: ChatSession) -> [ChatSession.ToolCallEntry] {
        s.entries.compactMap { if case .toolCall(let e) = $0 { return e } else { return nil } }
    }
    private func acts(_ s: ChatSession) -> [ChatSession.ActivityEntry] {
        s.entries.compactMap { if case .activity(let e) = $0 { return e } else { return nil } }
    }
    private func makeSession(_ p: ScriptedProvider) -> ChatSession { ChatSession(provider: p, model: "m") }

    // MARK: text

    func test_text_finalisesEntryFromRawText_andCommitsHistory() async {
        let p = ScriptedProvider([[.event(.text("Hello")), .event(.text(" world"))], [.event(.text("again"))]])
        let s = makeSession(p)
        XCTAssertTrue(s.send("hi"))
        await fullyIdle(s)
        XCTAssertEqual(ai(s).map(\.text), ["Hello world"])
        XCTAssertFalse(ai(s)[0].isStreaming)
        s.send("second")
        await fullyIdle(s)
        let sent = p.received[1]
        XCTAssertEqual(sent.map(\.role), [.user, .assistant, .user])
    }

    func test_whitespaceOnlyReply_isTreatedAsNoResponse() async {
        let p = ScriptedProvider([[.event(.text("  \n ")) ]])
        let s = makeSession(p)
        s.send("hi")
        await fullyIdle(s)
        XCTAssertTrue(ai(s).isEmpty)
        XCTAssertEqual(acts(s).count, 1)
        XCTAssertTrue(acts(s)[0].text.contains("scripted: no response"))
    }

    func test_reasoningOnly_givesSpecificMessage() async {
        let p = ScriptedProvider([[.event(.reasoning("thinking hard"))]])
        let s = makeSession(p)
        s.send("hi")
        await fullyIdle(s)
        XCTAssertEqual(acts(s).count, 1)
        XCTAssertTrue(acts(s)[0].text.contains("thinking"), acts(s)[0].text)
        XCTAssertFalse(acts(s)[0].text.contains("scripted: no response"))
    }

    func test_sendReturnsFalse_whenBusy_orEmpty() async {
        let p = ScriptedProvider([[.pause(ms: 150), .event(.text("ok"))]])
        let s = makeSession(p)
        XCTAssertFalse(s.send("   "))
        XCTAssertTrue(s.send("one"))
        XCTAssertFalse(s.send("two"))
        await fullyIdle(s)
        XCTAssertEqual(s.entries.filter { if case .userMessage = $0 { return true } else { return false } }.count, 1)
    }

    // MARK: errors

    func test_errorMidStream_keepsPartialText_andShowsInlineError() async {
        let p = ScriptedProvider([[.event(.text("partial answer")), .fail(ChatError.serverError(statusCode: 500, message: "boom"))]])
        let s = makeSession(p)
        s.send("hi")
        await fullyIdle(s)
        XCTAssertEqual(ai(s).first?.text, "partial answer")
        XCTAssertFalse(ai(s).first?.isStreaming ?? true)
        XCTAssertNotNil(s.error)
        XCTAssertEqual(acts(s).count, 1)
        XCTAssertTrue(acts(s)[0].isError)
    }

    func test_errorWithNoOutput_showsInlineError() async {
        let p = ScriptedProvider([[.fail(ChatError.streamError("bad"))]])
        let s = makeSession(p)
        s.send("hi")
        await fullyIdle(s)
        XCTAssertEqual(acts(s).count, 1)
        XCTAssertTrue(acts(s)[0].text.contains("bad"))
    }

    // MARK: tool loop

    func test_toolCall_waitsForHost_thenContinuesWithResult() async {
        let p = ScriptedProvider([
            [.event(.text("Let me check.")), .event(.toolCallComplete(id: "t1", name: "get_weather", arguments: #"{"city":"Paris"}"#))],
            [.event(.text("It is 21C."))],
        ])
        let s = makeSession(p)
        s.send("weather?")
        await wait(s) { s.isAwaitingToolResults }
        XCTAssertTrue(s.isGenerating)
        XCTAssertEqual(p.callCount, 1)
        s.submitToolResult(toolCallId: "t1", content: "21C")
        await fullyIdle(s)
        XCTAssertEqual(p.callCount, 2)
        XCTAssertEqual(tools(s).first?.status, .succeeded)
        XCTAssertEqual(ai(s).map(\.text), ["Let me check.", "It is 21C."])
        // History ordering: text and tool_calls share ONE assistant message, then the tool result.
        let second = p.received[1]
        XCTAssertEqual(second.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(second[1].toolCalls?.map(\.id), ["t1"])
        XCTAssertEqual(second[2].toolCallId, "t1")
    }

    func test_resultSubmittedWhileStillStreaming_isDeferredUntilStreamEnds() async {
        let p = ScriptedProvider([
            [.event(.toolCallComplete(id: "t1", name: "f", arguments: "{}")), .pause(ms: 200), .event(.text("trailing"))],
            [.event(.text("final"))],
        ])
        let s = makeSession(p)
        s.send("go")
        await wait(s) { !self.tools(s).isEmpty }
        s.submitToolResult(toolCallId: "t1", content: "r")          // host is fast
        XCTAssertEqual(p.callCount, 1, "must not restart generation while the first stream is live")
        await fullyIdle(s)
        XCTAssertEqual(p.callCount, 2)
        let second = p.received[1]
        XCTAssertEqual(second.map(\.role), [.user, .assistant, .tool], "tool result must follow the assistant turn that issued the call")
        XCTAssertEqual(ai(s).last?.text, "final")
    }

    func test_parallelToolCalls_continueOnlyAfterLastResult() async {
        let p = ScriptedProvider([
            [.event(.toolCallComplete(id: "a", name: "f", arguments: "{}")), .event(.toolCallComplete(id: "b", name: "f", arguments: "{}"))],
            [.event(.text("both done"))],
        ])
        let s = makeSession(p)
        s.send("go")
        await wait(s) { s.isAwaitingToolResults }
        s.submitToolResult(toolCallId: "a", content: "ra")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(p.callCount, 1, "model must not be re-invoked with a missing tool result")
        XCTAssertTrue(s.isAwaitingToolResults)
        s.submitToolResult(toolCallId: "b", content: "rb", isError: true)
        await fullyIdle(s)
        XCTAssertEqual(p.callCount, 2)
        XCTAssertEqual(p.received[1].map(\.role), [.user, .assistant, .tool, .tool])
        XCTAssertEqual(p.received[1][1].toolCalls?.count, 2)
        XCTAssertEqual(tools(s).map(\.status), [.succeeded, .failed])
    }

    func test_unknownOrDuplicateToolResult_isRejectedWithError() async {
        let p = ScriptedProvider([[.event(.toolCallComplete(id: "a", name: "f", arguments: "{}"))], [.event(.text("ok"))]])
        let s = makeSession(p)
        s.send("go")
        await wait(s) { s.isAwaitingToolResults }
        s.submitToolResult(toolCallId: "zzz", content: "x")
        XCTAssertNotNil(s.error)
        XCTAssertTrue(s.error!.localizedDescription.contains("zzz"))
        XCTAssertEqual(p.callCount, 1)
        s.submitToolResult(toolCallId: "a", content: "x")
        await fullyIdle(s)
        s.submitToolResult(toolCallId: "a", content: "again")      // duplicate
        XCTAssertNotNil(s.error)
        XCTAssertEqual(p.callCount, 2)
    }

    func test_emptyToolResult_getsPlaceholder() async {
        let p = ScriptedProvider([[.event(.toolCallComplete(id: "a", name: "f", arguments: "{}"))], [.event(.text("ok"))]])
        let s = makeSession(p)
        s.send("go")
        await wait(s) { s.isAwaitingToolResults }
        s.submitToolResult(toolCallId: "a", content: "  ")
        await fullyIdle(s)
        let toolMsg = p.received[1].last!
        XCTAssertFalse(toolMsg.content.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined().isEmpty)
    }

    func test_malformedToolArguments_areSanitisedForProvider_butKeptForDisplay() async {
        let p = ScriptedProvider([[.event(.toolCallComplete(id: "a", name: "f", arguments: "{not json"))], [.event(.text("ok"))]])
        let s = makeSession(p)
        s.send("go")
        await wait(s) { s.isAwaitingToolResults }
        XCTAssertEqual(tools(s).first?.arguments, "{not json")
        s.submitToolResult(toolCallId: "a", content: "bad args", isError: true)
        await fullyIdle(s)
        XCTAssertEqual(p.received[1][1].toolCalls?.first?.arguments, "{}")
    }

    func test_embeddedToolCallInText_isRecoveredIntoOneAssistantTurn() async {
        let p = ScriptedProvider([
            [.event(.text(#"Sure. <tool_call>{"name":"lookup","arguments":{"q":"x"}}</tool_call>"#))],
            [.event(.text("done"))],
        ])
        let s = makeSession(p)
        s.send("go")
        await wait(s) { s.isAwaitingToolResults }
        XCTAssertEqual(tools(s).first?.name, "lookup")
        XCTAssertEqual(ai(s).first?.text, "Sure.")
        s.submitToolResult(toolCallId: tools(s)[0].id, content: "r")
        await fullyIdle(s)
        let a = p.received[1][1]
        XCTAssertEqual(a.role, .assistant)
        XCTAssertEqual(a.toolCalls?.first?.name, "lookup")
    }

    // MARK: cancel / clear

    func test_cancelMidStream_settlesEntries_keepsPartial_andSessionIsReusable() async {
        let p = ScriptedProvider([[.event(.reasoning("hmm")), .event(.text("part one")), .hang], [.event(.text("fresh"))]])
        let s = makeSession(p)
        s.send("go")
        await wait(s) { self.ai(s).first?.text.isEmpty == false || s.entries.contains { if case .reasoning = $0 { return true } else { return false } } }
        await wait(s) { !(self.ai(s).first?.text.isEmpty ?? true) }
        s.cancel()
        XCTAssertFalse(s.isGenerating)
        XCTAssertEqual(ai(s).first?.text, "part one")
        XCTAssertFalse(ai(s).first?.isStreaming ?? true)
        for case .reasoning(let r) in s.entries { XCTAssertFalse(r.isThinking) }
        XCTAssertTrue(acts(s).isEmpty)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(ai(s).first?.text, "part one")
        s.send("again")
        await fullyIdle(s)
        XCTAssertEqual(ai(s).map(\.text), ["part one", "fresh"])
        // partial reply was committed so roles alternate
        XCTAssertEqual(p.received[1].map(\.role), [.user, .assistant, .user])
    }

    func test_cancelWhileAwaitingToolResults_failsCalls_andKeepsHistoryValid() async {
        let p = ScriptedProvider([[.event(.toolCallComplete(id: "a", name: "f", arguments: "{}"))], [.event(.text("ok"))]])
        let s = makeSession(p)
        s.send("go")
        await wait(s) { s.isAwaitingToolResults }
        s.cancel()
        XCTAssertFalse(s.isGenerating)
        XCTAssertEqual(tools(s).first?.status, .failed)
        s.send("next")
        await fullyIdle(s)
        // assistant tool_calls is always followed by its (synthetic) result
        XCTAssertEqual(p.received[1].map(\.role), [.user, .assistant, .tool, .user])
    }

    func test_cancelWhenIdle_isNoOp() {
        let s = makeSession(ScriptedProvider([]))
        s.cancel()
        XCTAssertFalse(s.isGenerating)
        XCTAssertTrue(s.entries.isEmpty)
    }

    func test_clearHistory_whileAwaitingTools_resetsSession() async {
        let p = ScriptedProvider([[.event(.toolCallComplete(id: "a", name: "f", arguments: "{}"))], [.event(.text("ok"))]])
        let s = makeSession(p)
        s.send("go")
        await wait(s) { s.isAwaitingToolResults }
        s.clearHistory()
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertFalse(s.isGenerating)
        s.send("fresh")
        await fullyIdle(s)
        XCTAssertEqual(p.received[1].map(\.role), [.user])
    }
}
