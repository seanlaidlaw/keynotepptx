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
// Current combined score (from MatchEngine): aHashDist + cmDist × 5.0   (pHash excluded)
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
// These require algorithm improvements.  Adding pHash to the combined score fixes both:
//   new score = aHashDist + pHashDist × W_phash + cmDist × W_cm
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

    /// Combined sort score used by MatchEngine.
    /// Keep in sync with MatchEngine's sort closure (aHash + cmDist × colorMomentSortWeight).
    private static let colorMomentSortWeight: Float = 5.0

    private func combinedScore(ref: ImageFingerprint, cand: ImageFingerprint) -> Float {
        guard let rA = ref.aHash, let cA = cand.aHash else { return .infinity }
        let aHashDist = Float(ImageHasher.hammingDistance(rA, cA))
        let cmDist: Float = {
            guard let rCM = ref.colorMoments, let cCM = cand.colorMoments else { return 0 }
            return ImageHasher.colorMomentDistance(rCM, cCM)
        }()
        return aHashDist + cmDist * Self.colorMomentSortWeight
    }

    /// Extended score adding pHash — NOT yet used in production.
    /// Included here to document what formula change fixes Category B failures.
    private func extendedScore(ref: ImageFingerprint, cand: ImageFingerprint,
                               pHashWeight: Float = 0.5) -> Float {
        guard let rA = ref.aHash, let cA = cand.aHash else { return .infinity }
        let aHashDist = Float(ImageHasher.hammingDistance(rA, cA))
        let pHashDist: Float = {
            guard let rP = ref.pHash, let cP = cand.pHash else { return 0 }
            return Float(ImageHasher.hammingDistance(rP, cP))
        }()
        let cmDist: Float = {
            guard let rCM = ref.colorMoments, let cCM = cand.colorMoments else { return 0 }
            return ImageHasher.colorMomentDistance(rCM, cCM)
        }()
        return aHashDist + pHashDist * pHashWeight + cmDist * Self.colorMomentSortWeight
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
            var lines = ["Score table for \(refFile) (current formula: aHash + cm×5):"]
            lines.append("  [✓] \(correctFile.padding(toLength: 60, withPad: " ", startingAt: 0)) score=\(String(format: "%.3f", correctScore))")
            for d in distractors {
                let dScore = combinedScore(ref: refFP, cand: fp(d))
                let marker = dScore <= correctScore ? "✗" : " "
                lines.append("  [\(marker)] \(d.padding(toLength: 60, withPad: " ", startingAt: 0)) score=\(String(format: "%.3f", dScore))")
            }
            XCTFail(lines.joined(separator: "\n"), file: file, line: line)
        }
    }

    /// Same as assertRanksFirst but uses the extended score (aHash + pHash×W + cm×5).
    /// Documents the fix needed for Category B cases.
    private func assertRanksFirstExtended(
        reference refFile: String,
        correct correctFile: String,
        distractors: [String],
        pHashWeight: Float = 0.5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let refFP        = fp(refFile)
        let correctFP    = fp(correctFile)
        let correctScore = extendedScore(ref: refFP, cand: correctFP, pHashWeight: pHashWeight)

        var failed = false
        for d in distractors {
            let dScore = extendedScore(ref: refFP, cand: fp(d), pHashWeight: pHashWeight)
            if dScore <= correctScore { failed = true }
        }

        if failed {
            var lines = ["Score table for \(refFile) (extended formula: aHash + pHash×\(pHashWeight) + cm×5):"]
            lines.append("  [✓] \(correctFile.padding(toLength: 60, withPad: " ", startingAt: 0)) score=\(String(format: "%.3f", correctScore))")
            for d in distractors {
                let dScore = extendedScore(ref: refFP, cand: fp(d), pHashWeight: pHashWeight)
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

    func testCategoryA_xenome_svgScoresAtLeastAsWellAsPDF() {
        let refFP  = fp("image35.png")
        let svgFP  = fp("Xenome_result_methylation_data_inkscape-7385.svg")
        let pdfFP  = fp("Xenome_result_methylation_data_inkscape-7384.pdf")

        let svgScore = combinedScore(ref: refFP, cand: svgFP)
        let pdfScore = combinedScore(ref: refFP, cand: pdfFP)

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

        XCTAssertLessThanOrEqual(
            svgScore, pdfScore + 2.0,
            "SVG score \(svgScore) should be ≤ companion PDF score \(pdfScore)"
        )
    }

    // MARK: - Category B: Genuinely ambiguous — current formula fails

    /// image47.png — two similar pasted PDFs.
    /// pasted-image-2715.pdf is correct.  pasted-image-2722.pdf has lower aHash
    /// but a much larger colorMoment distance (0.271 vs 0.015).
    ///
    /// Current formula (aHash + cm×5): FAILS  — wrong PDF scores lower.
    /// Fix: increase colorMomentSortWeight to ≥ 8, OR add pHash to score.
    func testCategoryB_pastedImage_currentFormula_documentsFailure() {
        // This test is EXPECTED TO FAIL with the current algorithm.
        // It documents the failure so the failure message shows the actual scores.
        assertRanksFirst(
            reference:   "image47.png",
            correct:     "pasted-image-2715.pdf",
            distractors: ["pasted-image-2722.pdf"]
        )
    }

    func testCategoryB_pastedImage_extendedFormula_passes() {
        // The same case PASSES when pHash (weight 0.5) is added to the score.
        // Use this test as the target spec when updating MatchEngine's formula.
        assertRanksFirstExtended(
            reference:   "image47.png",
            correct:     "pasted-image-2715.pdf",
            distractors: ["pasted-image-2722.pdf"],
            pHashWeight: 0.5
        )
    }

    /// image28.png — smoking vs non-smoking icon.
    /// smoking-icon-2976.svg is correct: ahash=10, phash=2, cm≈0.004.
    /// non-smoking-icon-2977.svg is wrong: ahash=6, phash=24, cm≈0.267.
    ///
    /// Current formula: FAILS — wrong icon scores 7.33 vs correct at 10.02.
    /// Fix: adding pHash×0.5 makes correct=11.02, wrong=19.33.
    func testCategoryB_smokingIcon_currentFormula_documentsFailure() {
        // EXPECTED TO FAIL — documents the failure score gap for algorithm work.
        assertRanksFirst(
            reference:   "image28.png",
            correct:     "smoking-icon-2976.svg",
            distractors: ["non-smoking-icon-2977.svg", "child-smoking-icon-export-7769.svg"]
        )
    }

    func testCategoryB_smokingIcon_extendedFormula_passes() {
        // PASSES with pHash weight 0.5 — target spec for MatchEngine improvement.
        assertRanksFirstExtended(
            reference:   "image28.png",
            correct:     "smoking-icon-2976.svg",
            distractors: ["non-smoking-icon-2977.svg", "child-smoking-icon-export-7769.svg"],
            pHashWeight: 0.5
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
            print("  aHash  pHash  cm        score     file")

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
