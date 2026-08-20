import XCTest
@testable import AIChatFoundationModels
import AIChatCore
import FoundationModels

// FoundationModels requires iOS 26+ / macOS 26+ with Apple Intelligence.
// Live generation (`stream`/`complete`, backed by `LanguageModelSession`) cannot be exercised in
// CI without physical Apple Intelligence-enabled hardware, so `test_init_defaultModel` remains the
// only test touching the live surface. Everything below tests the pure transcript-building,
// role-mapping, and stream-diffing logic that `stream(...)` delegates to — none of it needs a
// live session, so it runs unconditionally in CI and guards real regressions in that logic.
@available(macOS 26.0, iOS 26.0, *)
final class FoundationModelsProviderTests: XCTestCase {

    func test_init_defaultModel() {
        let provider = FoundationModelsProvider()
        XCTAssertEqual(provider.id, "foundation-models")
        XCTAssertEqual(provider.name, "Apple Intelligence")
    }

    // MARK: - extractText

    func test_extractText_joinsMultipleTextBlocks() {
        let message = ChatMessage(role: .user, content: [.text("first"), .text("second")])
        XCTAssertEqual(FoundationModelsProvider.extractText(from: message), "first\nsecond")
    }

    func test_extractText_returnsNilForNonTextContent() {
        let message = ChatMessage(
            role: .assistant,
            content: [.toolCall(.init(id: "call_1", name: "lookup", arguments: "{}"))]
        )
        XCTAssertNil(FoundationModelsProvider.extractText(from: message))
    }

    func test_extractText_ignoresNonTextBlocksAmongTextBlocks() {
        let message = ChatMessage(
            role: .assistant,
            content: [.text("kept"), .toolCall(.init(id: "call_1", name: "lookup", arguments: "{}"))]
        )
        XCTAssertEqual(FoundationModelsProvider.extractText(from: message), "kept")
    }

    // MARK: - transcriptEntry role mapping

    func test_transcriptEntry_mapsSystemRoleToInstructions() {
        let entry = FoundationModelsProvider.transcriptEntry(
            role: "system", content: "be helpful", options: GenerationOptions()
        )
        guard case .instructions(let instructions) = entry else {
            return XCTFail("Expected .instructions, got \(String(describing: entry))")
        }
        XCTAssertEqual(segmentText(instructions.segments), "be helpful")
    }

    func test_transcriptEntry_mapsUserRoleToPrompt() {
        let entry = FoundationModelsProvider.transcriptEntry(
            role: "user", content: "hello", options: GenerationOptions()
        )
        guard case .prompt(let prompt) = entry else {
            return XCTFail("Expected .prompt, got \(String(describing: entry))")
        }
        XCTAssertEqual(segmentText(prompt.segments), "hello")
    }

    func test_transcriptEntry_mapsAssistantRoleToResponse() {
        let entry = FoundationModelsProvider.transcriptEntry(
            role: "assistant", content: "hi there", options: GenerationOptions()
        )
        guard case .response(let response) = entry else {
            return XCTFail("Expected .response, got \(String(describing: entry))")
        }
        XCTAssertEqual(segmentText(response.segments), "hi there")
    }

    func test_transcriptEntry_returnsNilForToolRole() {
        // `ChatMessage.Role.tool` has no FoundationModels transcript equivalent — dropped, not
        // mapped to a placeholder entry that would confuse the model about who "said" it.
        let entry = FoundationModelsProvider.transcriptEntry(
            role: "tool", content: "tool output", options: GenerationOptions()
        )
        XCTAssertNil(entry)
    }

    // MARK: - buildTranscript

    func test_buildTranscript_prependsSystemPromptAsInstructions() {
        let transcript = FoundationModelsProvider.buildTranscript(
            from: [], options: GenerationOptions(), systemPrompt: "system rules"
        )
        XCTAssertEqual(transcript.count, 1)
        guard case .instructions = transcript.first else {
            return XCTFail("Expected the sole entry to be .instructions")
        }
    }

    func test_buildTranscript_omitsInstructionsWhenNoSystemPrompt() {
        let messages = [ChatMessage(role: .user, content: "hi")]
        let transcript = FoundationModelsProvider.buildTranscript(
            from: messages, options: GenerationOptions(), systemPrompt: nil
        )
        XCTAssertEqual(transcript.count, 1)
        guard case .prompt = transcript.first else {
            return XCTFail("Expected the sole entry to be .prompt")
        }
    }

    func test_buildTranscript_dropsToolMessagesButKeepsSurroundingOrder() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "call the tool"),
            ChatMessage(toolCallId: "call_1", content: "tool result"),
            ChatMessage(role: .assistant, content: "done"),
        ]
        let transcript = FoundationModelsProvider.buildTranscript(
            from: messages, options: GenerationOptions(), systemPrompt: nil
        )
        // The `.tool` message is dropped entirely — never silently coerced into a `.prompt` or
        // `.response` entry, which would misattribute tool output as something a party "said".
        XCTAssertEqual(transcript.count, 2)
        let entries = Array(transcript)
        guard case .prompt = entries[0] else { return XCTFail("Expected entries[0] == .prompt") }
        guard case .response = entries[1] else { return XCTFail("Expected entries[1] == .response") }
    }

    // MARK: - nextDelta (streaming diff)

    func test_nextDelta_firstSnapshotYieldsWholeText() {
        let (delta, _) = FoundationModelsProvider.nextDelta(fullText: "Hello", position: nil)
        XCTAssertEqual(delta, "Hello")
    }

    func test_nextDelta_subsequentSnapshotYieldsOnlyTheNewSuffix() {
        let first = FoundationModelsProvider.nextDelta(fullText: "Hello", position: nil)
        XCTAssertEqual(first.delta, "Hello")

        let second = FoundationModelsProvider.nextDelta(fullText: "Hello, world", position: first.newPosition)
        XCTAssertEqual(second.delta, ", world")
    }

    func test_nextDelta_unchangedSnapshotYieldsEmptyDelta() {
        let first = FoundationModelsProvider.nextDelta(fullText: "Hello", position: nil)
        let second = FoundationModelsProvider.nextDelta(fullText: "Hello", position: first.newPosition)
        XCTAssertTrue(second.delta.isEmpty)
    }

    // MARK: - Helpers

    private func segmentText(_ segments: [Transcript.Segment]) -> String? {
        for segment in segments {
            if case .text(let textSegment) = segment {
                return textSegment.content
            }
        }
        return nil
    }
}
