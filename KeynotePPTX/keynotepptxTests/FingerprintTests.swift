import XCTest
import CoreGraphics
import AppKit
@testable import keynotepptx

final class FingerprintTests: XCTestCase {

    private static let testDataDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // keynotepptxTests/
        .deletingLastPathComponent()  // keynotepptx/ (Xcode project root)
        .appendingPathComponent("TestData", isDirectory: true)

    // MARK: - Valid file

    func testFingerprint_svg_allFieldsPopulated() {
        let url = Self.testDataDir.appendingPathComponent("child-icon-female-1140.svg")
        let fp = ImageFingerprinter.fingerprint(url: url)

        XCTAssertNil(fp.error, "no error expected for valid SVG")
        XCTAssertNotNil(fp.aHash)
        XCTAssertNotNil(fp.pHash)
        XCTAssertNotNil(fp.colorMoments)
        XCTAssertEqual(fp.colorMoments?.count, 9)
        XCTAssertNotNil(fp.width)
        XCTAssertNotNil(fp.height)
        XCTAssertNotNil(fp.thumbnailData)
        XCTAssertGreaterThan(fp.fileSizeBytes, 0)
        XCTAssertEqual(fp.filename, "child-icon-female-1140.svg")
    }

    func testFingerprint_png_allFieldsPopulated() {
        let url = Self.testDataDir.appendingPathComponent("image16.png")
        let fp  = ImageFingerprinter.fingerprint(url: url)

        XCTAssertNil(fp.error)
        XCTAssertNotNil(fp.aHash)
        XCTAssertNotNil(fp.pHash)
        XCTAssertNotNil(fp.thumbnailData)
    }

    func testFingerprint_pdf_allFieldsPopulated() {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1264.pdf")
        let fp  = ImageFingerprinter.fingerprint(url: url)

        XCTAssertNil(fp.error)
        XCTAssertNotNil(fp.aHash)
        XCTAssertNotNil(fp.pHash)
        XCTAssertNotNil(fp.colorMoments)
    }

    // MARK: - CropBox propagates through fingerprinting

    func testFingerprint_pfeiferCrop_dimensionsFromCropBox() {
        // The fingerprint renders at maxDim=256 via renderForHashing, which uses
        // cgPDFVisibleRect. Width==256 proves the CropBox (wider than its height)
        // was the bounding dimension — not the taller MediaBox.
        let url = Self.testDataDir.appendingPathComponent("Pfeifer_PDF_crop.pdf")

        guard let doc  = CGPDFDocument(url as CFURL),
              let page = doc.page(at: 1) else {
            XCTFail("Cannot open Pfeifer_PDF_crop.pdf"); return
        }
        let cropBox  = ImageRenderer.cgPDFVisibleRect(page)
        let mediaBox = page.getBoxRect(.mediaBox)

        let fp = ImageFingerprinter.fingerprint(url: url)
        XCTAssertNil(fp.error)

        // Compute expected width and height from the CropBox at maxDim=256.
        let scale    = CGFloat(256) / max(cropBox.width, cropBox.height)
        let expectedW = max(1, Int(cropBox.width  * scale))
        let expectedH = max(1, Int(cropBox.height * scale))

        XCTAssertEqual(fp.width,  expectedW, "width must derive from CropBox")
        XCTAssertEqual(fp.height, expectedH, "height must derive from CropBox")

        // The MediaBox at maxDim=256 produces a very different aspect ratio.
        let mScale = CGFloat(256) / max(mediaBox.width, mediaBox.height)
        let mediaW = max(1, Int(mediaBox.width * mScale))
        XCTAssertNotEqual(fp.width, mediaW, "must NOT match MediaBox-derived width")
    }

    // MARK: - Invalid file

    func testFingerprint_invalidURL_returnsError() {
        let url = URL(fileURLWithPath: "/no/such/file.svg")
        let fp  = ImageFingerprinter.fingerprint(url: url)

        XCTAssertNotNil(fp.error, "error must be set for unreadable file")
        XCTAssertNil(fp.aHash)
        XCTAssertNil(fp.pHash)
        XCTAssertNil(fp.colorMoments)
        XCTAssertNil(fp.thumbnailData)
    }

    // MARK: - Thumbnail is valid PNG

    func testFingerprint_thumbnailIsPNG() {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1266.svg")
        let fp  = ImageFingerprinter.fingerprint(url: url)
        guard let data = fp.thumbnailData else {
            XCTFail("thumbnailData is nil"); return
        }
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(data.prefix(8), pngMagic, "thumbnail must be PNG-encoded")
    }

    func testFingerprint_thumbnailMaxDimension() {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1266.svg")
        let fp  = ImageFingerprinter.fingerprint(url: url)
        guard let data = fp.thumbnailData else {
            XCTFail("thumbnailData is nil"); return
        }
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            XCTFail("cannot decode thumbnail PNG"); return
        }
        XCTAssertLessThanOrEqual(img.width,  260)
        XCTAssertLessThanOrEqual(img.height, 260)
        XCTAssertEqual(max(img.width, img.height), 260)
    }

    // MARK: - Determinism

    func testFingerprint_deterministic() {
        let url = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1266.svg")
        let fp1 = ImageFingerprinter.fingerprint(url: url)
        let fp2 = ImageFingerprinter.fingerprint(url: url)

        XCTAssertEqual(fp1.aHash, fp2.aHash, "aHash must be deterministic")
        XCTAssertEqual(fp1.pHash, fp2.pHash, "pHash must be deterministic")

        if let cm1 = fp1.colorMoments, let cm2 = fp2.colorMoments {
            for (a, b) in zip(cm1, cm2) {
                XCTAssertEqual(a, b, accuracy: 1e-3)
            }
        } else {
            XCTFail("colorMoments nil on one or both runs")
        }
    }

    // MARK: - SVG and PDF with same content hash similarly

    func testFingerprint_svgAndPdfPair_closeHashes() {
        // BaP_to_mutagen-1264.pdf and BaP_to_mutagen-1266.svg are the same image.
        // Their aHash distance should be small (within the match threshold of 25).
        let pdfURL = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1264.pdf")
        let svgURL = Self.testDataDir.appendingPathComponent("BaP_to_mutagen-1266.svg")

        let pdfFP = ImageFingerprinter.fingerprint(url: pdfURL)
        let svgFP = ImageFingerprinter.fingerprint(url: svgURL)

        guard let pdfAHash = pdfFP.aHash, let svgAHash = svgFP.aHash else {
            XCTFail("aHash nil for PDF or SVG"); return
        }
        let dist = ImageHasher.hammingDistance(pdfAHash, svgAHash)
        XCTAssertLessThanOrEqual(dist, 1,
            "PDF/SVG pair aHash distance \(dist) exceeds threshold; they should represent the same image")
    }
}
