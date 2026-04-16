import Foundation
import PDFKit
import AppKit

// MARK: - Result

/// Similarity metrics between one SVG and one PDF, used to confirm they are
/// Keynote's SVG-plus-companion-PDF pair (same source image, consecutive asset IDs).
struct SVGPDFSimilarityResult {
    /// |svgPhysicalPt_W - pdfPagePt_W|, max with height.  0 = identical.
    let dimensionDelta: CGFloat
    /// True when dimensionDelta < 2 pt.
    let dimensionMatch: Bool

    /// Unique words extracted from SVG <text> elements.
    let svgWordCount: Int
    /// Unique words extracted from the PDF page.
    let pdfWordCount: Int
    /// Words that appear in both.
    let commonWordCount: Int
    /// commonWords / union(svgWords, pdfWords).  0 when neither has extractable text.
    let textOverlap: Double

    /// SVG text elements whose normalised x-position matched a PDF word (within 2 %).
    let xMatchCount: Int
    /// SVG text elements that were compared (had a matching word in the PDF).
    let xMatchTotal: Int

    /// Combined 0–1 confidence that this SVG/PDF is a companion pair.
    let confidence: Double

    /// Convenience: true when confidence ≥ 0.65.
    var isCompanionPair: Bool { confidence >= 0.65 }
}

// MARK: - Validator

/// Validates whether an SVG and a PDF file represent the same source image by
/// comparing physical dimensions, text word content, and text x-positions.
///
/// ## How Keynote creates companion PDFs
/// When a user imports an SVG, Keynote rasterises the SVG internally and stores
/// a companion PDF alongside it (consecutive asset IDs, delta ≤ 2).  The companion
/// PDF contains the same image with fonts already substituted and baked in.
/// When exporting to PPTX, Keynote renders the *companion PDF* — not the SVG.
///
/// ## Signals used
/// 1. **Dimension match** — SVG physical size (in PDF points) must equal PDF page size
///    within 2 pt.  Unit conversion: `px`/unitless → 1:1; `pt` → ×(96/72) because
///    `_NSSVGImageRep` renders pt-unit SVGs at 96 DPI.
///
/// 2. **Text word overlap** — If the SVG has `<text>` elements, the set of words must
///    overlap substantially with the words the PDF exposes via PDFKit.
///
/// 3. **Text x-position match** — For each SVG text element whose first word appears
///    in the PDF, the normalised x-position (x ÷ own-width) must agree within 2 %.
enum SVGPDFPairValidator {

    static func validate(svg svgURL: URL, pdf pdfURL: URL) -> SVGPDFSimilarityResult {
        let sm = parseSVGMetrics(url: svgURL)
        guard let pm = parsePDFMetrics(url: pdfURL) else {
            return zeroResult()
        }

        // 1. Dimension match
        let delta = dimensionDelta(svg: sm, pdf: pm)
        let dimMatch = delta < 2.0

        // 2. Text word set overlap
        let svgWords = Set(
            sm.texts
                .flatMap { $0.content.split(separator: " ").map(String.init) }
                .filter { !$0.isEmpty }
        )
        let pdfWords = Set(pm.words.map(\.text).filter { !$0.isEmpty })
        let unionCount  = svgWords.union(pdfWords).count
        let commonCount = svgWords.intersection(pdfWords).count
        let overlap = unionCount > 0 ? Double(commonCount) / Double(unionCount) : 0.0

        // 3. Text x-position match (normalised to respective page widths)
        var xOk = 0, xTotal = 0
        let svgUsW = sm.userSpaceWidth  > 0 ? sm.userSpaceWidth  : 1
        let pdfW   = pm.width           > 0 ? pm.width           : 1

        for svgText in sm.texts {
            guard let firstWord = svgText.content.split(separator: " ").first.map(String.init),
                  !firstWord.isEmpty else { continue }
            if let pdfWord = pm.words.first(where: { $0.text == firstWord }) {
                xTotal += 1
                let svgNorm = svgText.x / svgUsW
                let pdfNorm = pdfWord.xMin / pdfW
                if abs(svgNorm - pdfNorm) < 0.02 { xOk += 1 }
            }
        }

        // 4. Confidence
        let hasText = !svgWords.isEmpty || !pdfWords.isEmpty
        var score: Double = dimMatch ? 0.50 : max(0, 0.50 - Double(delta) / 100.0)
        if hasText {
            score += overlap * 0.35
            if xTotal > 0 { score += (Double(xOk) / Double(xTotal)) * 0.15 }
        } else {
            // No extractable text — dimension alone drives the decision.
            if dimMatch { score = min(score + 0.30, 0.80) }
        }

        return SVGPDFSimilarityResult(
            dimensionDelta:  delta,
            dimensionMatch:  dimMatch,
            svgWordCount:    svgWords.count,
            pdfWordCount:    pdfWords.count,
            commonWordCount: commonCount,
            textOverlap:     overlap,
            xMatchCount:     xOk,
            xMatchTotal:     xTotal,
            confidence:      min(score, 1.0)
        )
    }

