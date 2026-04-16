import Foundation

/// Applies confirmed image replacements to a PPTX directory, then rezips.
///
/// Three phases (mirrors Python `apply_selections_to_pptx` in app.py:1026):
///   1. Serial: resolve destination stubs, detect collisions
///   2. Parallel: materialise replacements (copy / convert)
///   3. Serial: update XML references, rezip
enum PPTXPatcher {

    private struct Replacement {
        let pptxFilename: String   // original name in ppt/media
        let sourcePath: URL        // keynote or custom source file
        let destFilename: String   // final name in ppt/media after patching
        let kind: ReplacementKind
    }

    private static func materialise(_ repl: Replacement, into mediaDir: URL, patchMode: PatchMode) async throws {
        let dest = mediaDir.appendingPathComponent(repl.destFilename)
        let srcExt = repl.sourcePath.pathExtension.lowercased()
        let isVector = srcExt == "svg" || srcExt == "pdf"
        if isVector {
            switch patchMode {
            case .vectorInPlace:
                try FileManager.default.copyItem(at: repl.sourcePath, to: dest)
            case .embedPNG:
                // For SVGs, prefer the companion PDF that Keynote stores alongside — it is the
                // authoritative render source (identical to what Keynote embeds in PPTX).
                let renderURL = srcExt == "svg" ? (companionPDF(for: repl.sourcePath) ?? repl.sourcePath) : repl.sourcePath
                let data = try ImageRenderer.renderToPNGData(url: renderURL, widthPx: 2560)
                try data.write(to: dest)
            case .embedWebP75:
                let renderURL = srcExt == "svg" ? (companionPDF(for: repl.sourcePath) ?? repl.sourcePath) : repl.sourcePath
                let data = try ImageRenderer.renderToWebPData(url: renderURL, widthPx: 2560)
                try data.write(to: dest)
            }
        } else {
            try FileManager.default.copyItem(at: repl.sourcePath, to: dest)
        }
    }

