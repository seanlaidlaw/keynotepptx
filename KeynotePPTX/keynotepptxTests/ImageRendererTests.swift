import XCTest
import CoreGraphics
import AppKit
@testable import keynotepptx

final class ImageRendererTests: XCTestCase {

    private static let testDataDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // keynotepptxTests/
        .deletingLastPathComponent()  // keynotepptx/ (Xcode project root)
        .appendingPathComponent("TestData", isDirectory: true)

    // MARK: - backgroundForCompositing

    func testBackground_allWhiteOpaque_returnsBlack() {
        // All opaque pixels are white → content would disappear on white BG → use black.
        let result = ImageRenderer.backgroundForCompositing(makeSolid(r: 255, g: 255, b: 255, a: 255))
        assertColorIsBlack(result)
    }

    func testBackground_grey_returnsWhite() {
        // 50% grey: un-premultiplied value 128 < 240 threshold → returns white.
        let result = ImageRenderer.backgroundForCompositing(makeSolid(r: 128, g: 128, b: 128, a: 255))
        assertColorIsWhite(result)
    }

    func testBackground_coloredPixel_returnsWhite() {
        let result = ImageRenderer.backgroundForCompositing(makeSolid(r: 255, g: 0, b: 0, a: 255))
        assertColorIsWhite(result)
    }

    func testBackground_fullyTransparent_returnsWhite() {
        // No opaque pixels → hasOpaque = false → falls back to white.
        let result = ImageRenderer.backgroundForCompositing(makeSolid(r: 0, g: 0, b: 0, a: 0))
        assertColorIsWhite(result)
    }

    func testBackground_alphaBelowThreshold_returnsWhite() {
        // Alpha = 8 ≤ threshold of 10 → pixel is skipped → effectively transparent → white.
        let result = ImageRenderer.backgroundForCompositing(makeSolid(r: 255, g: 255, b: 255, a: 8))
        assertColorIsWhite(result)
    }

    // MARK: - flattenForHashing

    func testFlattenForHashing_isOpaque() {
        let src = makeSolid(r: 200, g: 100, b: 50, a: 128)
        guard let result = ImageRenderer.flattenForHashing(src) else {
            XCTFail("flattenForHashing returned nil"); return
        }
        XCTAssertEqual(
            result.alphaInfo, .noneSkipLast,
            "output must have no alpha channel"
        )
    }

    func testFlattenForHashing_preservesDimensions() {
        let src = makeSolid(r: 100, g: 100, b: 100, a: 200, width: 123, height: 77)
        guard let result = ImageRenderer.flattenForHashing(src) else {
            XCTFail("flattenForHashing returned nil"); return
        }
        XCTAssertEqual(result.width, 123)
        XCTAssertEqual(result.height, 77)
    }

    func testFlattenForHashing_nonNilForTransparentInput() {
        let src = makeSolid(r: 0, g: 0, b: 0, a: 0)
        XCTAssertNotNil(ImageRenderer.flattenForHashing(src))
    }

    // MARK: - cgPDFVisibleRect — CropBox test

    func testCgPDFVisibleRect_pfeiferCrop_returnsCropBox() {
        // Pfeifer_PDF_crop.pdf has a CropBox meaningfully smaller than the MediaBox.
        // The visible rect must equal the CropBox and differ from the MediaBox.
        let url = Self.testDataDir.appendingPathComponent("Pfeifer_PDF_crop.pdf")
        guard let doc  = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open Pfeifer_PDF_crop.pdf"); return
        }

        let mediaBox = page.getBoxRect(.mediaBox)
        let cropBox  = page.getBoxRect(.cropBox)
        let visible  = ImageRenderer.cgPDFVisibleRect(page)

        // CropBox must be different from (and smaller than) MediaBox.
        XCTAssertNotEqual(cropBox, mediaBox, "test precondition: PDF must have a distinct CropBox")
        XCTAssertLessThan(cropBox.width, mediaBox.width)

