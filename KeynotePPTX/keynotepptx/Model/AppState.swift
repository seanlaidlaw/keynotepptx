import Foundation
import Observation

@MainActor
@Observable
final class AppState {

    init() {}

    // MARK: - Navigation state
    var phase: AppPhase = .welcome

    // MARK: - Input
    var pptxURL: URL?
    var keynoteURL: URL?

    // MARK: - Processing progress
    var progress: Double = 0
    var progressDetail: String = ""

    // MARK: - Review state
    var mappingRows: [MappingRow] = []
    /// Non-nil when PPTX and Keynote have different slide counts; user is warned but can continue.
    var slideCountMismatch: (pptxCount: Int, keynoteCount: Int)? = nil

    // MARK: - Patch options
    var patchMode: PatchMode = .vectorInPlace

    // MARK: - Extracted directories (kept alive for patching)
    var pptxExtractDir: URL?
    var keynoteExtractDir: URL?

    // MARK: - Computed helpers

    var skippedCount: Int { mappingRows.filter { $0.selectedChoice == .skip }.count }
    var confirmedCount: Int { mappingRows.filter { $0.selectedChoice != .skip }.count }

    var pendingSummary: (total: Int, skipped: Int, vectors: Int, rasters: Int) {
        var vectors = 0
        var rasters = 0
        for row in mappingRows {
            switch row.selectedChoice {
            case .skip: break
            case .keynoteFile(let name):
                let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                if ext == "svg" || ext == "pdf" { vectors += 1 } else { rasters += 1 }
            case .customFile(let url):
                let ext = url.pathExtension.lowercased()
                if ext == "svg" || ext == "pdf" { vectors += 1 } else { rasters += 1 }
            }
        }
        return (mappingRows.count, skippedCount, vectors, rasters)
    }

    // MARK: - Processing pipeline

    func startProcessing() async {
        guard let pptxURL, let keynoteURL else { return }
        phase = .processing
        progress = 0
        progressDetail = "Extracting files…"

        let progressCallback: @Sendable (Double, String) -> Void = { p, detail in
            Task { @MainActor [weak self] in
                self?.progress = p
                self?.progressDetail = detail
            }
        }

        do {
            let result = try await ProcessingPipeline.run(
                pptxURL: pptxURL,
                keynoteURL: keynoteURL,
                progress: progressCallback
            )

            self.mappingRows = result.rows
            self.pptxExtractDir = result.pptxDir
            self.keynoteExtractDir = result.keynoteDir
            if result.pptxSlideCount != result.keynoteSlideCount {
                self.slideCountMismatch = (result.pptxSlideCount, result.keynoteSlideCount)
            }
            self.phase = .review

        } catch {
            self.phase = .error(error.localizedDescription)
        }
    }

    func applyPatching() async {
        guard let pptxURL, let pptxExtractDir else { return }
        phase = .patching
        progress = 0
        progressDetail = "Applying replacements…"

        let rows = self.mappingRows
        let mode = self.patchMode
        // Save debug mapping now — selectedChoice reflects the user's confirmed ground truth,
        // not the algorithm's initial auto-selection, which is what we want for training data.
        ProcessingPipeline.saveDebugMapping(rows: rows, to: pptxExtractDir.deletingLastPathComponent())

        let progressCallback: @Sendable (Double, String) -> Void = { p, detail in
            Task { @MainActor [weak self] in
                self?.progress = p
                self?.progressDetail = detail
            }
        }

        do {
            let outputURL = try await PPTXPatcher.apply(
                rows: rows,
                pptxExtractDir: pptxExtractDir,
                originalPPTXName: pptxURL.deletingPathExtension().lastPathComponent,
                patchMode: mode,
                progress: progressCallback
            )

            self.phase = .done(outputURL: outputURL)
        } catch {
            self.phase = .error(error.localizedDescription)
        }
    }
}

// MARK: - Pipeline result

struct PipelineResult: Sendable {
    let rows: [MappingRow]
    let pptxDir: URL
    let keynoteDir: URL
    let pptxSlideCount: Int
    let keynoteSlideCount: Int
}

// MARK: - Processing pipeline (nonisolated, runs off main actor)

