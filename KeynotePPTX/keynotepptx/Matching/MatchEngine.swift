import Foundation

/// Mirrors Python `build_mapping` in app.py:755.
enum MatchEngine {

    private static let aHashThreshold = 25
    private static let aHashDedupThreshold = 2
    // Auto-select the top candidate only when its pHash distance is below this threshold.
    // pHash (64-bit DCT) is the primary ranking signal; aHash is a fast pre-filter gate only.
    // Threshold 16 = end of the "review" quality band: auto-select anything review-or-better
    // (pHash ≤ 15 means ≤23% of DCT bits differ). "Poor" matches (pHash ≥ 16) require the
    // user to actively confirm. The ranking gap to the next candidate still provides safety
    // even when the top score is in the review range.
    private static let pHashAutoSelectThreshold = 16
    // Aspect-ratio pre-filter: skip candidates where aspect ratios differ by more than 10%.
    // Catches gross shape mismatches before any hashing.
    private static let aspectRatioMaxRatio: Double = 1.1
    // Sort score: pHashDist + cmDist × colorMomentSortWeight
    //
    // aHash is a fast pre-filter gate only (aHashThreshold above). It is NOT part
    // of the sort score because a low aHash distance does not reliably indicate a
    // good match — two very different images can hash close if their 8×8 averages
    // align by coincidence (e.g. smoking vs non-smoking icon: aHash=6 for the wrong
    // candidate, aHash=10 for the correct one).
    //
    // pHash encodes more structural detail (64-bit DCT) and is the primary ranking
    // signal. colorMoments disambiguate candidates with similar pHash by catching
    // colour inversions and palette swaps. W_cm=20 means a cm delta of 0.2 (a clear
    // colour shift) contributes ~4 pHash-bit equivalents — enough to break ties
    // without overriding a decisive pHash gap.
    //
    // Keep colorMomentSortWeight in sync with MatchingAlgorithmTests.combinedScore().
    private static let colorMomentSortWeight: Float = 20.0

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

        // MARK: Pre-compute xml_exact candidates (two-pass)
        // Pass 1: for each PPTX item find the single Keynote image on the same slides.
        // We track how many PPTX items claim each Keynote image so we can detect the
        // symmetric ambiguity: multiple PPTX images on the same slide all pointing at
        // the sole Keynote image there is equally ambiguous and must not auto-match.
        var rawXmlMap: [String: String] = [:]    // pptx filename → keynote filename
        var xmlKeynoteUsage: [String: Int] = [:] // keynote filename → # pptx items claiming it

        for pptxItem in pptxItems {
            let pptxSlides = Set(pptxItem.slideNumbers)
            guard !pptxSlides.isEmpty else { continue }
            let candidatesOnSlides = keynoteItems.filter { !Set($0.slideNumbers).isDisjoint(with: pptxSlides) }
            guard candidatesOnSlides.count == 1 else { continue }
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
            rawXmlMap[pptxItem.filename] = keyName
            xmlKeynoteUsage[keyName, default: 0] += 1
        }

        var rows: [MappingRow] = []