    /// Returns the companion PDF for an SVG (same directory, same stem after stripping the
    /// trailing asset ID). Keynote stores a PDF alongside every imported SVG and uses that
    /// PDF — not the SVG directly — when rendering to PPTX.
    private static let trailingIDPattern = try! NSRegularExpression(pattern: #"^(.*)-\d+$"#)

    private static func stripTrailingID(_ stem: String) -> String {
        let r = NSRange(stem.startIndex..., in: stem)
        guard let m = trailingIDPattern.firstMatch(in: stem, range: r),
              let range = Range(m.range(at: 1), in: stem) else { return stem }
        return String(stem[range])
    }

    private static func companionPDF(for svgURL: URL) -> URL? {
        let dir = svgURL.deletingLastPathComponent()
        let svgStem = stripTrailingID(svgURL.deletingPathExtension().lastPathComponent)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.first {
            $0.pathExtension.lowercased() == "pdf" &&
            stripTrailingID($0.deletingPathExtension().lastPathComponent) == svgStem
        }
    }

    static func apply(
        rows: [MappingRow],
        pptxExtractDir: URL,
        originalPPTXName: String,
        patchMode: PatchMode,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> URL {

        let mediaDir = pptxExtractDir.appendingPathComponent("ppt/media")

        // --- Phase 1: serial stub resolution ---
        progress(0.05, "Resolving file names…")

        var replacements: [Replacement] = []
        var usedStems = Set<String>()

        for row in rows {
            guard row.selectedChoice != .skip else { continue }

            let sourcePath: URL
            switch row.selectedChoice {
            case .keynoteFile(let name):
                // Find path in keynote items (we stored absolutePath in CandidateMatch)
                guard let candidate = row.topCandidates.first(where: { $0.keynoteFilename == name })
                        ?? row.topCandidates.first else { continue }
                sourcePath = candidate.keynotePath
            case .customFile(let url):
                sourcePath = url
            case .skip:
                continue
            }

            let pptxFile = row.pptxItem.filename
            let pptxStem = URL(fileURLWithPath: pptxFile).deletingPathExtension().lastPathComponent
            let srcExt = sourcePath.pathExtension.lowercased()

            // Determine output extension.
            // SVGs and PDFs are treated as vectors for vectorInPlace (copy as-is).
            // For embed modes, SVGs follow the mode (png/webp); PDFs always become PNG
            // because rasterising a PDF produces a PNG, never WebP.
            let destExt: String
            let isVector = srcExt == "svg" || srcExt == "pdf"
            if !isVector {
                destExt = URL(fileURLWithPath: pptxFile).pathExtension.lowercased()
            } else {
                switch patchMode {
                case .vectorInPlace: destExt = srcExt   // svg→svg, pdf→pdf
                case .embedPNG:      destExt = "png"
                case .embedWebP75:   destExt = "webp"
                }
            }

            // Resolve stem (add _repl suffix to avoid collisions with existing files)
            var stem = pptxStem + "_repl"
            var attempt = 0
            while usedStems.contains(stem) {
                attempt += 1
                stem = pptxStem + "_repl\(attempt)"
            }
            usedStems.insert(stem)

            let destFilename = stem + "." + destExt
            let kind: ReplacementKind = srcExt == "svg" ? .svg : srcExt == "pdf" ? .pdf : .raster
            replacements.append(Replacement(
                pptxFilename: pptxFile,
                sourcePath: sourcePath,
                destFilename: destFilename,
                kind: kind
            ))
        }

        // --- Phase 2: parallel materialisation ---
        progress(0.10, "Converting images…")

        let total = max(replacements.count, 1)

        // WebP encoding (libwebp) is CPU-intensive and synchronous: each task occupies its
        // thread for 0.5–2 s. Running processorCount–1 of them simultaneously saturates the
        // CPU and starves the main thread even though it nominally has "one core free".
        //
        // Two-pronged fix:
        //  • Fewer concurrent tasks for WebP (processorCount / 2) vs fast modes (processorCount – 1).
        //  • .utility task priority: the OS always prefers the main thread (userInteractive)
        //    over utility work, so it can preempt encoding tasks whenever UI events arrive.
        //
        // PNG via ImageIO completes in ~50 ms/image, so higher concurrency + default priority
        // is fine — the threads cycle quickly and the main thread is never starved.
        let maxConcurrency: Int
        let taskPriority: TaskPriority?
        switch patchMode {
        case .embedWebP75:
            maxConcurrency = max(1, ProcessInfo.processInfo.processorCount / 2)
            taskPriority   = .utility
        default:
            maxConcurrency = max(1, ProcessInfo.processInfo.processorCount - 1)
            taskPriority   = nil   // inherit from parent (userInitiated)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            // Seed initial batch up to the concurrency limit.
            while nextIndex < min(maxConcurrency, replacements.count) {
                let repl = replacements[nextIndex]; nextIndex += 1
                group.addTask(priority: taskPriority) {
                    try await materialise(repl, into: mediaDir, patchMode: patchMode)
                }
            }
            var completed = 0
            for try await _ in group {
                completed += 1
                progress(0.10 + 0.75 * Double(completed) / Double(total),
                         "Converting \(completed)/\(total)…")
                if nextIndex < replacements.count {
                    let repl = replacements[nextIndex]; nextIndex += 1
                    group.addTask(priority: taskPriority) {
                        try await materialise(repl, into: mediaDir, patchMode: patchMode)
                    }
                }
            }
        }

        // --- Phase 3: serial XML updates ---
        progress(0.85, "Updating slide XML…")

        for repl in replacements {
            // Register new content type if extension differs
            let destExt = URL(fileURLWithPath: repl.destFilename).pathExtension.lowercased()
            let srcExt = URL(fileURLWithPath: repl.pptxFilename).pathExtension.lowercased()
            if destExt != srcExt {
                let contentType = mimeType(for: destExt)
                try? XMLHelpers.registerContentType(
                    extension: destExt, contentType: contentType, in: pptxExtractDir
                )
            }

            // Replace references in all XML/rels files
            let oldRef = "../media/\(repl.pptxFilename)"
            let newRef = "../media/\(repl.destFilename)"
            try XMLHelpers.replaceTextRefs(in: pptxExtractDir, old: oldRef, new: newRef)

            // Also handle root-relative references
            let oldRef2 = "ppt/media/\(repl.pptxFilename)"
            let newRef2 = "ppt/media/\(repl.destFilename)"
            try XMLHelpers.replaceTextRefs(in: pptxExtractDir, old: oldRef2, new: newRef2)
        }

        // --- Rezip ---
        // Output lives alongside pptx/ and keynote/ in the session cache directory
        // so the user can inspect all files from the most recent run.
        progress(0.92, "Packaging output…")
        let outputDir = pptxExtractDir.deletingLastPathComponent().appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent("\(originalPPTXName)_patched.pptx")
        try await ZipTools.rezip(directory: pptxExtractDir, to: outputURL)

        progress(1.0, "Done")
        return outputURL
    }

    private static func mimeType(for ext: String) -> String {
        switch ext {
        case "svg":  return "image/svg+xml"
        case "pdf":  return "application/pdf"
        case "png":  return "image/png"
        case "webp": return "image/webp"
        case "jpg", "jpeg": return "image/jpeg"
        default:     return "application/octet-stream"
        }
    }
}
