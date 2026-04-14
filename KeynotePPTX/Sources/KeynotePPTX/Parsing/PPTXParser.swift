import Foundation

/// Parses a PPTX directory (already unzipped) to discover which media files
/// appear on which slide numbers, and which are master/layout only.
///
/// Mirrors Python `parse_ppt_slide_media` in app.py:530.
enum PPTXParser {

    private static let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"

    static func parse(pptxDir: URL) throws -> (slideMedia: [String: [Int]], masterOnlyMedia: Set<String>) {
        let fm = FileManager.default

        // --- Slide content media ---
        var slideMedia: [String: [Int]] = [:]
        let slideRelsDir = pptxDir.appendingPathComponent("ppt/slides/_rels")

        if fm.fileExists(atPath: slideRelsDir.path) {
            let relsFiles = try fm.contentsOfDirectory(at: slideRelsDir, includingPropertiesForKeys: nil)
            for relsURL in relsFiles where relsURL.pathExtension == "rels" {
                guard let slideNumber = slideNumber(from: relsURL.lastPathComponent) else { continue }
                let mediaNames = try mediaFilenames(in: relsURL)
                for name in mediaNames {
                    slideMedia[name, default: []].append(slideNumber)
                }
            }
        }
        // Sort slide lists
        for key in slideMedia.keys { slideMedia[key]?.sort() }

        let slideContentMedia = Set(slideMedia.keys)

        // --- Master / layout media ---
        var masterMedia = Set<String>()
        for subdir in ["slideMasters", "slideLayouts"] {
            let relsDir = pptxDir.appendingPathComponent("ppt/\(subdir)/_rels")
            guard fm.fileExists(atPath: relsDir.path) else { continue }
            let relsFiles = try fm.contentsOfDirectory(at: relsDir, includingPropertiesForKeys: nil)
            for relsURL in relsFiles where relsURL.pathExtension == "rels" {
                let names = try mediaFilenames(in: relsURL)
                masterMedia.formUnion(names)
            }
        }

        let masterOnlyMedia = masterMedia.subtracting(slideContentMedia)
        return (slideMedia, masterOnlyMedia)
    }

    // MARK: - Helpers

    /// Extract media filenames from a .rels XML file.
    private static func mediaFilenames(in relsURL: URL) throws -> [String] {
        let doc = try XMLDocument(contentsOf: relsURL, options: [])
        guard let root = doc.rootElement() else { return [] }
        var names: [String] = []
        for node in root.elements(forName: "Relationship") {
            guard let target = node.attribute(forName: "Target")?.stringValue,
                  target.lowercased().contains("/media/") else { continue }
            let filename = URL(fileURLWithPath: target).lastPathComponent
            if !filename.isEmpty { names.append(filename) }
        }
        return names
    }

    private static let slideRelsPattern = try! NSRegularExpression(pattern: #"slide(\d+)\.xml\.rels$"#)

    /// Extract slide number from a rels filename like "slide3.xml.rels" → 3.
    private static func slideNumber(from filename: String) -> Int? {
        let nsRange = NSRange(filename.startIndex..., in: filename)
        guard let match = slideRelsPattern.firstMatch(in: filename, range: nsRange),
              let range = Range(match.range(at: 1), in: filename) else { return nil }
        return Int(filename[range])
    }
}