        // cgPDFVisibleRect must choose the CropBox.
        XCTAssertEqual(visible.width,    cropBox.width,    accuracy: 0.001)
        XCTAssertEqual(visible.height,   cropBox.height,   accuracy: 0.001)
        XCTAssertEqual(visible.origin.x, cropBox.origin.x, accuracy: 0.001)
        XCTAssertEqual(visible.origin.y, cropBox.origin.y, accuracy: 0.001)
    }

    func testCgPDFVisibleRect_pdfsWithoutCropBox_returnsMediaBox() {
        // BaP_to_mutagen-1264.pdf has no meaningful CropBox — must fall back to MediaBox.
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1264.pdf")
        guard let doc  = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open BaP_to_mutagen-1264.pdf"); return
        }
        let mediaBox = page.getBoxRect(.mediaBox)
        let visible  = ImageRenderer.cgPDFVisibleRect(page)
        XCTAssertEqual(visible.width,  mediaBox.width,  accuracy: 0.001)
        XCTAssertEqual(visible.height, mediaBox.height, accuracy: 0.001)
    }

    // MARK: - renderPDFPageOpaque

    func testRenderPDFPageOpaque_dimensionsMatchRequest() {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1264.pdf")
        guard let doc  = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open PDF"); return
        }
        let pageRect = ImageRenderer.cgPDFVisibleRect(page)
        let cs       = CGColorSpaceCreateDeviceRGB()
        let scale    = CGFloat(512) / max(pageRect.width, pageRect.height)
        let w = max(1, Int(pageRect.width  * scale))
        let h = max(1, Int(pageRect.height * scale))

        guard let image = ImageRenderer.renderPDFPageOpaque(
            page: page, pageRect: pageRect, scale: scale,
            width: w, height: h, cs: cs
        ) else {
            XCTFail("renderPDFPageOpaque returned nil"); return
        }
        XCTAssertEqual(image.width, w)
        XCTAssertEqual(image.height, h)
    }

    func testRenderPDFPageOpaque_outputIsOpaque() {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1264.pdf")
        guard let doc  = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open PDF"); return
        }
        let pageRect = ImageRenderer.cgPDFVisibleRect(page)
        let cs       = CGColorSpaceCreateDeviceRGB()
        let scale    = CGFloat(128) / max(pageRect.width, pageRect.height)
        let w = max(1, Int(pageRect.width  * scale))
        let h = max(1, Int(pageRect.height * scale))
        guard let image = ImageRenderer.renderPDFPageOpaque(
            page: page, pageRect: pageRect, scale: scale,
            width: w, height: h, cs: cs
        ) else {
            XCTFail("renderPDFPageOpaque returned nil"); return
        }
        XCTAssertEqual(image.alphaInfo, .noneSkipLast, "two-pass flatten must produce opaque output")
    }

    func testRenderPDFPageOpaque_pfeiferCropBox_dimensionsMatchCropBox() {
        // When we pass the CropBox as pageRect, output dimensions must derive from it,
        // not the MediaBox.
        let url = Self.testDataDir.appendingPathComponent("Pfeifer_PDF_crop.pdf")
        guard let doc  = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open Pfeifer_PDF_crop.pdf"); return
        }
        let cropBox = ImageRenderer.cgPDFVisibleRect(page)  // returns CropBox
        let cs      = CGColorSpaceCreateDeviceRGB()
        let scale   = CGFloat(256) / max(cropBox.width, cropBox.height)
        let w = max(1, Int(cropBox.width  * scale))
        let h = max(1, Int(cropBox.height * scale))

        guard let image = ImageRenderer.renderPDFPageOpaque(
            page: page, pageRect: cropBox, scale: scale,
            width: w, height: h, cs: cs
        ) else {
            XCTFail("renderPDFPageOpaque returned nil"); return
        }
        XCTAssertEqual(image.width, w)
        XCTAssertEqual(image.height, h)

        // The MediaBox is ~595 wide; ensure we didn't accidentally use it.
        let mediaBox = page.getBoxRect(.mediaBox)
        let mediaScale = CGFloat(256) / max(mediaBox.width, mediaBox.height)
        let wrongW = max(1, Int(mediaBox.width * mediaScale))
        XCTAssertNotEqual(image.width, wrongW, "output must be cropped width, not MediaBox width")
    }

    // MARK: - renderForHashing

    func testRenderForHashing_pdf_usesCropBox() {
        let url = Self.testDataDir.appendingPathComponent("Pfeifer_PDF_crop.pdf")
        let maxDim = 256

        guard let doc  = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open Pfeifer_PDF_crop.pdf"); return
        }
        let cropBox  = ImageRenderer.cgPDFVisibleRect(page)
        let scale    = CGFloat(maxDim) / max(cropBox.width, cropBox.height)
        let expectedW = max(1, Int(cropBox.width  * scale))
        let expectedH = max(1, Int(cropBox.height * scale))

        guard let result = ImageRenderer.renderForHashing(url: url, maxDim: maxDim) else {
            XCTFail("renderForHashing returned nil"); return
        }
        XCTAssertEqual(result.width,  expectedW)
        XCTAssertEqual(result.height, expectedH)

        // Confirm we're not seeing MediaBox dimensions
        let mediaBox   = page.getBoxRect(.mediaBox)
        let mScale     = CGFloat(maxDim) / max(mediaBox.width, mediaBox.height)
        let mediaWidth = max(1, Int(mediaBox.width * mScale))
        XCTAssertNotEqual(result.width, mediaWidth, "must use CropBox, not MediaBox")
    }

    func testRenderForHashing_raster_maxDimRespected() {
        let url = Self.testDataDir.appendingPathComponent("image10.png")
        guard let result = ImageRenderer.renderForHashing(url: url, maxDim: 256) else {
            XCTFail("renderForHashing returned nil"); return
        }
        XCTAssertLessThanOrEqual(result.width,  256)
        XCTAssertLessThanOrEqual(result.height, 256)
        XCTAssertEqual(max(result.width, result.height), 256)
    }

    func testRenderForHashing_svg_maxDimRespected() {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1266.svg")
        guard let result = ImageRenderer.renderForHashing(url: url, maxDim: 256) else {
            XCTFail("renderForHashing returned nil"); return
        }
        XCTAssertLessThanOrEqual(result.width,  256)
        XCTAssertLessThanOrEqual(result.height, 256)
        XCTAssertEqual(max(result.width, result.height), 256)
    }

    func testRenderForHashing_invalidURL_returnsNil() {
        let url = URL(fileURLWithPath: "/no/such/file.pdf")
        XCTAssertNil(ImageRenderer.renderForHashing(url: url, maxDim: 256))
    }

    // MARK: - renderThumbnail

    func testRenderThumbnail_svgMaxDim260() {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1266.svg")
        guard let result = ImageRenderer.renderThumbnail(url: url) else {
            XCTFail("renderThumbnail returned nil"); return
        }
        XCTAssertLessThanOrEqual(result.width,  260)
        XCTAssertLessThanOrEqual(result.height, 260)
        XCTAssertEqual(max(result.width, result.height), 260)
    }

    // MARK: - renderToPNGData

    func testRenderToPNGData_svg_hasPNGSignatureAndCorrectWidth() throws {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1266.svg")
        let data = try ImageRenderer.renderToPNGData(url: url, widthPx: 512)

        XCTAssertGreaterThan(data.count, 0)

        // PNG magic bytes: \x89PNG\r\n\x1a\n
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(data.prefix(8), pngMagic, "data must start with PNG signature")

        // Decode and check pixel width
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        XCTAssertEqual(decoded?.width, 512)
    }

    func testRenderToPNGData_invalidURL_throws() {
        let url = URL(fileURLWithPath: "/no/such/image.svg")
        XCTAssertThrowsError(try ImageRenderer.renderToPNGData(url: url))
    }

    // MARK: - renderToWebPData

    func testRenderToWebPData_svg_hasWebPSignature() throws {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1266.svg")
        // WebP encoding requires the codec to be registered; skip if not available
        // (e.g. in CLI test environments without an app bundle).
        let data: Data
        do {
            data = try ImageRenderer.renderToWebPData(url: url, widthPx: 256)
        } catch {
            throw XCTSkip("WebP encoding not available in this environment: \(error)")
        }
        XCTAssertGreaterThan(data.count, 12)
        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8), "WebP must begin with RIFF")
        XCTAssertEqual(data[8..<12],   Data("WEBP".utf8), "bytes 8-11 must be WEBP")
    }

    func testRenderToWebPData_invalidURL_throws() {
        let url = URL(fileURLWithPath: "/no/such/image.pdf")
        // If WebP encoding isn't available the error will be about the destination,
        // not the URL — either way a throw is the correct behaviour.
        XCTAssertThrowsError(try ImageRenderer.renderToWebPData(url: url))
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
        // Use DeviceRGB-space components directly to avoid P3→DeviceRGB color conversion.
        let comps: [CGFloat] = [CGFloat(r)/255, CGFloat(g)/255, CGFloat(b)/255, CGFloat(a)/255]
        ctx.setFillColor(CGColor(colorSpace: cs, components: comps)!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func assertColorIsBlack(_ color: CGColor,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard let c = color.components, c.count >= 4 else {
            XCTFail("Cannot read color components", file: file, line: line); return
        }
        XCTAssertEqual(c[0], 0, accuracy: 0.01, "R should be 0 (black)", file: file, line: line)
        XCTAssertEqual(c[1], 0, accuracy: 0.01, "G should be 0 (black)", file: file, line: line)
        XCTAssertEqual(c[2], 0, accuracy: 0.01, "B should be 0 (black)", file: file, line: line)
        XCTAssertEqual(c[3], 1, accuracy: 0.01, "A should be 1",         file: file, line: line)
    }

    private func assertColorIsWhite(_ color: CGColor,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard let c = color.components, c.count >= 4 else {
            XCTFail("Cannot read color components", file: file, line: line); return
        }
        XCTAssertEqual(c[0], 1, accuracy: 0.01, "R should be 1 (white)", file: file, line: line)
        XCTAssertEqual(c[1], 1, accuracy: 0.01, "G should be 1 (white)", file: file, line: line)
        XCTAssertEqual(c[2], 1, accuracy: 0.01, "B should be 1 (white)", file: file, line: line)
        XCTAssertEqual(c[3], 1, accuracy: 0.01, "A should be 1",         file: file, line: line)
    }
}
