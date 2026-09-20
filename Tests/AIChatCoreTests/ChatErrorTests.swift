import XCTest
@testable import AIChatCore

/// Fault-injection tests for `ChatError` messages and `ChatError.classify` (no model needed).
final class ChatErrorTests: XCTestCase {

    private struct Opaque: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func classify(_ e: Error, phase: ChatError.Phase = .load) -> ChatError {
        ChatError.classify(e, modelId: "org/model", phase: phase)
    }

    // MARK: Classification

    func test_cancellation_mapsToCancelled() {
        guard case .cancelled = classify(CancellationError()) else { return XCTFail() }
        guard case .cancelled = classify(URLError(.cancelled)) else { return XCTFail() }
    }

    func test_existingChatError_passesThrough() {
        guard case .streamError("x") = classify(ChatError.streamError("x")) else { return XCTFail() }
    }

    func test_urlErrorOffline_duringLoad_isDownloadFailed() {
        for code in [URLError.notConnectedToInternet, .timedOut, .cannotFindHost, .networkConnectionLost] {
            guard case .modelDownloadFailed(let id, _) = classify(URLError(code)) else {
                return XCTFail("\(code)")
            }
            XCTAssertEqual(id, "org/model")
        }
    }

    func test_hub404_isModelNotFound() {
        guard case .modelNotFound(let id) = classify(Opaque(message: "HTTP 404: Repository not found")) else { return XCTFail() }
        XCTAssertEqual(id, "org/model")
    }

    func test_hub401_isDownloadFailed() {
        guard case .modelDownloadFailed = classify(Opaque(message: "401 Unauthorized: access token required")) else { return XCTFail() }
    }

    func test_missingLocalFile_duringLoad_isLoadFailedNotNotFound() {
        let e = CocoaError(.fileReadNoSuchFile)
        guard case .modelLoadFailed = classify(e) else { return XCTFail() }
    }

    func test_metalAllocationFailure_isOutOfMemory() {
        for phase in [ChatError.Phase.load, .generate] {
            guard case .outOfMemory = classify(Opaque(message: "[metal::malloc] Unable to allocate 9 GB: out of memory"), phase: phase) else { return XCTFail() }
        }
        guard case .outOfMemory = classify(Opaque(message: "Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)"), phase: .generate) else { return XCTFail() }
    }

    func test_unsupportedModelType() {
        guard case .unsupportedModel(_, let reason) = classify(Opaque(message: "Unsupported model type: foo")) else { return XCTFail() }
        XCTAssertFalse(reason.isEmpty)
    }

    func test_templateFailure() {
        guard case .templateError = classify(Opaque(message: "Jinja template error: unexpected role sequence"), phase: .generate) else { return XCTFail() }
    }

    func test_decodingError_duringLoadVsGenerate() {
        let e = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad config"))
        guard case .modelLoadFailed = classify(e, phase: .load) else { return XCTFail() }
        guard case .decodingError = classify(e, phase: .generate) else { return XCTFail() }
    }

    func test_unknownErrors_fallBackByPhase() {
        guard case .modelLoadFailed = classify(Opaque(message: "boom"), phase: .load) else { return XCTFail() }
        guard case .generationFailed = classify(Opaque(message: "boom"), phase: .generate) else { return XCTFail() }
    }

    func test_underlyingErrorChain_isSearched() {
        let inner = NSError(domain: "MLX", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to allocate buffer"])
        let outer = NSError(domain: "Wrapper", code: 2, userInfo: [NSUnderlyingErrorKey: inner, NSLocalizedDescriptionKey: "load failed"])
        guard case .outOfMemory = classify(outer) else { return XCTFail() }
    }

    // MARK: Messages

    private var allNewCases: [ChatError] {
        let u = Opaque(message: "underlying detail")
        return [
            .modelNotFound(modelId: "org/model"),
            .modelDownloadFailed(modelId: "org/model", underlying: u),
            .outOfMemory(underlying: u),
            .modelLoadFailed(modelId: "org/model", underlying: u),
            .unsupportedModel(modelId: "org/model", reason: "r"),
            .templateError(underlying: u),
            .toolCallParseFailed("{bad"),
            .generationFailed(underlying: u),
        ]
    }

    func test_newCases_haveCompleteUserFacingText() {
        for e in allNewCases {
            XCTAssertFalse(e.errorDescription?.isEmpty ?? true, e.caseName)
            XCTAssertFalse(e.failureReason?.isEmpty ?? true, e.caseName)
            XCTAssertFalse(e.recoverySuggestion?.isEmpty ?? true, e.caseName)
        }
    }

    func test_messages_mentionModelId_andNeverLeakToolCallPayload() {
        XCTAssertTrue(ChatError.modelNotFound(modelId: "org/model").errorDescription!.contains("org/model"))
        XCTAssertFalse(ChatError.toolCallParseFailed("SECRET-PAYLOAD").errorDescription!.contains("SECRET-PAYLOAD"))
    }

    func test_debugDescription_includesUnderlyingChain() {
        let e = ChatError.modelDownloadFailed(modelId: "m", underlying: URLError(.notConnectedToInternet))
        XCTAssertTrue(e.debugDescription.contains("modelDownloadFailed"))
        XCTAssertTrue(e.debugDescription.contains(NSURLErrorDomain))
    }

    func test_cancelled_hasNoRecoverySuggestion() {
        XCTAssertNil(ChatError.cancelled.recoverySuggestion)
    }

    func test_debugMode_explicitOverride() {
        ChatLog.debugMode = true
        XCTAssertTrue(ChatLog.debugMode)
        ChatLog.debugMode = false
        XCTAssertFalse(ChatLog.debugMode)
        ChatLog.resetDebugMode()
        XCTAssertTrue(ChatLog.isTruthy("1"))
        XCTAssertFalse(ChatLog.isTruthy("0"))
    }
}
