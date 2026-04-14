import Foundation

/// Decodes a Keynote package (already unzipped) and builds a list of media items
/// with their associated slide numbers.
///
/// Mirrors Python `parse_keynote_slide_media` in app.py:448.
enum KeynoteParser {

    static func parse(
        keynoteDir: URL
    ) async throws -> (items: [KeynoteMediaItem], slideMedia: [String: [Int]]) {

        let fm = FileManager.default
        let indexDir = keynoteDir.appendingPathComponent("Index")
        let dataDir = keynoteDir.appendingPathComponent("Data")

        // --- Enumerate IWA files ---
        guard let iwaFiles = try? fm.contentsOfDirectory(at: indexDir, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "iwa" }) else {
            return ([], [:])
        }

        // Identify template slide IWA files
        let templateFileNames = iwaFiles.filter {
            $0.lastPathComponent.lowercased().contains("templateslide")
        }

        // Decode all IWA files in parallel
        var allArchives: [UInt64: (header: IWAArchiveHeader, payload: Data)] = [:]
        var templateObjectIDs = Set<UInt64>()

        let decodeResults = await withTaskGroup(
            of: (isTemplate: Bool, archives: [(header: IWAArchiveHeader, payload: Data)]).self
        ) { group in
            for url in iwaFiles {
                let isTemplate = templateFileNames.contains(url)
                group.addTask {
                    guard let raw = try? Data(contentsOf: url),
                          let decoded = try? IWADecoder.decode(raw) else {
                        return (isTemplate, [])
                    }
                    return (isTemplate, decoded)
                }
            }
            var collected: [(isTemplate: Bool, archives: [(header: IWAArchiveHeader, payload: Data)])] = []
            for await result in group { collected.append(result) }
            return collected
        }

        for result in decodeResults {
            for archive in result.archives {
                let id = archive.header.identifier
                allArchives[id] = archive
                if result.isTemplate { templateObjectIDs.insert(id) }
            }
        }

        // --- Build data-reference-ID → filename map from Data/ directory ---
        var idToFilename: [UInt64: String] = [:]
        if let dataFiles = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil) {
            for url in dataFiles {
                let filename = url.lastPathComponent
                if let id = SlideGraphTraversal.extractDataRefID(from: filename) {
                    idToFilename[id] = filename
                }
            }
        }

        // --- Traverse slide graph ---
        let traversal = SlideGraphTraversal(
            archives: allArchives,
            templateObjectIDs: templateObjectIDs,
            idToFilename: idToFilename
        )
        let slideMedia = traversal.buildSlideMediaMap()

        // --- Build KeynoteMediaItem list from Data/ ---
        var items: [KeynoteMediaItem] = []
        if let dataFiles = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil) {
            for url in dataFiles {
                let filename = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                let imageExtensions: Set<String> = ["svg", "pdf", "png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "webp", "heic"]
                guard imageExtensions.contains(ext),
                      !SlideGraphTraversal.isIgnoredPreview(filename) else { continue }
                let objectID = SlideGraphTraversal.extractDataRefID(from: filename).map { String($0) } ?? ""
                let slides = slideMedia[filename] ?? []
                items.append(KeynoteMediaItem(
                    filename: filename,
                    absolutePath: url,
                    slideNumbers: slides,
                    objectID: objectID
                ))
            }
        }

        return (items, slideMedia)
    }
}
