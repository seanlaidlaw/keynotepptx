import Foundation

/// Traverses Keynote's object graph to map each data asset to the slide(s) it appears on.
///
/// Mirrors Python `parse_keynote_slide_media` in app.py:448.
struct SlideGraphTraversal {

    // All decoded archives keyed by object identifier
    let archives: [UInt64: (header: IWAArchiveHeader, payload: Data)]
    // Object IDs that belong to template slides (to be skipped)
    let templateObjectIDs: Set<UInt64>
    // data-reference-ID → filename (from Data/ directory)
    let idToFilename: [UInt64: String]

    // KN.ShowArchive message type ID
    private static let showArchiveType: UInt32 = 2

    // MARK: - Public API

    /// Returns a map of filename → [slide numbers] (1-based) and the total slide count.
    func buildSlideMediaMap() -> (mediaMap: [String: [Int]], slideCount: Int) {
        // Find all archives whose first message is type 2 (KN.ShowArchive)
        var showArchives: [(identifier: UInt64, payload: Data)] = []
        for (id, archive) in archives {
            guard let firstMsg = archive.header.messageInfos.first,
                  firstMsg.type == Self.showArchiveType else { continue }
            showArchives.append((id, archive.payload))
        }

        var result: [String: Set<Int>] = [:]
        var slideCount = 0

        for showArchive in showArchives {
            // Parse slide list from KN.ShowArchive payload
            guard let slideNodeIDs = try? parseSlideNodeIDs(from: showArchive.payload) else { continue }
            slideCount = max(slideCount, slideNodeIDs.count)

            for (slideIndex, nodeID) in slideNodeIDs.enumerated() {
                let slideNumber = slideIndex + 1
                // DFS from nodeID collecting data references
                var visited = Set<UInt64>()
                let dataRefs = collectDataRefs(from: nodeID, visited: &visited)
                for ref in dataRefs {
                    guard let filename = idToFilename[ref],
                          !Self.isIgnoredPreview(filename) else { continue }
                    result[filename, default: []].insert(slideNumber)
                }
            }
        }

        return (result.mapValues { Array($0).sorted() }, slideCount)
    }

    // MARK: - Slide node ID extraction

    /// Parse KN.ShowArchive payload to extract slide node object IDs.
    /// Field 3 of the archive payload = slideTree message.
    /// Within slideTree, field 2 (repeated) = TSP.Reference with field 1 = object ID.
    private func parseSlideNodeIDs(from payload: Data) throws -> [UInt64] {
        var reader = ProtoReader(payload)
        var slideIDs: [UInt64] = []

        while reader.hasMore {
            let tag = try reader.readVarint()
            let fieldNumber = tag >> 3
            let wireType = UInt8(tag & 0x7)

            if fieldNumber == 3 { // slideTree
                let slideTreeData = try reader.readLengthDelimited()
                slideIDs.append(contentsOf: try parseSlideTree(slideTreeData))
            } else {
                try reader.skipField(wireType: wireType)
            }
        }
        return slideIDs
    }

    private func parseSlideTree(_ data: Data) throws -> [UInt64] {
        var reader = ProtoReader(data)
        var ids: [UInt64] = []

        while reader.hasMore {
            let tag = try reader.readVarint()
            let fieldNumber = tag >> 3
            let wireType = UInt8(tag & 0x7)

            if fieldNumber == 2 { // repeated slide references
                let refData = try reader.readLengthDelimited()
                if let id = try parseReference(refData) { ids.append(id) }
            } else {
                try reader.skipField(wireType: wireType)
            }
        }
        return ids
    }

    private func parseReference(_ data: Data) throws -> UInt64? {
        var reader = ProtoReader(data)
        while reader.hasMore {
            let tag = try reader.readVarint()
            let fieldNumber = tag >> 3
            let wireType = UInt8(tag & 0x7)
            if fieldNumber == 1 { return try reader.readVarint() }
            try reader.skipField(wireType: wireType)
        }
        return nil
    }

    // MARK: - DFS data reference collection

    private func collectDataRefs(from objectID: UInt64, visited: inout Set<UInt64>) -> [UInt64] {
        guard !visited.contains(objectID), !templateObjectIDs.contains(objectID) else { return [] }
        visited.insert(objectID)

        guard let archive = archives[objectID] else { return [] }
        var dataRefs: [UInt64] = []

        for msgInfo in archive.header.messageInfos {
            // Recurse into object references
            for objRef in msgInfo.objectReferences {
                dataRefs.append(contentsOf: collectDataRefs(from: objRef, visited: &visited))
            }
            // Collect data references at this node
            dataRefs.append(contentsOf: msgInfo.dataReferences)
        }

        return dataRefs
    }

    // MARK: - Preview filter

    // Matches st-<hash>-N.ext and mt-<hash>-N.ext thumbnail patterns.
    // Python filters st- via is_keynote_ignored_preview; mt- thumbnails (master-slide previews)
    // have the same format and must also be excluded to prevent them from contaminating
    // slide-media mapping and xml_exact candidate counts.
    private static let thumbnailPreviewPattern = try! NSRegularExpression(
        pattern: #"^(st|mt)-[0-9A-Fa-f-]+-\d+\.(png|jpe?g|tiff?|gif|bmp|webp)$"#,
        options: .caseInsensitive
    )

    static func isIgnoredPreview(_ filename: String) -> Bool {
        if filename.contains("-small-") { return true }
        let range = NSRange(filename.startIndex..., in: filename)
        return thumbnailPreviewPattern.firstMatch(in: filename, range: range) != nil
    }
}

// MARK: - Filename → ID extraction

extension SlideGraphTraversal {
    private static let trailingIDPattern = try! NSRegularExpression(pattern: #"-(\d+)$"#)

    /// Extract the trailing numeric ID from a Keynote Data/ filename.
    /// e.g. "Image-1234567890.png" → 1234567890
    static func extractDataRefID(from filename: String) -> UInt64? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let nsRange = NSRange(stem.startIndex..., in: stem)
        guard let match = trailingIDPattern.firstMatch(in: stem, range: nsRange),
              let range = Range(match.range(at: 1), in: stem) else { return nil }
        return UInt64(stem[range])
    }
}
