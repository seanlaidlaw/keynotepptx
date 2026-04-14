import Foundation
import Observation

@MainActor
@Observable
final class AppState {

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
}

// MARK: - Processing pipeline (nonisolated, runs off main actor)

enum ProcessingPipeline {

    static func run(
        pptxURL: URL,
        keynoteURL: URL,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> PipelineResult {

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let pptxDir = tmp.appendingPathComponent("kp_pptx_" + UUID().uuidString)
        let keynoteDir = tmp.appendingPathComponent("kp_key_" + UUID().uuidString)

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
        let (slideMedia, masterOnlyMedia) = try PPTXParser.parse(pptxDir: pptxDir)

        // 3. Parse Keynote IWA
        let (keynoteItems, keynoteSlideMedia) = try await KeynoteParser.parse(keynoteDir: keynoteDir)
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

        // 5. Fingerprint keynote assets (0.20 → 0.55)
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
                progress(0.20 + 0.35 * Double(keynoteDone) / Double(keynoteTotal),
                         "Keynote assets \(keynoteDone)/\(keynoteTotal)…")
            }
        }

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
            keynoteItems: keynoteItems,
            pptxFingerprints: pptxFingerprints,
            keynoteFingerprints: keynoteFingerprints,
            slideMedia: slideMedia,
            keynoteSlideMedia: keynoteSlideMedia
        )

        progress(1.0, "Done")
        return PipelineResult(rows: rows, pptxDir: pptxDir, keynoteDir: keynoteDir)
    }
}