        for pptxItem in pptxItems {
            guard let pptxFP = pptxFingerprints[pptxItem.filename] else { continue }

            // 1. xml_exact candidate: only valid when unambiguous from both sides —
            //    exactly one Keynote image appears on these slides (checked in pre-pass),
            //    AND no other PPTX image also claims that same Keynote image.
            let xmlExactCandidate: String? = rawXmlMap[pptxItem.filename].flatMap { name in
                xmlKeynoteUsage[name] == 1 ? name : nil
            }

            // 2. Score all keynote candidates
            var scored: [ScoredCandidate] = []

            for keynoteItem in keynoteItems {
                guard let keyFP = keynoteFingerprints[keynoteItem.filename] else { continue }

                // Aspect-ratio pre-filter: skip candidates whose shape is grossly different.
                // Only applied when both images have known dimensions.
                if let pw = pptxFP.width, let ph = pptxFP.height, pw > 0, ph > 0,
                   let kw = keyFP.width, let kh = keyFP.height, kw > 0, kh > 0 {
                    let pAR = Double(pw) / Double(ph)
                    let kAR = Double(kw) / Double(kh)
                    if max(pAR, kAR) / min(pAR, kAR) > aspectRatioMaxRatio { continue }
                }

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

            // Sort by pHash + cmDist×W_cm (see colorMomentSortWeight comment for rationale).
            scored.sort { lhs, rhs in
                let lScore = Float(lhs.pHashDist) + lhs.cmDist * colorMomentSortWeight
                let rScore = Float(rhs.pHashDist) + rhs.cmDist * colorMomentSortWeight
                return lScore < rScore
            }

            // 3. Deduplicate visually identical candidates
            scored = deduplicate(scored)

            // 4. Take top 3 by distance
            let top3 = Array(scored.prefix(3))

            // 5. Build CandidateMatch array.
            // For xml_exact rows the identified match is pinned to position 0 regardless of
            // its hash distance — it may not rank in top3 at all (e.g. an SVG whose PPTX
            // rasterisation looks very different at pixel level). Remaining slots fill with
            // the top distance-ranked candidates that aren't the xml match.
            let scoredToCandidate: (ScoredCandidate) -> CandidateMatch = { sc in
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

            let candidates: [CandidateMatch]
            // Tracks the best ScoredCandidate for the xml match (drives quality classification)
            let primaryScoredCandidate: ScoredCandidate?

            if let xmlName = xmlExactCandidate,
               let xmlItem = keynoteByName[xmlName],
               let xmlFP   = keynoteFingerprints[xmlName] {

                // Re-use pre-computed scores if the xml item survived hash filtering;
                // otherwise compute distances directly from the fingerprint.
                let xmlScored: ScoredCandidate
                if let existing = scored.first(where: { $0.item.filename == xmlName }) {
                    xmlScored = existing
                } else {
                    let aD: Int
                    if let pa = pptxFP.aHash, let ka = xmlFP.aHash {
                        aD = ImageHasher.hammingDistance(pa, ka)
                    } else { aD = 64 }
                    let pH: Int
                    if let pp = pptxFP.pHash, let kp = xmlFP.pHash {
                        pH = ImageHasher.hammingDistance(pp, kp)
                    } else { pH = 64 }
                    let cm: Float
                    if let pcm = pptxFP.colorMoments, let kcm = xmlFP.colorMoments {
                        cm = ImageHasher.colorMomentDistance(pcm, kcm)
                    } else { cm = .infinity }
                    let ext  = URL(fileURLWithPath: xmlName).pathExtension.lowercased()
                    let kind: ReplacementKind = ext == "svg" ? .svg : ext == "pdf" ? .pdf : .raster
                    xmlScored = ScoredCandidate(
                        item: xmlItem, fp: xmlFP,
                        aHashDist: aD, pHashDist: pH, cmDist: cm,
                        extPriority: extPriority[ext] ?? 5, kind: kind
                    )
                }

                let rest = top3
                    .filter { $0.item.filename != xmlName }
                    .prefix(2)
                    .map { scoredToCandidate($0) }
                candidates = [scoredToCandidate(xmlScored)] + Array(rest)
                primaryScoredCandidate = xmlScored

            } else {
                candidates = top3.map { scoredToCandidate($0) }
                primaryScoredCandidate = nil
            }

            // 6. Determine quality using the xml-match score when available
            let isXmlExact = xmlExactCandidate != nil
            let quality = classifyQuality(
                top: primaryScoredCandidate ?? top3.first,
                isXmlExact: isXmlExact
            )

            // 7. Default choice: auto-select when pHash distance is below the threshold
            // (meaning ≤10/64 DCT bits differ — reliably "same image"). High-pHash
            // candidates require user review even if aHash looked close.
            let xmlDistOK = primaryScoredCandidate.map { $0.pHashDist < pHashAutoSelectThreshold } ?? false
            let selectedChoice: RowChoice
            if let xmlName = xmlExactCandidate, xmlDistOK {
                selectedChoice = .keynoteFile(filename: xmlName)
            } else if let first = top3.first, first.pHashDist < pHashAutoSelectThreshold {
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
        // Only award the xml-exact quality boost when pHash is within the auto-select
        // threshold — a high-pHash xml "match" is likely wrong and should be classified
        // by its actual pHash distance like any other candidate.
        if isXmlExact && top.pHashDist < pHashAutoSelectThreshold {
            return top.pHashDist == 0 ? .exact : .xmlExact
        }
        switch top.pHashDist {
        case 0:      return .exact
        case 1...7:  return .strong
        case 8...15: return .review
        case 16...25: return .poor
        default:     return .noMatch
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
