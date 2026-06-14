import XCTest
import CryptoKit
@testable import NanoMeters

final class PKCETests: XCTestCase {
    func test_challenge_isBase64URLSha256OfVerifier_noPadding() {
        let p = PKCE(verifier: "abc123-_~.verifiertestvaluelongenough0000000000")
        let expected = Data(SHA256.hash(data: Data(p.verifier.utf8)))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(p.challenge, expected)
        XCTAssertEqual(p.method, "S256")
    }
    func test_generated_verifierLengthInRange_andURLSafe() {
        let p = PKCE.generate()
        XCTAssertTrue((43...128).contains(p.verifier.count))
        XCTAssertTrue(p.verifier.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".contains($0) })
        XCTAssertFalse(p.challenge.contains("="))
    }
    func test_state_isRandom() { XCTAssertNotEqual(PKCE.randomState(), PKCE.randomState()) }
}
