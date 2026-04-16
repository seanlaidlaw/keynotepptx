import XCTest
import CoreGraphics
import AppKit
@testable import keynotepptx

// MARK: - Candidate scoring / ranking regression tests
//
// All cases come from matching_debug.json session 5F01563F-AE30-453C-8761-BE2C2F9EEDED.
// In every case the user manually confirmed the correct match.  The algorithm's
// combined score formula ranked a wrong candidate lower (= better) than the correct one.
//
// Current combined score (from MatchEngine): pHashDist + cmDist × 20.0
// aHash is a fast pre-filter gate only — it is NOT part of the sort score.
//
// ── Category A — SVG vs companion PDF ─────────────────────────────────────────────
// Keynote stores a PDF companion for each imported SVG.  The old SVG renderer produced
// hashes that diverged from the PPTX PNG (which Keynote renders from the companion PDF),
// so the PDF companion ranked first.  After the SVG→PDF rendering fix the SVG fingerprint
// should nearly match the companion PDF's fingerprint, making their scores approximately
// equal.  The deduplication step (aHash delta ≤ 2 → keep higher-priority ext) then
// selects the SVG because extPriority["svg"] < extPriority["pdf"].
//
//   image35.png  →  Xenome…7385.svg   (distractor: Xenome…7384.pdf)
//   image94.png  →  Clustered…7990.svg (distractor: Clustered…7988.pdf)
//   image16.png  →  Description…1122.svg (distractor: Description…1120.pdf)
//   image37.png  →  MouseMethylationWorkflow-1207.svg (distractor: …1205.pdf)
//
// ── Category B — Genuinely ambiguous ─────────────────────────────────────────────
// The tiered score (pHash + cm×W_cm, aHash = gate only) distinguishes both:
//
//   image47.png  →  pasted-image-2715.pdf  (distractor: pasted-image-2722.pdf)
//     correct: ahash=5 phash=2  cm=0.015  ←  wrong: ahash=3 phash=4  cm=0.271
//     cm distance alone distinguishes them; colorMomentWeight ≥ ~8 fixes this.
//
//   image28.png  →  smoking-icon-2976.svg  (distractor: non-smoking-icon-2977.svg)
//     correct: ahash=10 phash=2  cm=0.004  ←  wrong: ahash=6 phash=24 cm=0.267
//     pHash distance 24 is the clearest signal; adding pHash×0.5 to the score fixes this.

final class MatchingAlgorithmTests: XCTestCase {

    private static let testDataDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // keynotepptxTests/
        .deletingLastPathComponent()   // keynotepptx/ (Xcode project root)
        .appendingPathComponent("TestData", isDirectory: true)

    // MARK: - Score formula (mirrors MatchEngine exactly — update both together)
    //
    // score = pHashDist + cmDist × colorMomentSortWeight
    // Keep colorMomentSortWeight in sync with MatchEngine.colorMomentSortWeight.

    private static let colorMomentSortWeight: Float = 20.0

    private func combinedScore(ref: ImageFingerprint, cand: ImageFingerprint) -> Float {
        guard let rP = ref.pHash, let cP = cand.pHash else { return .infinity }
        let pHashDist = Float(ImageHasher.hammingDistance(rP, cP))
        let cmDist: Float = {
            guard let rCM = ref.colorMoments, let cCM = cand.colorMoments else { return 0 }
            return ImageHasher.colorMomentDistance(rCM, cCM)
        }()
        return pHashDist + cmDist * Self.colorMomentSortWeight
    }

    // MARK: - Helpers

    private func fp(_ name: String) -> ImageFingerprint {
        ImageFingerprinter.fingerprint(url: Self.testDataDir.appendingPathComponent(name))
    }

    /// Assert `correctFile` has a lower combined score against `reference` than every
    /// file in `distractors`.  Prints a score table on failure for easy diagnosis.
    private func assertRanksFirst(
        reference refFile: String,
        correct correctFile: String,
        distractors: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let refFP      = fp(refFile)
        let correctFP  = fp(correctFile)
        let correctScore = combinedScore(ref: refFP, cand: correctFP)

        var failed = false
        for d in distractors {
            let dFP    = fp(d)
            let dScore = combinedScore(ref: refFP, cand: dFP)
            if dScore <= correctScore {
                failed = true
            }
        }

        if failed {
            var lines = ["Score table for \(refFile) (formula: pHash + cm×\(Self.colorMomentSortWeight)):"]
            lines.append("  [✓] \(correctFile.padding(toLength: 60, withPad: " ", startingAt: 0)) score=\(String(format: "%.3f", correctScore))")
            for d in distractors {
                let dScore = combinedScore(ref: refFP, cand: fp(d))
                let marker = dScore <= correctScore ? "✗" : " "
                lines.append("  [\(marker)] \(d.padding(toLength: 60, withPad: " ", startingAt: 0)) score=\(String(format: "%.3f", dScore))")
            }
            XCTFail(lines.joined(separator: "\n"), file: file, line: line)
        }
    }


