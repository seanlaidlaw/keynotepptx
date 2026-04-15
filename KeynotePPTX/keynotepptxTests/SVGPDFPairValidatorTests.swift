import XCTest
import PDFKit
@testable import keynotepptx

// MARK: - SVGPDFPairValidator regression tests
//
// Two groups of test cases, both sourced from the real Keynote cache at
//   ~/Library/Caches/keynotepptx/2B7D2A94-C22F-484D-96F9-E85303FB4CFC/keynote/Data/
//
// Group A — CONFIRMED pairs (same source image, consecutive asset IDs ≤ 2 apart).
//   Every pair must report isCompanionPair == true.
//
// Group B — CONFIRMED non-pairs (different images, same directory).
//   Every pair must report isCompanionPair == false.
//
// The validator uses three signals (see SVGPDFPairValidator.swift for details):
//   1. Physical dimension match (SVG pts ≈ PDF page pts, within 2 pt)
//   2. Text word-set overlap (Jaccard coefficient over extracted word sets)
//   3. Normalised x-position match (each word x ÷ page_width, within 2 %)

final class SVGPDFPairValidatorTests: XCTestCase {

    private static let cacheDir = URL(fileURLWithPath:
        "/Users/sl31/Library/Caches/keynotepptx/2B7D2A94-C22F-484D-96F9-E85303FB4CFC/keynote/Data")

    private func svg(_ name: String) -> URL { Self.cacheDir.appendingPathComponent(name) }
    private func pdf(_ name: String) -> URL { Self.cacheDir.appendingPathComponent(name) }

    // MARK: - Group A: Confirmed companion pairs → must return isCompanionPair == true

