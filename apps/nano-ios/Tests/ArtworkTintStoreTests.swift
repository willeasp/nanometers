import XCTest
import UIKit
@testable import NanoMeters

final class ArtworkTintStoreTests: XCTestCase {
    func test_averageHexOfSolidImageMatches() {
        let size = CGSize(width: 4, height: 4)
        UIGraphicsBeginImageContext(size)
        UIColor(red: 0.94, green: 0.66, blue: 0.41, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        let data = img.pngData()!

        let hex = ArtworkTintStore.averageHex(data)
        XCTAssertNotNil(hex)
        XCTAssertEqual(hex?.first, "#")
        let r = UInt8(hex!.dropFirst().prefix(2), radix: 16) ?? 0
        XCTAssertGreaterThan(r, 0xD0)
    }
    func test_averageHexOfGarbageIsNil() {
        XCTAssertNil(ArtworkTintStore.averageHex(Data([0, 1, 2, 3])))
    }
}
