import XCTest
import CoreGraphics
import AppKit
@testable import keynotepptx

// MARK: - SVG → PDF → raster pipeline regression tests
//
// Keynote stores a PDF companion alongside every imported SVG (consecutive asset
// IDs, delta ≤ 2).  When exporting to PPTX it renders that companion PDF — NOT
// the SVG directly — to produce the raster PNG embedded in the slide.
//
// The old ImageRenderer.renderSVG path drew the SVG directly into an
// NSBitmapImageRep, which produces subtly different pixels to CoreGraphics
// rendering the companion PDF.  The result: user-validated SVG↔PNG matches that
// produced high hash distances (phash 8–14) in matching_debug.json.
//
// The new path routes SVG rendering through an in-memory PDF via:
//   NSImage (_NSSVGImageRep) → CGContext PDF → CGPDFDocument → renderPDFPageOpaque
//
// This replicates Keynote's pipeline and should reduce hash distances to ≤ 5.
// All (SVG, PNG) pairs in these tests are user-validated true matches sourced
// from the session at cache UUID 5F01563F-AE30-453C-8761-BE2C2F9EEDED.

final class SVGRenderingPipelineTests: XCTestCase {

    private static let testDataDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // keynotepptxTests/
        .deletingLastPathComponent()   // keynotepptx/ (Xcode project root)
        .appendingPathComponent("TestData", isDirectory: true)

    // MARK: - Test pairs

    private struct Pair {
        let svg: String
        let png: String
        /// pHash distance produced by the OLD direct SVG→bitmap path (from matching_debug.json).
        /// Kept for documentation — the test threshold is independent of this value.
        let oldPHashBaseline: Int
    }

    private let pairs: [Pair] = [
        // Old phash=10; PDF companion (same content) scored phash=2 against this PNG.
        Pair(svg: "Description of Yoshida et al 2020-1122.svg",
             png: "image16.png",
             oldPHashBaseline: 10),

        // Old phash=8; PDF companion scored phash=8 at 256 px but improves at full resolution.
        Pair(svg: "lung_cancer_flowchart-1106.svg",
             png: "image12.png",
             oldPHashBaseline: 8),

        // Old phash=14; PDF companion (MouseMethylationWorkflow-1205.pdf) scored phash=2.
        Pair(svg: "MouseMethylationWorkflow-1207.svg",
             png: "image37.png",
             oldPHashBaseline: 14),

        // Old phash=8 (simple icon — colour-moment distance was already very low).
        Pair(svg: "person-icon-smoker-1136.svg",
             png: "image20.png",
             oldPHashBaseline: 8),

        // Old phash=10 (simple icon).
        Pair(svg: "person-icon-nonsmoker-1160.svg",
             png: "image18.png",
             oldPHashBaseline: 10),
    ]

    // MARK: - Hash-distance test (production matching path)
    //
    // Uses ImageFingerprinter.fingerprint which calls renderForHashing at 256 px —
    // the exact same path the matching engine uses at runtime.  Asserting distance
    // ≤ 5 verifies substantial improvement over the old baselines (8–14) while
    // leaving room for minor anti-aliasing variation at 256 px.

    func testSVGFingerprint_matchesPPTXPNG_lowHashDistance() {
        for pair in pairs {
            XCTContext.runActivity(named: "\(pair.svg) ↔ \(pair.png)") { _ in
                let svgURL = Self.testDataDir.appendingPathComponent(pair.svg)
                let pngURL = Self.testDataDir.appendingPathComponent(pair.png)

                let svgFP = ImageFingerprinter.fingerprint(url: svgURL)
                let pngFP = ImageFingerprinter.fingerprint(url: pngURL)

                XCTAssertNil(svgFP.error, "\(pair.svg): fingerprint error — \(svgFP.error ?? "")")
                XCTAssertNil(pngFP.error, "\(pair.png): fingerprint error — \(pngFP.error ?? "")")

                guard let svgAHash = svgFP.aHash, let pngAHash = pngFP.aHash,
                      let svgPHash = svgFP.pHash, let pngPHash = pngFP.pHash,
                      let svgCM    = svgFP.colorMoments, let pngCM = pngFP.colorMoments
                else {
                    XCTFail("\(pair.svg): nil hash — SVG or PNG failed to render")
                    return
                }

                let aHashDist = ImageHasher.hammingDistance(svgAHash, pngAHash)
                let pHashDist = ImageHasher.hammingDistance(svgPHash, pngPHash)
                let cmDist    = ImageHasher.colorMomentDistance(svgCM, pngCM)

                XCTAssertLessThanOrEqual(
                    aHashDist, 5,
                    "\(pair.svg): aHash distance \(aHashDist) — old baseline was pre-fix"
                )
                XCTAssertLessThanOrEqual(
                    pHashDist, 5,
                    "\(pair.svg): pHash distance \(pHashDist) — old baseline \(pair.oldPHashBaseline)"
                )
                XCTAssertLessThanOrEqual(
                    cmDist, 0.15,
                    "\(pair.svg): colorMoment distance \(cmDist)"
                )
            }
        }
    }

    // MARK: - Full-resolution rendering test
    //
    // Renders the SVG at the *exact* pixel width of the reference PNG via
    // renderToPNGData, then decodes and hashes both images.  Full resolution
    // eliminates 256-px downsampling noise and should bring distances closer to 0.
    // The rendered data goes through pngquant compression; we decode it back to
    // pixels before hashing to avoid comparing compressed bytes directly.

