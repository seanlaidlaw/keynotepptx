import XCTest
import CoreGraphics
import AppKit
@testable import keynotepptx

// MARK: - PDF → PNG conversion fidelity tests
//
// Each test case renders a Keynote-origin PDF to PNG at the exact DPI needed to
// reproduce the pixel dimensions of the corresponding PPTX-exported reference PNG.
// We then compare all three perceptual hash metrics and assert distance == 0.
//
// If a test fails, the XCTContext activity label and the failure message both report
// the pair name and the exact distance, making root-cause diagnosis straightforward.
//
// Test data lives at <project-root>/TestData/ (referenced via #filePath at compile time).

final class PDFConversionTests: XCTestCase {

    // MARK: - Test data root (compile-time path, works locally and in Xcode)

    private static let testDataDir: URL = {
        // #filePath expands to the absolute path of THIS source file at compile time.
        // Navigate: .../keynotepptxTests/ → keynotepptx/ → TestData/
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // keynotepptxTests/
            .deletingLastPathComponent()  // keynotepptx/ (Xcode project root)
            .appendingPathComponent("TestData", isDirectory: true)
    }()

    // MARK: - (PDF, reference PNG) pairs confirmed in matching_debug.json
    //
    // DPI is derived at runtime from the reference PNG's pixel width so that the
    // rendered output has exactly the same dimensions as the Keynote-exported PNG.
    // Keynote rasterises at a per-asset DPI that equals (slide export resolution) ×
    // (fraction of slide width the asset occupies), so it varies across images.

    private struct Pair {
        let pdf: String
        let png: String
        // Expected current distances (from matching_debug.json analysis).
        // These are the CURRENT render distances — the test asserts 0, so all
        // non-zero values represent regressions to drive down.
        let knownAHash: Int
        let knownPHash: Int
    }

    private let pairs: [Pair] = [
        // Δ0–1: near-identical renders — should pass immediately once DPI matches.
        Pair(pdf: "Description of Yoshida et al 2020-1120.pdf",
             png: "image16.png",  knownAHash: 1, knownPHash: 2),

        // Δ2: sub-pixel anti-aliasing — borderline; exact DPI may close the gap.
        Pair(pdf: "TopDMRs-3125.pdf",
             png: "image48.png",  knownAHash: 2, knownPHash: 6),
        Pair(pdf: "fig-hmlike_lusc_drivers-1-3814.pdf",
             png: "image82.png",  knownAHash: 2, knownPHash: 2),
        Pair(pdf: "smoking-lungcancer-mortality-nrc2703 copy-940.pdf",
             png: "image11.png",  knownAHash: 2, knownPHash: 0),

        // Δ3: thin-stroke rendering — requires exact DPI to eliminate scale rounding.
        Pair(pdf: "fig-hmlike_nrf2-examples-1-3819.pdf",
             png: "image81.png",  knownAHash: 3, knownPHash: 2),
        Pair(pdf: "lung_cancer_flowchart-1105.pdf",
             png: "image12.png",  knownAHash: 3, knownPHash: 8),

        // Δ5–7: line-weight & transparency rendering differences needing renderer fixes.
        Pair(pdf: "nrc2703-slope-full-936.pdf",
             png: "image10.png",  knownAHash: 5, knownPHash: 2),
        Pair(pdf: "PathwayEnrichmentTable-3656.pdf",
             png: "image61.png",  knownAHash: 6, knownPHash: 0),
        Pair(pdf: "top_dmr_gene_track_ex_smoker_between_smoker_and_nonsmoker-3581.pdf",
             png: "image64.png",  knownAHash: 7, knownPHash: 4),
    ]

    // MARK: - Main test

    func testPDFConversionMatchesKeynoteExport() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFConversionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        print("PDFConversionTests output: \(tempDir.path)")

