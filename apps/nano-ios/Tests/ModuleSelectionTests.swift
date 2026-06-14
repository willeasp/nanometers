import XCTest
@testable import NanoMeters

final class ModuleSelectionTests: XCTestCase {
    func test_parseDefaultsEmptyToScopeAndCanonicalizesOrder() {
        XCTAssertEqual(ModuleSelection.parse("scope"), [.scope])
        XCTAssertEqual(ModuleSelection.parse(""), [.scope])                    // empty → min one
        XCTAssertEqual(ModuleSelection.parse("garbage"), [.scope])            // unknown → min one
        XCTAssertEqual(ModuleSelection.parse("spectrum,scope"), [.scope, .spectrum])   // canonical order
        XCTAssertEqual(ModuleSelection.parse("gonio,spectrum,scope"), [.scope, .gonio, .spectrum])
    }

    func test_toggleAddsAndRemoves() {
        XCTAssertEqual(ModuleSelection.parse(ModuleSelection.toggle("scope", .gonio)), [.scope, .gonio])
        XCTAssertEqual(ModuleSelection.parse(ModuleSelection.toggle("scope,gonio", .gonio)), [.scope])
    }

    func test_minOneInvariant() {
        // Turning off the last remaining module is a no-op.
        XCTAssertEqual(ModuleSelection.parse(ModuleSelection.toggle("scope", .scope)), [.scope])
        let gonioOnly = ModuleSelection.toggle(ModuleSelection.toggle("scope", .gonio), .scope)  // → gonio only
        XCTAssertEqual(ModuleSelection.parse(gonioOnly), [.gonio])
        XCTAssertEqual(ModuleSelection.parse(ModuleSelection.toggle(gonioOnly, .gonio)), [.gonio])  // last stays on
    }
}
