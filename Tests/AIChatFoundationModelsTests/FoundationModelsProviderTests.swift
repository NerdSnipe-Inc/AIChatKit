import XCTest
@testable import AIChatFoundationModels
import AIChatCore

// FoundationModels requires iOS 26+ / macOS 26+ with Apple Intelligence.
// These tests are intentionally minimal stubs — runtime availability cannot
// be asserted in CI without physical Apple Intelligence-enabled hardware.
final class FoundationModelsProviderTests: XCTestCase {

    @available(macOS 26.0, iOS 26.0, *)
    func test_init_defaultModel() {
        let provider = FoundationModelsProvider()
        XCTAssertEqual(provider.id, "foundation-models")
        XCTAssertEqual(provider.name, "Apple Intelligence")
    }
}
