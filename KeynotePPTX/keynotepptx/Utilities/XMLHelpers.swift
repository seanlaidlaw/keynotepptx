import Foundation

enum XMLHelpers {

    /// Recursively replace all occurrences of `old` with `new` in every
    /// `.xml` and `.rels` file under `directory`.
    static func replaceTextRefs(in directory: URL, old: String, new: String) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "xml" || ext == "rels" else { continue }
            var text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains(old) else { continue }
            text = text.replacingOccurrences(of: old, with: new)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Register a new media type in `[Content_Types].xml`.
    static func registerContentType(
        extension ext: String,
        contentType: String,
        in pptxDir: URL
    ) throws {
        let ctURL = pptxDir.appendingPathComponent("[Content_Types].xml")
        let doc = try XMLDocument(contentsOf: ctURL, options: [])
        guard let root = doc.rootElement() else { return }

        let extLower = ext.lowercased()
        // Check if already registered
        let existing = root.elements(forName: "Default")
        for node in existing {
            if node.attribute(forName: "Extension")?.stringValue?.lowercased() == extLower { return }
        }

        let node = XMLElement(name: "Default")
        node.addAttribute(XMLNode.attribute(withName: "Extension", stringValue: ext) as! XMLNode)
        node.addAttribute(XMLNode.attribute(withName: "ContentType", stringValue: contentType) as! XMLNode)
        root.addChild(node)

        let data = doc.xmlData(options: [.nodePrettyPrint])
        try data.write(to: ctURL)
    }
}
