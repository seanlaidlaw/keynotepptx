import Foundation

/// Mirrors Python `build_mapping` in app.py:755.
enum MatchEngine {

    private static let aHashThreshold = 25
    private static let pHashThreshold = 7
    private static let aHashDedupThreshold = 2
    private static let colorMomentAutoSelectThreshold: Float = 10.0

    // Extension priority for deduplication (lower = preferred)
    private static let extPriority: [String: Int] = [
        "svg": 0, "pdf": 1, "png": 2, "jpg": 3, "jpeg": 3, "tiff": 4, "tif": 4
    ]

    // MARK: - Public

    static func buildMappingRows(
        pptxItems: [PPTXMediaItem],
        keynoteItems: [KeynoteMediaItem],
        pptxFingerprints: [String: ImageFingerprint],
        keynoteFingerprints: [String: ImageFingerprint],
        slideMedia: [String: [Int]],
        keynoteSlideMedia: [String: [Int]]
    ) -> [MappingRow] {

        // Build lookup: Keynote filename → item
        let keynoteByName: [String: KeynoteMediaItem] = Dictionary(
            keynoteItems.map { ($0.filename, $0) }, uniquingKeysWith: { a, _ in a }
        )
        // Available Keynote names set
        let keynoteNames = Set(keynoteItems.map(\.filename))

        var rows: [MappingRow] = []

        for pptxItem in pptxItems {
            guard let pptxFP = pptxFingerprints[pptxItem.filename] else { continue }
            let pptxSlides = Set(pptxItem.slideNumbers)

            // 1. Find xml_exact candidate: Keynote image(s) on the same slides
            var xmlExactCandidate: String? = nil
            if !pptxSlides.isEmpty {
                let candidatesOnSlides = keynoteItems.filter { ki in
                    !Set(ki.slideNumbers).isDisjoint(with: pptxSlides)
                }
                if candidatesOnSlides.count == 1 {
                    var keyName = candidatesOnSlides[0].filename
                    // If xml_exact is PDF, check for same-stem SVG sibling
                    if URL(fileURLWithPath: keyName).pathExtension.lowercased() == "pdf" {
                        let stemNoID = stripTrailingID(stem: URL(fileURLWithPath: keyName).deletingPathExtension().lastPathComponent)
                        for candidate in keynoteNames {
                            if URL(fileURLWithPath: candidate).pathExtension.lowercased() == "svg" {
                                let cStem = stripTrailingID(stem: URL(fileURLWithPath: candidate).deletingPathExtension().lastPathComponent)
                                if cStem == stemNoID { keyName = candidate; break }
                            }
                        }
                    }
                    xmlExactCandidate = keyName
                }
            }

            // 2. Score all keynote candidates
            var scored: [ScoredCandidate] = []

            for keynoteItem in keynoteItems {
                guard let keyFP = keynoteFingerprints[keynoteItem.filename] else { continue }
                guard let pAHash = pptxFP.aHash, let kAHash = keyFP.aHash else { continue }

                let aHashDist = ImageHasher.hammingDistance(pAHash, kAHash)
                guard aHashDist <= aHashThreshold else { continue }

                let pHashDist: Int
                if let ppHash = pptxFP.pHash, let kpHash = keyFP.pHash {
                    pHashDist = ImageHasher.hammingDistance(ppHash, kpHash)
                } else {
                    pHashDist = 64
                }

                let cmDist: Float
                if let pcm = pptxFP.colorMoments, let kcm = keyFP.colorMoments {
                    cmDist = ImageHasher.colorMomentDistance(pcm, kcm)
                } else {
                    cmDist = Float.infinity
                }

                let ext = URL(fileURLWithPath: keynoteItem.filename).pathExtension.lowercased()
                let priority = extPriority[ext] ?? 5
                let kind: ReplacementKind = ext == "svg" ? .svg : ext == "pdf" ? .pdf : .raster

                scored.append(ScoredCandidate(
                    item: keynoteItem, fp: keyFP,
                    aHashDist: aHashDist, pHashDist: pHashDist, cmDist: cmDist,
                    extPriority: priority, kind: kind
                ))
            }

            // Sort by colorMoment distance, then aHash
            scored.sort { lhs, rhs in
                if lhs.cmDist != rhs.cmDist { return lhs.cmDist < rhs.cmDist }
                return lhs.aHashDist < rhs.aHashDist
            }

            // 3. Deduplicate visually identical candidates
            scored = deduplicate(scored)

            // 4. Take top 3
            let top3 = Array(scored.prefix(3))

            // 5. Build CandidateMatch objects
            let candidates = top3.map { sc -> CandidateMatch in
                CandidateMatch(
                    keynoteFilename: sc.item.filename,
                    keynotePath: sc.item.absolutePath,
                    fileExtension: URL(fileURLWithPath: sc.item.filename).pathExtension.lowercased(),
                    fileSizeBytes: sc.fp.fileSizeBytes,
                    thumbnailData: sc.fp.thumbnailData,
                    aHashDistance: sc.aHashDist,
                    pHashDistance: sc.pHashDist,
                    colorMomentDistance: sc.cmDist,
                    replacementKind: sc.kind
                )
            }

            // 6. Determine quality
            let isXmlExact = xmlExactCandidate != nil
            let quality = classifyQuality(
                top: top3.first,
                isXmlExact: isXmlExact
            )

            // 7. Default choice
            let selectedChoice: RowChoice
            if let xmlName = xmlExactCandidate {
                selectedChoice = .keynoteFile(filename: xmlName)
            } else if let first = top3.first, first.cmDist < colorMomentAutoSelectThreshold {
                selectedChoice = .keynoteFile(filename: first.item.filename)
            } else {
                selectedChoice = .skip
            }

            rows.append(MappingRow(
                pptxItem: pptxItem,
                pptxFingerprint: pptxFP,
                topCandidates: candidates,
                quality: quality,
                isXmlExact: isXmlExact,
                selectedChoice: selectedChoice
            ))
        }

        // Sort: xml_exact first, then by quality descending, then by filename
        rows.sort { lhs, rhs in
            let lp = qualityOrder(lhs.quality)
            let rp = qualityOrder(rhs.quality)
            if lp != rp { return lp < rp }
            return lhs.pptxItem.filename < rhs.pptxItem.filename
        }

        return rows
    }