    // MARK: - SVG metrics

    private struct SVGMetrics {
        var rawWidth:        CGFloat = 0
        var rawHeight:       CGFloat = 0
        var widthUnit:       String  = "px"
        var heightUnit:      String  = "px"
        /// ViewBox coordinate-space width (equals rawWidth when no viewBox).
        var userSpaceWidth:  CGFloat = 0
        var userSpaceHeight: CGFloat = 0
        /// Equivalent PDF page width in points.
        var physicalPtWidth: CGFloat = 0
        var physicalPtHeight:CGFloat = 0
        var texts: [(x: CGFloat, content: String)] = []
    }

    private static func parseSVGMetrics(url: URL) -> SVGMetrics {
        guard let data = try? Data(contentsOf: url) else { return SVGMetrics() }
        let p = SVGMetricsParser()
        p.parse(data: data)
        var m = SVGMetrics()
        m.rawWidth        = p.rawWidth
        m.rawHeight       = p.rawHeight
        m.widthUnit       = p.widthUnit
        m.heightUnit      = p.heightUnit
        m.userSpaceWidth  = p.viewBoxWidth  > 0 ? p.viewBoxWidth  : p.rawWidth
        m.userSpaceHeight = p.viewBoxHeight > 0 ? p.viewBoxHeight : p.rawHeight
        m.physicalPtWidth  = toPhysicalPts(p.rawWidth,  unit: p.widthUnit)
        m.physicalPtHeight = toPhysicalPts(p.rawHeight, unit: p.heightUnit)
        m.texts           = p.texts
        return m
    }

    /// Convert an SVG dimension value+unit to PDF points, matching how NSImage/
    /// _NSSVGImageRep interprets SVG units when creating the in-memory companion PDF.
    ///
    /// Empirical rules (verified against 45 SVG/PDF pairs):
    /// - `px` or unitless → 1 SVG px = 1 PDF pt  (the common case)
    /// - `pt`             → 1 SVG pt = 96/72 PDF pts  (NSImage renders at 96 DPI)
    /// - `mm`, `cm`, `in` → standard physical conversion
    private static func toPhysicalPts(_ value: CGFloat, unit: String) -> CGFloat {
        switch unit {
        case "px", "": return value
        case "pt":     return value * (96.0 / 72.0)
        case "mm":     return value * (72.0 / 25.4)
        case "cm":     return value * (72.0 / 2.54)
        case "in":     return value * 72.0
        default:       return value
        }
    }

    private static func dimensionDelta(svg: SVGMetrics, pdf: PDFMetrics) -> CGFloat {
        guard svg.physicalPtWidth > 0, pdf.width > 0 else { return .greatestFiniteMagnitude }
        return max(abs(svg.physicalPtWidth - pdf.width), abs(svg.physicalPtHeight - pdf.height))
    }

    // MARK: - PDF metrics

    private struct PDFMetrics {
        var width:  CGFloat
        var height: CGFloat
        var words:  [(text: String, xMin: CGFloat)]
    }

    private static func parsePDFMetrics(url: URL) -> PDFMetrics? {
        guard let doc  = PDFDocument(url: url),
              let page = doc.page(at: 0) else { return nil }

        let box = page.bounds(for: .mediaBox)

        // Extract word text and xMin positions via PDFKit character selections.
        // PDFKit origin is bottom-left; xMin is distance from the left edge (correct for us).
        var words: [(text: String, xMin: CGFloat)] = []
        if let pageStr = page.string, !pageStr.isEmpty {
            pageStr.enumerateSubstrings(in: pageStr.startIndex..., options: .byWords) { word, range, _, _ in
                guard let word, !word.isEmpty else { return }
                let nsRange = NSRange(range, in: pageStr)
                if let sel = page.selection(for: nsRange) {
                    let bounds = sel.bounds(for: page)
                    if bounds != .zero { words.append((text: word, xMin: bounds.minX)) }
                }
            }
        }

        return PDFMetrics(width: box.width, height: box.height, words: words)
    }