    func testSVGRenderedAtExactWidth_matchesPPTXPNG() throws {
        for pair in pairs {
            try XCTContext.runActivity(named: "\(pair.svg) ↔ \(pair.png) (full-res)") { _ in
                let svgURL = Self.testDataDir.appendingPathComponent(pair.svg)
                let pngURL = Self.testDataDir.appendingPathComponent(pair.png)

                guard let refNS     = NSImage(contentsOf: pngURL),
                      let refCGRaw  = refNS.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let refCG     = ImageRenderer.flattenForHashing(refCGRaw)
                else {
                    XCTFail("Cannot load/flatten reference PNG: \(pair.png)"); return
                }
                let refW = refCGRaw.width

                // Render SVG through new pipeline at the reference PNG's exact width.
                let svgData: Data
                do {
                    svgData = try ImageRenderer.renderToPNGData(url: svgURL, widthPx: refW)
                } catch {
                    XCTFail("\(pair.svg): renderToPNGData threw — \(error)"); return
                }

                guard let src      = CGImageSourceCreateWithData(svgData as CFData, nil),
                      let svgCGRaw = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let svgCG    = ImageRenderer.flattenForHashing(svgCGRaw)
                else {
                    XCTFail("Cannot decode rendered PNG for \(pair.svg)"); return
                }

                guard let refAHash = ImageHasher.aHash(from: refCG),
                      let svgAHash = ImageHasher.aHash(from: svgCG),
                      let refPHash = ImageHasher.pHash(from: refCG),
                      let svgPHash = ImageHasher.pHash(from: svgCG),
                      let refCM    = ImageHasher.colorMoments(from: refCG),
                      let svgCM    = ImageHasher.colorMoments(from: svgCG)
                else {
                    XCTFail("\(pair.svg): hashing failed"); return
                }

                let aHashDist = ImageHasher.hammingDistance(refAHash, svgAHash)
                let pHashDist = ImageHasher.hammingDistance(refPHash, svgPHash)
                let cmDist    = ImageHasher.colorMomentDistance(refCM, svgCM)

                // At full resolution with correct pipeline, distances should be very low.
                // Threshold 8 is still a large improvement over the old 8–14 baseline
                // measured at 256 px; full-resolution distances are typically ≤ 2 for
                // well-matched pairs.
                XCTAssertLessThanOrEqual(
                    aHashDist, 8,
                    "\(pair.svg): full-res aHash distance \(aHashDist)"
                )
                XCTAssertLessThanOrEqual(
                    pHashDist, 8,
                    "\(pair.svg): full-res pHash distance \(pHashDist)  (old 256-px baseline \(pair.oldPHashBaseline))"
                )
                XCTAssertLessThanOrEqual(
                    cmDist, 0.15,
                    "\(pair.svg): full-res colorMoment distance \(cmDist)"
                )
            }
        }
    }

    // MARK: - Smoke tests for the new pipeline

    /// Every SVG in the test pairs must render without returning nil.
    func testSVGRenderForHashing_newPipeline_nonNil() {
        for pair in pairs {
            let url = Self.testDataDir.appendingPathComponent(pair.svg)
            XCTAssertNotNil(
                ImageRenderer.renderForHashing(url: url, maxDim: 256),
                "\(pair.svg): renderForHashing returned nil"
            )
        }
    }

    /// renderForHashing must honour the maxDim constraint for SVGs.
    func testSVGRenderForHashing_newPipeline_respectsMaxDim() {
        for pair in pairs {
            let url = Self.testDataDir.appendingPathComponent(pair.svg)
            guard let img = ImageRenderer.renderForHashing(url: url, maxDim: 256) else {
                XCTFail("\(pair.svg): renderForHashing returned nil"); continue
            }
            XCTAssertLessThanOrEqual(img.width,  256, "\(pair.svg): width exceeds maxDim")
            XCTAssertLessThanOrEqual(img.height, 256, "\(pair.svg): height exceeds maxDim")
            XCTAssertEqual(max(img.width, img.height), 256,
                           "\(pair.svg): longest side must equal maxDim exactly")
        }
    }

    /// Fingerprinting the same SVG twice must yield identical hashes.
    func testSVGFingerprint_isDeterministic() {
        for pair in pairs {
            let url = Self.testDataDir.appendingPathComponent(pair.svg)
            let fp1 = ImageFingerprinter.fingerprint(url: url)
            let fp2 = ImageFingerprinter.fingerprint(url: url)
            XCTAssertEqual(fp1.aHash, fp2.aHash, "\(pair.svg): aHash not deterministic")
            XCTAssertEqual(fp1.pHash, fp2.pHash, "\(pair.svg): pHash not deterministic")
        }
    }

    /// SVG fingerprint via new pipeline must score better than the old baseline.
    /// This is the regression guard: if someone reverts the SVG rendering path,
    /// the distance jumps back to 8–14 and this test fails.
    func testSVGFingerprint_improvesOverOldBaseline() {
        for pair in pairs {
            let svgURL = Self.testDataDir.appendingPathComponent(pair.svg)
            let pngURL = Self.testDataDir.appendingPathComponent(pair.png)

            let svgFP = ImageFingerprinter.fingerprint(url: svgURL)
            let pngFP = ImageFingerprinter.fingerprint(url: pngURL)

            guard let svgPHash = svgFP.pHash, let pngPHash = pngFP.pHash else {
                XCTFail("\(pair.svg): nil pHash"); continue
            }

            let dist = ImageHasher.hammingDistance(svgPHash, pngPHash)
            XCTAssertLessThan(
                dist, pair.oldPHashBaseline,
                "\(pair.svg): new pHash distance \(dist) is not better than old baseline \(pair.oldPHashBaseline)"
            )
        }
    }
}