enum ProcessingPipeline {

    static func run(
        pptxURL: URL,
        keynoteURL: URL,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> PipelineResult {

        let fm = FileManager.default

        // Mirror the Python app: persist extracted and output files in
        // ~/Library/Caches/KeynotePPTX/<uuid>/ so they are inspectable after each run.
        // UUIDs avoid collisions when the same files are processed multiple times.
        // Keep only the 10 most-recent sessions; remove older ones.
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let appCacheDir = caches.appendingPathComponent("KeynotePPTX")
        try? fm.createDirectory(at: appCacheDir, withIntermediateDirectories: true)

        let sessionDir = appCacheDir.appendingPathComponent(UUID().uuidString)
        let pptxDir = sessionDir.appendingPathComponent("pptx")
        let keynoteDir = sessionDir.appendingPathComponent("keynote")

        // Prune old sessions — keep the 10 most recent by creation date
        if let existing = try? fm.contentsOfDirectory(
            at: appCacheDir, includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) {
            let sorted = existing.compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return nil }
                return (url, d)
            }.sorted { $0.1 > $1.1 }

            for (url, _) in sorted.dropFirst(10) { try? fm.removeItem(at: url) }
        }

        // 1. Unzip both in parallel
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try fm.createDirectory(at: pptxDir, withIntermediateDirectories: true)
                try await ZipTools.unzip(archive: pptxURL, to: pptxDir)
            }
            group.addTask {
                try fm.createDirectory(at: keynoteDir, withIntermediateDirectories: true)
                try await ZipTools.unzip(archive: keynoteURL, to: keynoteDir)
            }
            try await group.waitForAll()
        }
        progress(0.08, "Parsing slide structure…")

        // 2. Parse PPTX XML
        let (slideMedia, masterOnlyMedia, pptxSlideCount) = try PPTXParser.parse(pptxDir: pptxDir)

        // 3. Parse Keynote IWA
        let (keynoteItems, keynoteSlideMedia, keynoteSlideCount) = try await KeynoteParser.parse(keynoteDir: keynoteDir)
        progress(0.15, "Building file lists…")

        // 4. Build PPTX media items (exclude master-only)
        let pptxMediaDir = pptxDir.appendingPathComponent("ppt/media")
        var pptxItems: [PPTXMediaItem] = []
        if let contents = try? fm.contentsOfDirectory(at: pptxMediaDir, includingPropertiesForKeys: nil) {
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                guard !masterOnlyMedia.contains(name) else { continue }
                let slides = slideMedia[name] ?? []
                pptxItems.append(PPTXMediaItem(
                    filename: name, absolutePath: url,
                    slideNumbers: slides, isMasterOnly: false
                ))
            }
        }

        // 5. Fingerprint keynote assets (0.20 → 0.52)
        progress(0.20, "Fingerprinting Keynote assets…")
        var keynoteFingerprints: [String: ImageFingerprint] = [:]
        let keynoteTotal = max(keynoteItems.count, 1)
        var keynoteDone = 0
        await withTaskGroup(of: (String, ImageFingerprint).self) { group in
            for item in keynoteItems {
                group.addTask {
                    (item.filename, ImageFingerprinter.fingerprint(url: item.absolutePath))
                }
            }
            for await (name, fp) in group {
                keynoteFingerprints[name] = fp
                keynoteDone += 1
                progress(0.20 + 0.32 * Double(keynoteDone) / Double(keynoteTotal),
                         "Keynote assets \(keynoteDone)/\(keynoteTotal)…")
            }
        }

        // 5.5 Resolve SVG/PDF companion pairs (0.52 → 0.55)
        // Each SVG imported into Keynote has a companion PDF alongside it (consecutive
        // asset IDs, delta ≤ 2).  The companion PDF is what Keynote rasterises when
        // exporting to PPTX, so its fingerprint is pixel-accurate vs the PPTX PNGs —
        // the SVG's fingerprint can diverge due to missing fonts or overflow differences.
        //
        // For each confirmed pair we:
        //   • Replace the SVG's fingerprint with the PDF's hash/dimension metrics
        //     (keeping the SVG's filename and file size so the SVG remains the candidate)
        //   • Remove the companion PDF from keynoteItems and keynoteFingerprints entirely
        //     so it never appears as a separate candidate in the review UI.
        progress(0.52, "Resolving SVG/PDF companion pairs…")
        let resolvedKeynoteItems = resolveCompanionPairs(
            keynoteItems: keynoteItems,
            fingerprints: &keynoteFingerprints
        )

        // 6. Fingerprint PPTX images (0.55 → 0.80)
        progress(0.55, "Fingerprinting PPTX images…")
        var pptxFingerprints: [String: ImageFingerprint] = [:]
        let pptxTotal = max(pptxItems.count, 1)
        var pptxDone = 0
        await withTaskGroup(of: (String, ImageFingerprint).self) { group in
            for item in pptxItems {
                group.addTask {
                    (item.filename, ImageFingerprinter.fingerprint(url: item.absolutePath))
                }
            }
            for await (name, fp) in group {
                pptxFingerprints[name] = fp
                pptxDone += 1
                progress(0.55 + 0.25 * Double(pptxDone) / Double(pptxTotal),
                         "PPTX images \(pptxDone)/\(pptxTotal)…")
            }
        }

        // 7. Match
        progress(0.80, "Matching images…")
        let rows = MatchEngine.buildMappingRows(
            pptxItems: pptxItems,
            keynoteItems: resolvedKeynoteItems,
            pptxFingerprints: pptxFingerprints,
            keynoteFingerprints: keynoteFingerprints,
            slideMedia: slideMedia,
            keynoteSlideMedia: keynoteSlideMedia
        )

        progress(1.0, "Done")
        return PipelineResult(
            rows: rows,
            pptxDir: pptxDir,
            keynoteDir: keynoteDir,
            pptxSlideCount: pptxSlideCount,
            keynoteSlideCount: keynoteSlideCount
        )
    }

    // MARK: - SVG/PDF companion pair resolution

    /// For every SVG in `keynoteItems` that has a confirmed companion PDF (same filename
    /// stem, asset ID delta ≤ 2, validated by `SVGPDFPairValidator`):
    ///
    /// - Replaces the SVG's entry in `fingerprints` with a merged fingerprint that keeps
    ///   the SVG's filename and file size but adopts the PDF's hash metrics (aHash, pHash,
    ///   colorMoments, width, height).  The PDF renders with baked-in fonts so its hashes
    ///   match the PPTX PNGs far more accurately than the SVG renderer can.
    ///
    /// - Removes the companion PDF from `fingerprints` and returns a filtered item list
    ///   that excludes it.  The PDF is invisible to MatchEngine — it has done its job.
    ///
    /// Returns the filtered `[KeynoteMediaItem]` with absorbed PDFs removed.
    static func resolveCompanionPairs(
        keynoteItems: [KeynoteMediaItem],
        fingerprints: inout [String: ImageFingerprint]
    ) -> [KeynoteMediaItem] {

        // Index all PDF items by (stem-without-trailing-ID → [(numericID, item)])
        var pdfByStem: [String: [(id: Int, item: KeynoteMediaItem)]] = [:]
        for item in keynoteItems {
            let ext = URL(fileURLWithPath: item.filename).pathExtension.lowercased()
            guard ext == "pdf" else { continue }
            let stem = URL(fileURLWithPath: item.filename).deletingPathExtension().lastPathComponent
            guard let id = trailingNumericID(of: stem) else { continue }
            let baseStem = dropTrailingID(stem)
            pdfByStem[baseStem, default: []].append((id, item))
        }

        var absorbedPDFs: Set<String> = []

        for item in keynoteItems {
            let ext = URL(fileURLWithPath: item.filename).pathExtension.lowercased()
            guard ext == "svg" else { continue }

            let svgStem = URL(fileURLWithPath: item.filename).deletingPathExtension().lastPathComponent
            guard let svgID = trailingNumericID(of: svgStem) else { continue }
            let baseStem = dropTrailingID(svgStem)

            guard let pdfCandidates = pdfByStem[baseStem], !pdfCandidates.isEmpty else { continue }

            // Among PDFs with the same stem, prefer the closest ID that is below the SVG's.
            // (Keynote creates the PDF first, then the SVG — so PDF ID < SVG ID.)
            let sorted = pdfCandidates
                .filter { $0.id < svgID && svgID - $0.id <= 3 }
                .sorted { abs($0.id - svgID) < abs($1.id - svgID) }

            for (_, pdfItem) in sorted {
                let result = SVGPDFPairValidator.validate(
                    svg: item.absolutePath,
                    pdf: pdfItem.absolutePath
                )
                guard result.isCompanionPair else { continue }

                // Borrow the PDF's hash metrics for this SVG.
                // The SVG is the replacement file (better PowerPoint support);
                // the PDF's hashes are pixel-accurate against the PPTX PNGs.
                if let svgFP = fingerprints[item.filename],
                   let pdfFP = fingerprints[pdfItem.filename] {
                    fingerprints[item.filename] = ImageFingerprint(
                        filename:      svgFP.filename,       // keep SVG name
                        fileSizeBytes: svgFP.fileSizeBytes,  // keep SVG file size
                        aHash:         pdfFP.aHash,
                        pHash:         pdfFP.pHash,
                        colorMoments:  pdfFP.colorMoments,
                        width:         pdfFP.width,
                        height:        pdfFP.height,
                        thumbnailData: pdfFP.thumbnailData,  // PDF thumbnail renders correctly
                        error:         svgFP.error
                    )
                }
                absorbedPDFs.insert(pdfItem.filename)
                break  // one companion PDF per SVG
            }
        }

        // Remove absorbed PDFs from fingerprints and return filtered item list
        for name in absorbedPDFs { fingerprints.removeValue(forKey: name) }
        return keynoteItems.filter { !absorbedPDFs.contains($0.filename) }
    }

    /// Extracts the trailing numeric ID from a filename stem, e.g. "Foo-1207" → 1207.
    private static func trailingNumericID(of stem: String) -> Int? {
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let idStr = stem[stem.index(after: dash)...]
        return Int(idStr)
    }

    /// Removes the trailing "-NNNN" from a stem, e.g. "Foo-1207" → "Foo".
    private static func dropTrailingID(_ stem: String) -> String {
        guard let dash = stem.lastIndex(of: "-"),
              stem[stem.index(after: dash)...].allSatisfy(\.isNumber) else { return stem }
        return String(stem[..<dash])
    }

    // MARK: - Debug output

    /// Saves a JSON file to the session directory listing every PPTX image, its matched
    /// Keynote file, and all hash distances / composite scores — useful for debugging match quality.
    static func saveDebugMapping(rows: [MappingRow], to sessionDir: URL) {
        var entries: [[String: Any]] = []
        for row in rows {
            // Determine the user-confirmed keynote filename (nil = skipped)
            let confirmedFilename: String?
            switch row.selectedChoice {
            case .skip:                    confirmedFilename = nil
            case .keynoteFile(let name):   confirmedFilename = name
            case .customFile(let url):     confirmedFilename = url.lastPathComponent
            }

            var candidateEntries: [[String: Any]] = []
            for c in row.topCandidates {
                // Combined score mirrors MatchEngine sort: aHash + cmDist * 5.0
                let combinedScore = Float(c.aHashDistance) + c.colorMomentDistance * 5.0
                candidateEntries.append([
                    "keynote_filename": c.keynoteFilename,
                    "ahash_distance": c.aHashDistance,
                    "phash_distance": c.pHashDistance,
                    "cm_distance": Double(c.colorMomentDistance),
                    "combined_score": Double(combinedScore),
                    // True on exactly one candidate — the user's confirmed ground-truth label
                    "user_confirmed": c.keynoteFilename == confirmedFilename
                ])
            }

            entries.append([
                "pptx_filename": row.pptxItem.filename,
                "pptx_slides": row.pptxItem.slideNumbers,
                "quality": row.quality.rawValue,
                "is_xml_exact": row.isXmlExact,
                // Top-level convenience field: the confirmed keynote file, or "skip"
                "confirmed_match": confirmedFilename ?? "skip",
                "candidates": candidateEntries
            ])
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: entries,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: sessionDir.appendingPathComponent("matching_debug.json"))
    }
}
