import XCTest
@testable import AIChatCore

/// Thread-safe collector for emitter output in tests.
private actor Collector {
    var chunks: [String] = []
    func append(_ s: String) { chunks.append(s) }
    var joined: String { chunks.joined() }
    var count: Int { chunks.count }
}

final class BalancedEmitterTests: XCTestCase {

    func test_add_emitsChunk() async {
        let col = Collector()
        let emitter = BalancedEmitter(duration: 0.05, frequency: 60) { chunk in
            Task { await col.append(chunk) }
        }
        await emitter.add("hello")
        await emitter.wait()
        let result = await col.joined
        XCTAssertEqual(result, "hello")
    }

    func test_multipleAdds_emitAllContent() async {
        let col = Collector()
        let emitter = BalancedEmitter(duration: 0.1, frequency: 60) { chunk in
            Task { await col.append(chunk) }
        }
        await emitter.add("foo")
        await emitter.add("bar")
        await emitter.add("baz")
        await emitter.wait()
        // Brief wait for final Task callbacks to settle
        try? await Task.sleep(for: .milliseconds(50))
        let result = await col.joined
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
            Task { await col.append(chunk) }
        }
        let bigText = String(repeating: "a", count: 500)
        await emitter.add(bigText)
        await emitter.wait()
        try? await Task.sleep(for: .milliseconds(100))
        let total = await col.joined
        let numChunks = await col.count
        XCTAssertEqual(total.count, 500)
        XCTAssertLessThan(numChunks, 500)
    }
}