    private static func zeroResult() -> SVGPDFSimilarityResult {
        SVGPDFSimilarityResult(
            dimensionDelta: .greatestFiniteMagnitude, dimensionMatch: false,
            svgWordCount: 0, pdfWordCount: 0, commonWordCount: 0,
            textOverlap: 0, xMatchCount: 0, xMatchTotal: 0, confidence: 0
        )
    }
}

// MARK: - SAX-style SVG metrics parser

/// Lightweight XMLParser delegate that extracts only what SVGPDFPairValidator needs:
/// root-element dimensions and all <text> elements with their x-coordinate and string content.
private final class SVGMetricsParser: NSObject, XMLParserDelegate {

    private(set) var rawWidth:   CGFloat = 0
    private(set) var rawHeight:  CGFloat = 0
    private(set) var widthUnit   = "px"
    private(set) var heightUnit  = "px"
    private(set) var viewBoxWidth:  CGFloat = 0
    private(set) var viewBoxHeight: CGFloat = 0
    private(set) var texts: [(x: CGFloat, content: String)] = []

    private var rootParsed  = false
    private var inText      = false
    private var textDepth   = 0
    private var currentX:   CGFloat?
    private var currentBuf  = ""

    func parse(data: Data) {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attrs: [String: String] = [:]) {
        let el = element.lowercased()

        if el == "svg", !rootParsed {
            rootParsed = true
            parseSVGRoot(attrs)
            return
        }

        if el == "text" {
            inText    = true
            textDepth = 1
            currentBuf = ""
            currentX   = xCoord(from: attrs)
            return
        }

        if inText {
            textDepth += 1
            // Inherit x from <tspan> if the <text> itself had none
            if el == "tspan", currentX == nil, let tx = xCoord(from: attrs) {
                currentX = tx
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentBuf += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if inText {
            textDepth -= 1
            if textDepth == 0 {
                let content = currentBuf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty, let x = currentX {
                    texts.append((x: x, content: content))
                }
                inText    = false
                currentX  = nil
                currentBuf = ""
            }
        }
    }

    // MARK: - Helpers

    private func parseSVGRoot(_ attrs: [String: String]) {
        if let w = attrs["width"]  { (rawWidth,  widthUnit)  = dimension(w) }
        if let h = attrs["height"] { (rawHeight, heightUnit) = dimension(h) }
        if let vb = attrs["viewBox"] {
            let parts = vb.replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").compactMap { Double($0) }
            if parts.count >= 4 {
                viewBoxWidth  = CGFloat(parts[2])
                viewBoxHeight = CGFloat(parts[3])
            }
        }
    }

    /// Extracts the x-coordinate from a `<text>` or `<tspan>` element's attributes.
    /// Handles three SVG transform patterns:
    ///   - `transform="translate(x y)"`
    ///   - `transform="matrix(a b c d tx ty)"` — tx is element [4]
    ///   - `x="value"` attribute
    private func xCoord(from attrs: [String: String]) -> CGFloat? {
        if let t = attrs["transform"] {
            // matrix(a b c d tx ty)
            if let range = t.range(of: #"matrix\(([^)]+)\)"#, options: .regularExpression) {
                let inner = String(t[range]).dropFirst(7).dropLast()   // strip "matrix(" and ")"
                let parts = inner.replacingOccurrences(of: ",", with: " ")
                    .split(separator: " ").compactMap { Double($0) }
                if parts.count >= 5 { return CGFloat(parts[4]) }
            }
            // translate(x y) or translate(x,y)
            if let range = t.range(of: #"translate\(([^)]+)\)"#, options: .regularExpression) {
                let inner = String(t[range]).dropFirst(10).dropLast()  // strip "translate(" and ")"
                let parts = inner.replacingOccurrences(of: ",", with: " ")
                    .split(separator: " ").compactMap { Double($0) }
                if let first = parts.first { return CGFloat(first) }
            }
        }
        if let x = attrs["x"], let v = Double(x) { return CGFloat(v) }
        return nil
    }

    /// Parses an SVG dimension string into (value, unit).
    /// E.g. "558.00pt" → (558.0, "pt"), "1024" → (1024.0, "px").
    private func dimension(_ s: String) -> (CGFloat, String) {
        let s = s.trimmingCharacters(in: .whitespaces)
        let numStr = s.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })
        let unit   = String(s.dropFirst(numStr.count)).lowercased()
        return (CGFloat(Double(numStr) ?? 0), unit.isEmpty ? "px" : unit)
    }
}