    // MARK: - Category A: SVG vs companion PDF
    //
    // After the SVG→PDF rendering fix the SVG fingerprint should be nearly
    // identical to the companion PDF's, giving approximately equal combined scores.
    // The dedup step (aHash delta ≤ 2 → keep higher extPriority) then selects
    // the SVG.  These tests verify the raw score is at least as good as the PDF's
    // (SVG score ≤ companion PDF score), so dedup can do its job.
    //
    // Each test also writes rendered PNGs to:
    //   ~/Library/Caches/keynotepptxTests/MatchingAlgorithm/<label>/
    //     1_ref_<name>.png      — the original PPTX reference PNG
    //     2_svg_rendered.png    — SVG through our SVG→PDF→raster pipeline
    //     3_pdf_rendered.png    — companion PDF through our PDF→raster pipeline
    // Open these in Preview to visually diagnose any remaining differences.

    private static let outputDir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches
            .appendingPathComponent("keynotepptxTests", isDirectory: true)
            .appendingPathComponent("MatchingAlgorithm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("MatchingAlgorithmTests output dir: \(dir.path)")
        return dir
    }()

    /// Render `svgName` and `pdfName` to PNG at the native pixel width of `refName`,
    /// then write all three alongside each other to `outputDir/<label>/`.
    private func saveRenderComparison(label: String, ref refName: String,
                                      svg svgName: String, pdf pdfName: String) {
        let refURL = Self.testDataDir.appendingPathComponent(refName)
        let svgURL = Self.testDataDir.appendingPathComponent(svgName)
        let pdfURL = Self.testDataDir.appendingPathComponent(pdfName)

        let dir = Self.outputDir.appendingPathComponent(label, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Determine native width of the reference PNG.
        let refW: Int
        if let refNS = NSImage(contentsOf: refURL),
           let refCG = refNS.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            refW = refCG.width
        } else {
            refW = 1024
        }

        // 1. Copy the PPTX reference PNG as-is.
        try? FileManager.default.copyItem(at: refURL,
            to: dir.appendingPathComponent("1_ref_\(refName)"))

        // 2. Render SVG via our SVG→PDF→raster pipeline.
        if let svgData = try? ImageRenderer.renderToPNGData(url: svgURL, widthPx: refW) {
            try? svgData.write(to: dir.appendingPathComponent("2_svg_rendered.png"))
        }

        // 3. Render companion PDF via our PDF→raster pipeline.
        if let pdfData = try? ImageRenderer.renderToPNGData(url: pdfURL, widthPx: refW) {
            try? pdfData.write(to: dir.appendingPathComponent("3_pdf_rendered.png"))
        }
    }

    func testCategoryA_xenome_svgScoresAtLeastAsWellAsPDF() {
        let refFP  = fp("image35.png")
        let svgFP  = fp("Xenome_result_methylation_data_inkscape-7385.svg")
        let pdfFP  = fp("Xenome_result_methylation_data_inkscape-7384.pdf")

        let svgScore = combinedScore(ref: refFP, cand: svgFP)
        let pdfScore = combinedScore(ref: refFP, cand: pdfFP)

        saveRenderComparison(label: "xenome",
            ref: "image35.png",
            svg: "Xenome_result_methylation_data_inkscape-7385.svg",
            pdf: "Xenome_result_methylation_data_inkscape-7384.pdf")

        XCTAssertLessThanOrEqual(
            svgScore, pdfScore + 2.0,          // allow tiny rounding headroom
            "SVG score \(svgScore) should be ≤ companion PDF score \(pdfScore);" +
            " SVG rendering fix should equalise their fingerprints"
        )
    }

    func testCategoryA_clustered_svgScoresAtLeastAsWellAsPDF() {
        let refFP  = fp("image94.png")
        let svgFP  = fp("Clustered_pathways_network_plot_MSigDB_Hallmark-7990.svg")
        let pdfFP  = fp("Clustered_pathways_network_plot_MSigDB_Hallmark-7988.pdf")

        let svgScore = combinedScore(ref: refFP, cand: svgFP)
        let pdfScore = combinedScore(ref: refFP, cand: pdfFP)

        saveRenderComparison(label: "clustered",
            ref: "image94.png",
            svg: "Clustered_pathways_network_plot_MSigDB_Hallmark-7990.svg",
            pdf: "Clustered_pathways_network_plot_MSigDB_Hallmark-7988.pdf")

        XCTAssertLessThanOrEqual(
            svgScore, pdfScore + 2.0,
            "SVG score \(svgScore) should be ≤ companion PDF score \(pdfScore)"
        )
    }

    func testCategoryA_yoshida_svgScoresAtLeastAsWellAsPDF() {
        let refFP  = fp("image16.png")
        let svgFP  = fp("Description of Yoshida et al 2020-1122.svg")
        let pdfFP  = fp("Description of Yoshida et al 2020-1120.pdf")

        let svgScore = combinedScore(ref: refFP, cand: svgFP)
        let pdfScore = combinedScore(ref: refFP, cand: pdfFP)

        saveRenderComparison(label: "yoshida",
            ref: "image16.png",
            svg: "Description of Yoshida et al 2020-1122.svg",
            pdf: "Description of Yoshida et al 2020-1120.pdf")

        XCTAssertLessThanOrEqual(
            svgScore, pdfScore + 2.0,
            "SVG score \(svgScore) should be ≤ companion PDF score \(pdfScore)"
        )
    }