    /// Pair with text elements using translate() transform, px units, dim 1:1
    func testCompanion_mouseMethylation() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("MouseMethylationWorkflow-1207.svg"),
            pdf: pdf("MouseMethylationWorkflow-1205.pdf"))
        printResult("MouseMethylation", r)
        XCTAssertTrue(r.dimensionMatch,   "dimension mismatch: delta=\(r.dimensionDelta)")
        XCTAssertTrue(r.isCompanionPair,  "confidence \(r.confidence) below threshold")
    }

    /// Pair with text using x= attribute, pt units (SVG_w × 4/3 = PDF_w)
    func testCompanion_clusteredPathways() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("Clustered_pathways_network_plot_MSigDB_Hallmark-7990.svg"),
            pdf: pdf("Clustered_pathways_network_plot_MSigDB_Hallmark-7988.pdf"))
        printResult("ClusteredPathways", r)
        XCTAssertTrue(r.dimensionMatch,   "dimension mismatch: delta=\(r.dimensionDelta)")
        XCTAssertTrue(r.isCompanionPair,  "confidence \(r.confidence) below threshold")
    }

    /// Pair with text using matrix() transform, px units, dim 1:1
    func testCompanion_exSmokerSchema() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("Ex-smoker HM Composition Schema-1281.svg"),
            pdf: pdf("Ex-smoker HM Composition Schema-1279.pdf"))
        printResult("ExSmokerSchema", r)
        XCTAssertTrue(r.dimensionMatch,   "dimension mismatch: delta=\(r.dimensionDelta)")
        XCTAssertTrue(r.isCompanionPair,  "confidence \(r.confidence) below threshold")
    }

    /// Pair with text using matrix() transform (only asterisk labels)
    func testCompanion_luscDriverDMRs() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("LUSC Driver DMRs-3691.svg"),
            pdf: pdf("LUSC Driver DMRs-3690.pdf"))
        printResult("LUSCDriverDMRs", r)
        XCTAssertTrue(r.dimensionMatch,   "dimension mismatch: delta=\(r.dimensionDelta)")
        XCTAssertTrue(r.isCompanionPair,  "confidence \(r.confidence) below threshold")
    }

    /// Pair with no extractable text (all paths), px units, dim 1:1
    func testCompanion_bapToMutagen() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("BaP_to_mutagen-1266.svg"),
            pdf: pdf("BaP_to_mutagen-1264.pdf"))
        printResult("BaPToMutagen (no text)", r)
        XCTAssertTrue(r.dimensionMatch,   "dimension mismatch: delta=\(r.dimensionDelta)")
        XCTAssertTrue(r.isCompanionPair,  "confidence \(r.confidence) below threshold")
    }

    /// Pair with no extractable text, px units, small dimensions
    func testCompanion_carcinagens() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("Carcinagens_in_tobacco-1340.svg"),
            pdf: pdf("Carcinagens_in_tobacco-1338.pdf"))
        printResult("Carcinagens (no text)", r)
        XCTAssertTrue(r.dimensionMatch,   "dimension mismatch: delta=\(r.dimensionDelta)")
        XCTAssertTrue(r.isCompanionPair,  "confidence \(r.confidence) below threshold")
    }

    /// Pair with no extractable text, viewBox with near-zero y origin
    func testCompanion_yoshida() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("Description of Yoshida et al 2020-1122.svg"),
            pdf: pdf("Description of Yoshida et al 2020-1120.pdf"))
        printResult("Yoshida (no text, pt units)", r)
        // Dimension match is the primary signal here (pt units → 4/3 scale)
        XCTAssertTrue(r.dimensionMatch,   "dimension mismatch: delta=\(r.dimensionDelta)")
        XCTAssertTrue(r.isCompanionPair,  "confidence \(r.confidence) below threshold")
    }

    func testCompanion_lungProximalAirway() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("Lung Proximal Airway Basal Highlight-957.svg"),
            pdf: pdf("Lung Proximal Airway Basal Highlight-955.pdf"))
        printResult("LungProximalAirway (no text)", r)
        XCTAssertTrue(r.dimensionMatch,   "dimension mismatch: delta=\(r.dimensionDelta)")
        XCTAssertTrue(r.isCompanionPair,  "confidence \(r.confidence) below threshold")
    }

    // MARK: - Group B: Confirmed non-pairs → must return isCompanionPair == false

    /// Different images: small icon SVG vs large workflow PDF
    func testNonPair_svgIconVsWorkflowPDF() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("Carcinagens_in_tobacco-1340.svg"),
            pdf: pdf("MouseMethylationWorkflow-1205.pdf"))
        printResult("NonPair: icon vs workflow", r)
        XCTAssertFalse(r.isCompanionPair, "false positive — confidence \(r.confidence)")
    }

    /// Different images: clustered network SVG (558pt) vs small workflow PDF (529pt)
    func testNonPair_clusteredVsMouseMethylation() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("Clustered_pathways_network_plot_MSigDB_Hallmark-7990.svg"),
            pdf: pdf("MouseMethylationWorkflow-1205.pdf"))
        printResult("NonPair: clustered vs mouseMethylation", r)
        XCTAssertFalse(r.isCompanionPair, "false positive — confidence \(r.confidence)")
    }

    /// Different images: large schema SVG vs small carcinagens PDF
    func testNonPair_schemaVsCarcinagens() {
        let r = SVGPDFPairValidator.validate(
            svg: svg("Ex-smoker HM Composition Schema-1281.svg"),
            pdf: pdf("Carcinagens_in_tobacco-1338.pdf"))
        printResult("NonPair: schema vs carcinagens", r)
        XCTAssertFalse(r.isCompanionPair, "false positive — confidence \(r.confidence)")
    }

    // MARK: - Diagnostic: print full score table for every detected pair

    /// Not a pass/fail test — scans the whole cache directory, finds all SVG/PDF candidates
    /// by ID-proximity (delta ≤ 3), runs the validator on each, and prints the results.
    /// Useful for tuning confidence thresholds.
    func testDiagnostic_scanAllCachePairs() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.cacheDir.path) else {
            throw XCTSkip("Cache directory not present on this machine")
        }

        let files = try fm.contentsOfDirectory(at: Self.cacheDir,
                                                includingPropertiesForKeys: nil)
        let svgFiles = files.filter { $0.pathExtension.lowercased() == "svg" }
        let pdfFiles = files.filter { $0.pathExtension.lowercased() == "pdf" }

        // Index PDFs by (stem, id)
        struct FileID { let stem: String; let id: Int }
        func parseID(_ url: URL) -> FileID? {
            let name = url.deletingPathExtension().lastPathComponent
            guard let m = name.range(of: #"^(.*)-(\d+)$"#, options: .regularExpression) else { return nil }
            let parts  = name.components(separatedBy: "-")
            guard let idStr = parts.last, let id = Int(idStr) else { return nil }
            let stem = parts.dropLast().joined(separator: "-")
            return FileID(stem: stem, id: id)
        }

        var pdfIndex: [String: [(id: Int, url: URL)]] = [:]
        for pdfURL in pdfFiles {
            if let fid = parseID(pdfURL) {
                pdfIndex[fid.stem, default: []].append((fid.id, pdfURL))
            }
        }

        print("\n── SVGPDFPairValidator diagnostic scan ─────────────────────────────────")
        print(String(format: "%-52s  %5s  %5s  %5s  %5s  %5s",
                     "pair", "delta", "textOv", "xOk", "conf", "pair?"))
        print(String(repeating: "-", count: 90))

        var trueCount = 0, falseCount = 0
        for svgURL in svgFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let svgFID = parseID(svgURL) else { continue }
            guard let candidates = pdfIndex[svgFID.stem] else { continue }
            // Match PDF with same stem and ID within 3
            for (pdfID, pdfURL) in candidates where abs(pdfID - svgFID.id) <= 3 && pdfID < svgFID.id {
                let r = SVGPDFPairValidator.validate(svg: svgURL, pdf: pdfURL)
                let label = "\(svgFID.stem)-\(svgFID.id)↔\(pdfID)"
                print(String(format: "%-52s  %5.1f  %5.2f  %d/%d  %5.2f  %@",
                             String(label.prefix(52)),
                             r.dimensionDelta,
                             r.textOverlap,
                             r.xMatchCount, r.xMatchTotal,
                             r.confidence,
                             r.isCompanionPair ? "✓" : "✗"))
                r.isCompanionPair ? (trueCount += 1) : (falseCount += 1)
            }
        }
        print("── \(trueCount) companion pairs, \(falseCount) non-pairs ──────────────────────────────")
    }

    // MARK: - Helper

    private func printResult(_ label: String, _ r: SVGPDFSimilarityResult) {
        print("""
        [\(label)]
          dim: delta=\(String(format: "%.2f", r.dimensionDelta)) match=\(r.dimensionMatch)
          text: svg=\(r.svgWordCount) pdf=\(r.pdfWordCount) common=\(r.commonWordCount) overlap=\(String(format: "%.2f", r.textOverlap))
          x: \(r.xMatchCount)/\(r.xMatchTotal)
          confidence=\(String(format: "%.3f", r.confidence))  isCompanion=\(r.isCompanionPair)
        """)
    }
}
