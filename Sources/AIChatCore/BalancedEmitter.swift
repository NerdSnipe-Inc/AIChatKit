import Foundation

/// Rate-limits text emission during streaming to prevent SwiftUI from thrashing on every token.
///
/// Inspired by FlowDown's BalancedEmitter. Buffers incoming chunks and drains them at a
/// controlled cadence. Batch size auto-scales with buffer size so large buffers drain
/// quickly even at low frequency settings.
public actor BalancedEmitter {
    private var buffer: String = ""
    private var isRunning: Bool = false
    private var waitContinuation: CheckedContinuation<Void, Never>?

    private let onEmit: @Sendable (String) -> Void
    private var duration: Double
    private var frequency: Int
    private var batchSize: Int = 1

    /// - Parameters:
    ///   - duration: Target total drain time in seconds for a full buffer.
    ///   - frequency: Target number of emit ticks within `duration`.
    ///   - onEmit: Called on each tick with the next chunk of text.
    public init(
        duration: Double = 1.0,
        frequency: Int = 30,
        onEmit: @escaping @Sendable (String) -> Void
    ) {
        self.duration = duration
        self.frequency = frequency
        self.onEmit = onEmit
    }

    /// Add text to the buffer and start draining if not already running.
    public func add(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        buffer += chunk
        batchSize = max(1, Int(ceil(Double(buffer.count) / Double(frequency))))
        startLoopIfNeeded()
    }

    /// Wait until the buffer is fully drained.
    public func wait() async {
        guard !buffer.isEmpty || isRunning else { return }
        await withCheckedContinuation { cont in
            resolveWaiter()
            startLoopIfNeeded()
            if buffer.isEmpty && !isRunning {
                cont.resume()
            } else {
                waitContinuation = cont
            }
        }
    }

    /// Immediately clear the buffer and resolve any pending wait.
    public func cancel() {
        buffer = ""
        resolveWaiter()
    }

    // MARK: - Private

    private func startLoopIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        Task { await drain() }
    }

    private func drain() async {
        let stepDelay = Int((duration * 1_000) / Double(frequency))
        while !buffer.isEmpty {
            let len = min(batchSize, buffer.count)
            let chunk = String(buffer.prefix(len))
            buffer.removeFirst(chunk.count)
            onEmit(chunk)
            if buffer.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(stepDelay))
            // Recalculate batch size as buffer shrinks
            batchSize = max(1, Int(ceil(Double(buffer.count) / Double(frequency))))
        }
        isRunning = false
        resolveWaiter()
    }

    private func resolveWaiter() {
        waitContinuation?.resume()
        waitContinuation = nil
    }
}