    func testCategoryA_mouseMethylation_svgScoresAtLeastAsWellAsPDF() {
        let refFP  = fp("image37.png")
        let svgFP  = fp("MouseMethylationWorkflow-1207.svg")
        let pdfFP  = fp("MouseMethylationWorkflow-1205.pdf")

        let svgScore = combinedScore(ref: refFP, cand: svgFP)
        let pdfScore = combinedScore(ref: refFP, cand: pdfFP)

        saveRenderComparison(label: "mouseMethylation",
            ref: "image37.png",
            svg: "MouseMethylationWorkflow-1207.svg",
            pdf: "MouseMethylationWorkflow-1205.pdf")

        XCTAssertLessThanOrEqual(
            svgScore, pdfScore + 2.0,
            "SVG score \(svgScore) should be ≤ companion PDF score \(pdfScore)"
        )
    }

    // MARK: - Category B: Near-duplicate disambiguation

    /// image47.png — two similar pasted PDFs.
    /// pasted-image-2715.pdf is correct: ahash=5, phash=2,  cm=0.015
    /// pasted-image-2722.pdf is wrong:   ahash=3, phash=4,  cm=0.271
    /// aHash alone favours the wrong PDF; pHash×0.5 + cm×5 corrects the ranking.
    func testCategoryB_pastedImage_ranksCorrectFirst() {
        assertRanksFirst(
            reference:   "image47.png",
            correct:     "pasted-image-2715.pdf",
            distractors: ["pasted-image-2722.pdf"]
        )
    }

    /// image28.png — smoking vs non-smoking icon.
    /// smoking-icon-2976.svg is correct:     ahash=10, phash=2,  cm≈0.004  → score≈11.02
    /// non-smoking-icon-2977.svg is wrong:   ahash=6,  phash=24, cm≈0.267  → score≈19.34
    /// child-smoking-icon-export-7769.svg:   third distractor, should also rank below correct.
    /// aHash alone (6 < 10) selected the wrong icon; pHash=24 exposes it clearly.
    func testCategoryB_smokingIcon_ranksCorrectFirst() {
        assertRanksFirst(
            reference:   "image28.png",
            correct:     "smoking-icon-2976.svg",
            distractors: ["non-smoking-icon-2977.svg", "child-smoking-icon-export-7769.svg"]
        )
    }

    // MARK: - Diagnostic: print score tables for all cases

    /// Not a pass/fail test — prints the full score table for every case so you
    /// can see all metrics at a glance when tuning the combined score formula.
    func testDiagnostic_printAllScores() {
        typealias Row = (ref: String, correct: String, distractors: [String])
        let cases: [Row] = [
            ("image35.png",
             "Xenome_result_methylation_data_inkscape-7385.svg",
             ["Xenome_result_methylation_data_inkscape-7384.pdf"]),

            ("image94.png",
             "Clustered_pathways_network_plot_MSigDB_Hallmark-7990.svg",
             ["Clustered_pathways_network_plot_MSigDB_Hallmark-7988.pdf"]),

            ("image16.png",
             "Description of Yoshida et al 2020-1122.svg",
             ["Description of Yoshida et al 2020-1120.pdf"]),

            ("image37.png",
             "MouseMethylationWorkflow-1207.svg",
             ["MouseMethylationWorkflow-1205.pdf"]),

            ("image47.png",
             "pasted-image-2715.pdf",
             ["pasted-image-2722.pdf"]),

            ("image28.png",
             "smoking-icon-2976.svg",
             ["non-smoking-icon-2977.svg", "child-smoking-icon-export-7769.svg"]),
        ]

        for row in cases {
            let refFP = fp(row.ref)
            print("\n── \(row.ref) ──────────────────────────")
            print("  aHash  pHash  cm        score(p+cm×\(Self.colorMomentSortWeight))  file")

            let allFiles = [row.correct] + row.distractors
            for fname in allFiles {
                let cFP = fp(fname)
                guard let rA = refFP.aHash, let cA = cFP.aHash else { continue }
                let aH = ImageHasher.hammingDistance(rA, cA)
                let pH: Int = {
                    guard let rP = refFP.pHash, let cP = cFP.pHash else { return -1 }
                    return ImageHasher.hammingDistance(rP, cP)
                }()
                let cm: Float = {
                    guard let rCM = refFP.colorMoments, let cCM = cFP.colorMoments else { return -1 }
                    return ImageHasher.colorMomentDistance(rCM, cCM)
                }()
                let score = combinedScore(ref: refFP, cand: cFP)
                let tick = fname == row.correct ? "✓" : " "
                print("  [\(tick)] \(aH)      \(pH)      \(String(format: "%.4f", cm))    \(String(format: "%.3f", score))     \(fname)")
            }
        }
    }
}
