import XCTest
@testable import AIChatCore

/// Thread-safe collector for emitter output in tests.
///
/// Deliberately synchronous (lock-protected) rather than an actor fed by `Task { await ... }`:
/// `BalancedEmitter` is an actor that calls `onEmit` sequentially, so appending inline keeps the
/// chunks in order and guarantees every chunk is recorded before `wait()` returns. Forwarding each
/// chunk through its own detached `Task` let the tasks run out of order (seen as "helol" for
/// "hello") and after `wait()` had already returned (seen as "hell"), making these tests flaky.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []
    func append(_ s: String) { lock.lock(); chunks.append(s); lock.unlock() }
    var joined: String { lock.lock(); defer { lock.unlock() }; return chunks.joined() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return chunks.count }
}

final class BalancedEmitterTests: XCTestCase {

    func test_add_emitsChunk() async {
        let col = Collector()
        let emitter = BalancedEmitter(duration: 0.05, frequency: 60) { chunk in
            col.append(chunk)
        }
        await emitter.add("hello")
        await emitter.wait()
        let result = col.joined
        XCTAssertEqual(result, "hello")
    }

    func test_multipleAdds_emitAllContent() async {
        let col = Collector()
        let emitter = BalancedEmitter(duration: 0.1, frequency: 60) { chunk in
            col.append(chunk)
        }
        await emitter.add("foo")
        await emitter.add("bar")
        await emitter.add("baz")
        await emitter.wait()
        let result = col.joined
        XCTAssertEqual(result, "foobarbaz")
    }

    func test_wait_resolvesWhenEmpty() async {
        let emitter = BalancedEmitter(duration: 0.05, frequency: 60) { _ in }
        let start = Date()
        await emitter.wait()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func test_cancel_clearsBuffer() async {
        let emitter = BalancedEmitter(duration: 10, frequency: 1) { _ in }
        await emitter.add(String(repeating: "x", count: 10_000))
        await emitter.cancel()
        let start = Date()
        await emitter.wait()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func test_batchSizeAdaptsToBuffer() async {
        let col = Collector()
        let emitter = BalancedEmitter(duration: 0.5, frequency: 10) { chunk in
            col.append(chunk)
        }
        let bigText = String(repeating: "a", count: 500)
        await emitter.add(bigText)
        await emitter.wait()
        let total = col.joined
        let numChunks = col.count
        XCTAssertEqual(total.count, 500)
        XCTAssertLessThan(numChunks, 500)
    }
}
