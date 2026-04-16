import XCTest
import CoreGraphics
import AppKit
@testable import keynotepptx

final class ImageHasherTests: XCTestCase {

    // MARK: - hammingDistance

    func testHammingDistance_identical() {
        let x: UInt64 = 0xDEAD_BEEF_CAFE_BABE
        XCTAssertEqual(ImageHasher.hammingDistance(x, x), 0)
    }

    func testHammingDistance_oneBit() {
        XCTAssertEqual(ImageHasher.hammingDistance(0, 1), 1)
    }

    func testHammingDistance_allBits() {
        XCTAssertEqual(ImageHasher.hammingDistance(0, UInt64.max), 64)
    }

    func testHammingDistance_symmetric() {
        let a: UInt64 = 0x00FF_00FF_00FF_00FF
        let b: UInt64 = 0xFF00_FF00_FF00_FF00
        XCTAssertEqual(ImageHasher.hammingDistance(a, b), ImageHasher.hammingDistance(b, a))
    }

    // MARK: - colorMomentDistance

    func testColorMomentDistance_identical() {
        let v: [Float] = [0.5, 0.1, -0.02, 0.4, 0.08, 0.01, 0.3, 0.12, -0.01]
        XCTAssertEqual(ImageHasher.colorMomentDistance(v, v), 0.0, accuracy: 1e-6)
    }

    func testColorMomentDistance_pythagorean() {
        // 3-4-0 in first two components → Euclidean distance = 5
        var a = [Float](repeating: 0, count: 9)
        let b = [Float](repeating: 0, count: 9)
        a[0] = 3.0; a[1] = 4.0
        XCTAssertEqual(ImageHasher.colorMomentDistance(a, b), 5.0, accuracy: 1e-5)
    }

    func testColorMomentDistance_mismatchedLengths() {
        XCTAssertEqual(
            ImageHasher.colorMomentDistance([Float](repeating: 0, count: 9),
                                            [Float](repeating: 0, count: 8)),
            Float.infinity
        )
    }

    func testColorMomentDistance_emptyArrays() {
        // Both empty: vDSP treats length 0 as identical → distance = 0
        XCTAssertEqual(ImageHasher.colorMomentDistance([], []), 0.0, accuracy: 1e-6)
    }

    // MARK: - aHash

    func testAHash_uniformGrey_isZero() {
        // Every pixel equals the mean → no bits set → hash = 0.
        let image = makeSolid(r: 128, g: 128, b: 128, a: 255)
        XCTAssertEqual(ImageHasher.aHash(from: image), 0)
    }

    func testAHash_nonNil() {
        let image = makeSolid(r: 200, g: 100, b: 50, a: 255)
        XCTAssertNotNil(ImageHasher.aHash(from: image))
    }

    func testAHash_deterministic() {
        let image = makeSolid(r: 80, g: 160, b: 40, a: 255)
        XCTAssertEqual(ImageHasher.aHash(from: image), ImageHasher.aHash(from: image))
    }

    func testAHash_differentImages_differentHashes() {
        // Solid uniform images all produce aHash=0 (no spatial variation), so use real files.
        let dir   = Self.testDataDir
        let url10 = dir.appendingPathComponent("image10.png")
        let url16 = dir.appendingPathComponent("image16.png")
        guard let img10 = ImageRenderer.renderForHashing(url: url10),
              let img16 = ImageRenderer.renderForHashing(url: url16) else {
            XCTFail("could not render test images"); return
        }
        let h10 = ImageHasher.aHash(from: img10)!
        let h16 = ImageHasher.aHash(from: img16)!
        XCTAssertNotEqual(h10, h16, "visually distinct images must have different aHashes")
    }

    private static let testDataDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // keynotepptxTests/
        .deletingLastPathComponent()  // keynotepptx/ (Xcode project root)
        .appendingPathComponent("TestData", isDirectory: true)

    // MARK: - pHash

    func testPHash_nonNil() {
        XCTAssertNotNil(ImageHasher.pHash(from: makeSolid(r: 100, g: 150, b: 200, a: 255)))
    }

    func testPHash_deterministic() {
        let image = makeSolid(r: 80, g: 160, b: 40, a: 255, width: 64, height: 64)
        XCTAssertEqual(ImageHasher.pHash(from: image), ImageHasher.pHash(from: image))
    }

    func testPHash_samePixelValues_sameHash() {
        // Two independently-created identical images must hash the same.
        let a = makeSolid(r: 123, g: 45, b: 67, a: 255)
        let b = makeSolid(r: 123, g: 45, b: 67, a: 255)
        XCTAssertEqual(ImageHasher.pHash(from: a), ImageHasher.pHash(from: b))
    }

    // MARK: - colorMoments

    func testColorMoments_returnsNineElements() {
        let result = ImageHasher.colorMoments(from: makeSolid(r: 200, g: 100, b: 50, a: 255))
        XCTAssertEqual(result?.count, 9)
    }

    func testColorMoments_uniformGrey_zeroVariance() {
        // Solid grey: stddev and skewness for each channel should be ~0.
        let image = makeSolid(r: 128, g: 128, b: 128, a: 255)
        guard let cm = ImageHasher.colorMoments(from: image) else {
            XCTFail("colorMoments returned nil"); return
        }
        // Each channel: [mean, std, skew] × 3 channels
        for ch in 0..<3 {
            XCTAssertEqual(cm[ch * 3 + 1], 0.0, accuracy: 1e-4, "stddev ch\(ch) should be ~0")
            XCTAssertEqual(cm[ch * 3 + 2], 0.0, accuracy: 1e-4, "skewness ch\(ch) should be ~0")
        }
    }

    func testColorMoments_solidRed_meanR_dominates() {
        // Solid red: mean_R must be significantly higher than mean_G and mean_B.
        // (Using DeviceRGB-space colors in makeSolid to avoid P3→DeviceRGB conversion bleed.)
        let image = makeSolid(r: 255, g: 0, b: 0, a: 255)
        guard let cm = ImageHasher.colorMoments(from: image) else {
            XCTFail("colorMoments returned nil"); return
        }
        // mean_R should dominate
        XCTAssertGreaterThan(cm[0], 0.8, "mean_R should be high for solid red")
        XCTAssertGreaterThan(cm[0], cm[3] + 0.5, "mean_R must dominate mean_G")
        XCTAssertGreaterThan(cm[0], cm[6] + 0.5, "mean_R must dominate mean_B")
    }

    func testColorMoments_identical_distanceIsZero() {
        let image = makeSolid(r: 80, g: 160, b: 40, a: 255)
        guard let cm = ImageHasher.colorMoments(from: image) else {
            XCTFail("colorMoments returned nil"); return
        }
        XCTAssertEqual(ImageHasher.colorMomentDistance(cm, cm), 0.0, accuracy: 1e-6)
    }

    // MARK: - Helpers

    private func makeSolid(r: UInt8, g: UInt8, b: UInt8, a: UInt8,
                            width: Int = 64, height: Int = 64) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Use DeviceRGB-space components directly to avoid P3→DeviceRGB conversion.
        let comps: [CGFloat] = [CGFloat(r)/255, CGFloat(g)/255, CGFloat(b)/255, CGFloat(a)/255]
        let color = CGColor(colorSpace: cs, components: comps)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