        for pair in pairs {
            XCTContext.runActivity(named: "\(pair.pdf) ↔ \(pair.png)") { _ in
                do {
                    try assertHashesEqual(pair: pair, tempDir: tempDir)
                } catch {
                    XCTFail("\(pair.pdf): unexpected error — \(error)")
                }
            }
        }
    }

    // MARK: - Per-pair assertion

    private func assertHashesEqual(pair: Pair, tempDir: URL) throws {
        let pdfURL = Self.testDataDir.appendingPathComponent(pair.pdf)
        let pngURL = Self.testDataDir.appendingPathComponent(pair.png)

        // 1. Load reference PNG and obtain its CGImage for hashing.
        guard let refNS    = NSImage(contentsOf: pngURL),
              let refCGRaw = refNS.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Cannot load reference PNG: \(pair.png)")
            return
        }
        let refW = refCGRaw.width
        let refH = refCGRaw.height

        // Flatten the reference PNG onto the appropriate background before hashing.
        // PPTX-exported PNGs can have a transparent background; flattening here
        // mirrors what the production hashing path does via ImageRenderer.renderRaster.
        guard let refCG = ImageRenderer.flattenForHashing(refCGRaw) else {
            XCTFail("Cannot flatten reference PNG for hashing: \(pair.png)")
            return
        }

        // 2. Compute the DPI that reproduces the reference PNG's exact pixel width.
        guard let computedDPI = dpiMatchingReference(pdfURL: pdfURL, referencePixelWidth: refW) else {
            XCTFail("Cannot open PDF: \(pair.pdf)")
            return
        }

        // 3. Render the PDF to a temporary PNG at the computed DPI.
        let pdfStem  = pdfURL.deletingPathExtension().lastPathComponent
        let rendered = try convertPDF(at: pdfURL, to: tempDir, fileType: .png, dpi: computedDPI)
        guard let outURL = rendered.first,
              let outNS  = NSImage(contentsOf: outURL),
              let outCG  = outNS.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("Cannot load rendered PNG for: \(pair.pdf)")
            return
        }

        // Save reference and converted PNGs for manual inspection.
        let pptxCopyURL = tempDir.appendingPathComponent("\(pdfStem)_pptx.png")
        let convCopyURL = tempDir.appendingPathComponent("\(pdfStem)_conv.png")
        try? FileManager.default.copyItem(at: pngURL, to: pptxCopyURL)
        try? FileManager.default.copyItem(at: outURL, to: convCopyURL)
        let outW = outCG.width
        let outH = outCG.height

        // 4. Assert dimensions match the reference (allowing ±1 px on height for
        //    floating-point rounding across different PDF aspect ratios).
        XCTAssertEqual(outW, refW,
                       "\(pair.pdf): rendered width \(outW) ≠ reference \(refW)")
        XCTAssertLessThanOrEqual(
            abs(outH - refH), 1,
            "\(pair.pdf): rendered height \(outH) differs from reference \(refH) by more than 1 px"
        )

        // 5. Hash both images using the same hasher the matching engine uses.
        guard let refAHash = ImageHasher.aHash(from: refCG),
              let outAHash = ImageHasher.aHash(from: outCG),
              let refPHash = ImageHasher.pHash(from: refCG),
              let outPHash = ImageHasher.pHash(from: outCG),
              let refCM    = ImageHasher.colorMoments(from: refCG),
              let outCM    = ImageHasher.colorMoments(from: outCG) else {
            XCTFail("\(pair.pdf): hashing failed")
            return
        }

        let aHashDist = ImageHasher.hammingDistance(refAHash, outAHash)
        let pHashDist = ImageHasher.hammingDistance(refPHash, outPHash)
        let cmDist    = ImageHasher.colorMomentDistance(refCM, outCM)

        // 6. Assert all three metrics are zero.
        //    The knownAHash / knownPHash annotations above record the current baseline
        //    measured from the Python renderer for reference — they are NOT the pass
        //    threshold.  The pass threshold is always 0.
        XCTAssertEqual(
            aHashDist, 0, accuracy: 1,
            "\(pair.pdf) ↔ \(pair.png): aHash distance = \(aHashDist)  (baseline \(pair.knownAHash))"
        )
        XCTAssertEqual(
            pHashDist, 0, accuracy: 1,
            "\(pair.pdf) ↔ \(pair.png): pHash distance = \(pHashDist)  (baseline \(pair.knownPHash))"
        )
        XCTAssertEqual(
            cmDist, 0.0, accuracy: 0.1,
            "\(pair.pdf) ↔ \(pair.png): colorMoment distance = \(cmDist)"
        )
    }
}
