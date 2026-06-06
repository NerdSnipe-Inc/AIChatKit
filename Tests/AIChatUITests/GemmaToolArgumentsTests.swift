import XCTest
@testable import AIChatUI

final class GemmaToolArgumentsTests: XCTestCase {

    func test_normalize_gemmaDelimitedArgs_producesValidJSON() {
        let raw = #"{action:<|"|>memory_recall<|"|>,query:<|"|>Alric Memory App Store description<|"|>}"#
        let normalized = GemmaToolArguments.normalize(raw)
        guard let data = normalized.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected valid JSON, got: \(normalized)")
            return
        }
        XCTAssertEqual(obj["action"] as? String, "memory_recall")
        XCTAssertEqual(obj["query"] as? String, "Alric Memory App Store description")
    }
}
