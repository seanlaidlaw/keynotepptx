import XCTest
import CoreGraphics
import AppKit
@testable import keynotepptx

final class PDFConverterTests: XCTestCase {

    private static let testDataDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // keynotepptxTests/
        .deletingLastPathComponent()  // keynotepptx/ (Xcode project root)
        .appendingPathComponent("TestData", isDirectory: true)

    // MARK: - dpiMatchingReference

    func testDpiMatchingReference_invalidURL_returnsNil() {
        let result = dpiMatchingReference(
            pdfURL: URL(fileURLWithPath: "/no/such/file.pdf"),
            referencePixelWidth: 512
        )
        XCTAssertNil(result)
    }

    func testDpiMatchingReference_formula() {
        // dpi = referencePixelWidth / pageWidth * 72.
        // Verify by independently computing from the page rect.
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1264.pdf")
        guard let doc  = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open BaP_to_mutagen-1264.pdf"); return
        }
        let pageRect = ImageRenderer.cgPDFVisibleRect(page)
        let refWidth = 800
        let expected = Double(refWidth) / Double(pageRect.width) * 72.0

        guard let result = dpiMatchingReference(pdfURL: url, referencePixelWidth: refWidth) else {
            XCTFail("dpiMatchingReference returned nil"); return
        }
        XCTAssertEqual(Double(result), expected, accuracy: 0.001)
    }

    func testDpiMatchingReference_usesCropBox_notMediaBox() {
        // Pfeifer_PDF_crop.pdf has a CropBox narrower than the MediaBox.
        // dpiMatchingReference must use the CropBox width, so for the same refWidth
        // it returns a higher DPI than if MediaBox were used.
        let url = Self.testDataDir.appendingPathComponent("Pfeifer_PDF_crop.pdf")
        guard let doc  = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open Pfeifer_PDF_crop.pdf"); return
        }

        let mediaBox = page.getBoxRect(.mediaBox)
        let cropBox  = ImageRenderer.cgPDFVisibleRect(page)
        XCTAssertLessThan(cropBox.width, mediaBox.width, "test precondition")

        let refWidth = 1000
        guard let dpi = dpiMatchingReference(pdfURL: url, referencePixelWidth: refWidth) else {
            XCTFail("dpiMatchingReference returned nil"); return
        }

        let expectedFromCrop  = Double(refWidth) / Double(cropBox.width)  * 72.0
        let expectedFromMedia = Double(refWidth) / Double(mediaBox.width) * 72.0

        XCTAssertEqual(Double(dpi), expectedFromCrop,  accuracy: 0.001, "must use CropBox width")
        XCTAssertNotEqual(Double(dpi), expectedFromMedia, "must NOT match MediaBox-derived DPI")
    }

    // MARK: - convertPDF

    func testConvertPDF_invalidURL_throws() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertThrowsError(
            try convertPDF(at: URL(fileURLWithPath: "/no/such/file.pdf"), to: tempDir)
        ) { error in
            XCTAssertTrue(error is PDFConverterError)
        }
    }

    func testConvertPDF_singlePage_createsOneFile() throws {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1264.pdf")
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let results = try convertPDF(at: url, to: tempDir, fileType: .png, dpi: 72)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].path))
    }

    func testConvertPDF_dimensionsRespectDPI() throws {
        // At a known DPI, output width = floor(pageWidth * dpi/72).
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1264.pdf")
        guard let doc  = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open BaP_to_mutagen-1264.pdf"); return
        }
        let pageRect = ImageRenderer.cgPDFVisibleRect(page)
        let dpi: CGFloat = 144
        let scale = dpi / 72.0
        let expectedW = max(1, Int(pageRect.width  * scale))
        let expectedH = max(1, Int(pageRect.height * scale))

        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let results = try convertPDF(at: url, to: tempDir, fileType: .png, dpi: dpi)

        guard let outImg = NSImage(contentsOf: results[0]),
              let outCG  = outImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Cannot load rendered PNG"); return
        }
        XCTAssertEqual(outCG.width, expectedW)
        XCTAssertEqual(outCG.height, expectedH)
    }

    // MARK: - The primary CropBox integration test

    /// Pfeifer_PDF_crop.pdf has a CropBox that is a sub-region of the MediaBox.
    /// When rendered at the DPI that matches image16.png's pixel width, the output
    /// must match image16.png's dimensions — confirming that the CropBox (not the
    /// MediaBox) drives the geometry throughout the pipeline.
    func testConvertPDF_pfeiferCropBox_matchesReferenceImageDimensions() throws {
        let pdfURL = Self.testDataDir.appendingPathComponent("Pfeifer_PDF_crop.pdf")
        let pngURL = Self.testDataDir.appendingPathComponent("image16.png")

        // 1. Measure the reference PNG (from Keynote export via PPTX).
        guard let refNS    = NSImage(contentsOf: pngURL),
              let refCGRaw = refNS.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Cannot load image16.png"); return
        }
        let refW = refCGRaw.width
        let refH = refCGRaw.height

        // 2. Derive the DPI that produces exactly refW pixels from the PDF's CropBox.
        guard let computedDPI = dpiMatchingReference(pdfURL: pdfURL, referencePixelWidth: refW) else {
            XCTFail("dpiMatchingReference failed"); return
        }

        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 3. Render the PDF at that DPI.
        let results = try convertPDF(at: pdfURL, to: tempDir, fileType: .png, dpi: computedDPI)
        guard let outNS  = NSImage(contentsOf: results[0]),
              let outCG  = outNS.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Cannot load rendered PNG"); return
        }
        let outW = outCG.width
        let outH = outCG.height

        // 4. Width must be exactly refW (DPI was derived for this).
        XCTAssertEqual(outW, refW,
                       "rendered width must match reference PNG width")

        // 5. Height within ±1 px (floating-point rounding of aspect ratio).
        XCTAssertLessThanOrEqual(
            abs(outH - refH), 1,
            "rendered height \(outH) must be within 1 px of reference \(refH)"
        )

        // 6. Confirm the MediaBox was NOT used (it's ~595 pt wide; at the same DPI
        //    it would produce a far larger output width).
        guard let doc  = CGPDFDocument(pdfURL as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open PDF"); return
        }
        let mediaBox  = page.getBoxRect(.mediaBox)
        let mediaScale = computedDPI / 72.0
        let mediaWidth = max(1, Int(mediaBox.width * mediaScale))
        XCTAssertNotEqual(outW, mediaWidth,
                          "output must derive from CropBox, not MediaBox")
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFConverterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