    // MARK: - Helpers

    private struct ScoredCandidate {
        let item: KeynoteMediaItem
        let fp: ImageFingerprint
        let aHashDist: Int
        let pHashDist: Int
        let cmDist: Float
        let extPriority: Int
        let kind: ReplacementKind
    }

    /// Collapse visually identical candidates (aHash distance ≤ 2), keeping the one
    /// with lowest extension priority (SVG > PDF > PNG > …). Mirrors Python _dedup_candidates.
    private static func deduplicate(_ candidates: [ScoredCandidate]) -> [ScoredCandidate] {
        var kept: [ScoredCandidate] = []
        for cand in candidates {
            var merged = false
            for i in kept.indices {
                let k = kept[i]
                let aClose = ImageHasher.hammingDistance(
                    cand.fp.aHash ?? 0, k.fp.aHash ?? UInt64.max
                ) <= aHashDedupThreshold
                let pIdentical = (cand.fp.pHash != nil && k.fp.pHash != nil &&
                                  cand.fp.pHash == k.fp.pHash)
                if aClose || pIdentical {
                    if cand.extPriority < k.extPriority { kept[i] = cand }
                    merged = true
                    break
                }
            }
            if !merged { kept.append(cand) }
        }
        return kept
    }

    private static func classifyQuality(top: ScoredCandidate?, isXmlExact: Bool) -> MatchQuality {
        guard let top else { return .noMatch }
        if isXmlExact { return top.aHashDist == 0 ? .exact : .xmlExact }
        switch top.aHashDist {
        case 0: return .exact
        case 1...7: return .strong
        case 8...15: return .review
        case 16...25: return .poor
        default: return .noMatch
        }
    }

    private static func qualityOrder(_ q: MatchQuality) -> Int {
        switch q {
        case .xmlExact: return 0
        case .exact:    return 1
        case .strong:   return 2
        case .review:   return 3
        case .poor:     return 4
        case .noMatch:  return 5
        }
    }

    private static let trailingIDPattern = try! NSRegularExpression(pattern: #"^(.*)-\d+$"#)

    /// Strip trailing -\d+ from a filename stem (to match SVG/PDF siblings).
    private static func stripTrailingID(stem: String) -> String {
        let nsRange = NSRange(stem.startIndex..., in: stem)
        guard let match = trailingIDPattern.firstMatch(in: stem, range: nsRange),
              let range = Range(match.range(at: 1), in: stem) else { return stem }
        return String(stem[range])
    }
}
