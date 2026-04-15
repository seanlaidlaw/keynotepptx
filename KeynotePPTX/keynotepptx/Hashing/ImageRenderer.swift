import Foundation
import AppKit
import CoreGraphics
import WebP

/// Renders any source image file (SVG, PDF, raster) to a CGImage.
/// Returns CGImage (Sendable) so it can safely cross actor boundaries.
enum ImageRenderer {

    /// Render a file to CGImage at max dimension `maxDim` for hashing.
    /// Composites onto a white background (matches Python convention).
    static func renderForHashing(url: URL, maxDim: Int = 256) -> CGImage? {
        let ext = url.pathExtension.lowercased()
        return switch ext {
        case "svg": renderSVG(url: url, maxDim: maxDim)
        case "pdf": renderPDF(url: url, maxDim: maxDim)
        default: renderRaster(url: url, maxDim: maxDim)
        }
    }

    /// Render a file to a small thumbnail CGImage (max 260×180).
    static func renderThumbnail(url: URL) -> CGImage? {
        renderForHashing(url: url, maxDim: 260)
    }

    // MARK: - Background colour selection

    /// Returns the background colour to use when flattening a potentially-transparent
    /// image for hashing.
    ///
    /// Uses **black** when every opaque pixel (alpha ≥ 10/255) is white (≥ 240/255
    /// un-premultiplied in all channels) — so that white-on-transparent content such
    /// as white labels or icons is not silently erased against a matching background.
    /// Falls back to **white** in all other cases (including a fully-transparent image).
    ///
    /// Exposed as `internal` so the test target can reuse it via `@testable import`.
    /// Composites `src` onto an opaque background chosen by `backgroundForCompositing`.
    /// Use this in tests and anywhere the production hashing path's flattening must be
    /// replicated exactly, to guarantee hash comparisons are apples-to-apples.
    static func flattenForHashing(_ src: CGImage) -> CGImage? {
        compositeOnBackground(
            cgImage: src, background: backgroundForCompositing(src),
            width: src.width, height: src.height
        )
    }

    static func backgroundForCompositing(_ src: CGImage) -> CGColor {
        let sw = 64, sh = 64
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: sw, height: sh,
            bitsPerComponent: 8, bytesPerRow: sw * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let raw = ctx.data else { return CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
        let ptr = raw.assumingMemoryBound(to: UInt8.self)
        var hasOpaque = false
        for i in 0 ..< sw * sh {
            let a = ptr[i * 4 + 3]
            guard a > 10 else { continue }
            hasOpaque = true
            let aF = Float(a)
            // Un-premultiply each channel and check against the white threshold.
            if Float(ptr[i * 4    ]) / aF * 255 < 240 { return CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
            if Float(ptr[i * 4 + 1]) / aF * 255 < 240 { return CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
            if Float(ptr[i * 4 + 2]) / aF * 255 < 240 { return CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
        }
        // All opaque pixels are white → use black so the content remains visible.
        return hasOpaque
            ? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

    // MARK: - Raster

    private static func renderRaster(url: URL, maxDim: Int) -> CGImage? {
        // CGImageSource is fully thread-safe and never touches AppKit — critical because
        // this runs inside the parallel fingerprinting task group.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let rawImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let sw = rawImage.width, sh = rawImage.height
        guard sw > 0, sh > 0 else { return nil }
        let scale = min(Double(maxDim) / Double(max(sw, sh)), 1.0)
        let targetW = max(1, Int(Double(sw) * scale))
        let targetH = max(1, Int(Double(sh) * scale))
        return compositeOnBackground(cgImage: rawImage,
                                     background: backgroundForCompositing(rawImage),
                                     width: targetW, height: targetH)
    }

    // MARK: - SVG → in-memory PDF → CGImage

    /// Renders an SVG into an in-memory CGPDFDocument by drawing it through AppKit's
    /// SVG renderer (_NSSVGImageRep) into a PDF CGContext.
    ///
    /// This replicates Keynote's internal SVG→PDF companion pipeline: Keynote stores a
    /// PDF alongside each imported SVG (consecutive asset IDs) and renders *that* PDF
    /// when exporting to PPTX — not the SVG directly. By going through the same
    /// SVG→PDF→raster path we produce hashes that match the PPTX PNGs exactly.
    ///
    /// PDF contexts are naturally bottom-up (non-flipped), which is what `_NSSVGImageRep`
    /// expects when the graphics context is non-flipped — no coordinate mangling needed.
    /// Injects `overflow="hidden"` into the root `<svg>` element so that
    /// `_NSSVGImageRep` clips any path coordinates that fall outside the declared
    /// viewBox.  This matches Keynote's clipping behaviour when it creates its
    /// companion PDF alongside an imported SVG.
    private static func svgAddingOverflowHidden(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        guard let svgStart = text.range(of: "<svg", options: .caseInsensitive) else { return data }
        // Search for the closing `>` of the opening <svg> tag by slicing the string
        // from svgStart.upperBound onwards — avoids NSString/StringProtocol overload ambiguity.
        guard let tagEnd = text[svgStart.upperBound...].range(of: ">") else { return data }
        let tagContent = text[svgStart.lowerBound..<tagEnd.upperBound]
        guard !tagContent.contains("overflow") else { return data }
        text.insert(contentsOf: " overflow=\"hidden\"", at: tagEnd.lowerBound)
        return text.data(using: .utf8) ?? data
    }

    private static func svgToPDFDocument(url: URL) -> CGPDFDocument? {
        // Pre-process the SVG to clip overflow content, then load via NSImage so
        // _NSSVGImageRep respects the viewBox boundary (matching Keynote's pipeline).
        guard let rawData = try? Data(contentsOf: url) else { return nil }
        let svgData = svgAddingOverflowHidden(rawData)
        guard let img = NSImage(data: svgData) else { return nil }
        let size = img.size
        guard size.width > 0, size.height > 0 else { return nil }

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.clip(to: CGRect(origin: .zero, size: size))
        img.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()

        guard let provider = CGDataProvider(data: pdfData as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    private static func renderSVG(url: URL, maxDim: Int) -> CGImage? {
        guard let pdfDoc = svgToPDFDocument(url: url),
              let page = pdfDoc.page(at: 1) else { return nil }
        let pageRect = cgPDFVisibleRect(page)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let scale = CGFloat(maxDim) / max(pageRect.width, pageRect.height)
        let width = max(1, Int(pageRect.width * scale))
        let height = max(1, Int(pageRect.height * scale))
        let cs = CGColorSpaceCreateDeviceRGB()
        return renderPDFPageOpaque(page: page, pageRect: pageRect, scale: scale,
                                   width: width, height: height, cs: cs)
    }

    // MARK: - PDF shared rendering

    /// Two-pass opaque PDF page render used by both the hashing path and `PDFConverter`.
    ///
    /// Pass 1: premultiplied-alpha so semi-transparent PDF content composites correctly.
    /// Pass 2: flatten onto opaque background so the output has no alpha channel.
    static func renderPDFPageOpaque(
        page: CGPDFPage, pageRect: CGRect, scale: CGFloat,
        width: Int, height: Int, cs: CGColorSpace
    ) -> CGImage? {
        let pixelRect = CGRect(x: 0, y: 0, width: width, height: height)
        let bg = pdfBackgroundColor(page: page, pageRect: pageRect, scale: scale, cs: cs)

        guard let alphaCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        alphaCtx.interpolationQuality = .high
        alphaCtx.setFillColor(bg)
        alphaCtx.fill(pixelRect)
        alphaCtx.saveGState()
        alphaCtx.scaleBy(x: scale, y: scale)
        alphaCtx.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
        alphaCtx.drawPDFPage(page)
        alphaCtx.restoreGState()
        guard let alphaImage = alphaCtx.makeImage() else { return nil }

        guard let flatCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        flatCtx.setFillColor(bg)
        flatCtx.fill(pixelRect)
        flatCtx.draw(alphaImage, in: pixelRect)
        return flatCtx.makeImage()
    }

    /// Returns the effective visible rect for a PDF page (cropBox when meaningful, else mediaBox).
    /// Internal so `PDFConverter` can share the same logic without duplicating it.
    static func cgPDFVisibleRect(_ page: CGPDFPage) -> CGRect {
        let media = page.getBoxRect(.mediaBox)
        let crop  = page.getBoxRect(.cropBox)
        if crop.width > 1 && crop.height > 1 && crop != media { return crop }
        return media
    }

    private static func renderPDF(url: URL, maxDim: Int) -> CGImage? {
        guard let pdfDoc = CGPDFDocument(url as CFURL),
              let page = pdfDoc.page(at: 1) else { return nil }
        let pageRect = cgPDFVisibleRect(page)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let scale = CGFloat(maxDim) / max(pageRect.width, pageRect.height)
        let cs = CGColorSpaceCreateDeviceRGB()
        return renderPDFPageOpaque(
            page: page, pageRect: pageRect, scale: scale,
            width: max(1, Int(pageRect.width * scale)),
            height: max(1, Int(pageRect.height * scale)),
            cs: cs
        )
    }

    /// Renders the PDF page at a small sample size with no background fill to detect
    /// whether the content is white-only (requiring a black background to remain visible).
    private static func pdfBackgroundColor(
        page: CGPDFPage, pageRect: CGRect, scale: CGFloat, cs: CGColorSpace
    ) -> CGColor {
        let sw = max(1, Int(pageRect.width  * min(scale, 32.0 / max(pageRect.width,  1))))
        let sh = max(1, Int(pageRect.height * min(scale, 32.0 / max(pageRect.height, 1))))
        guard let sCtx = CGContext(
            data: nil, width: sw, height: sh,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
        // No fill — context starts as transparent black (zero-initialised).
        let sScale = CGFloat(sw) / pageRect.width
        sCtx.scaleBy(x: sScale, y: sScale)
        sCtx.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
        sCtx.drawPDFPage(page)
        guard let sample = sCtx.makeImage() else { return CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
        return backgroundForCompositing(sample)
    }

    // MARK: - Background compositing

    /// Composites a raw `CGImage` (already rendered, possibly with alpha) onto `background`.
    private static func compositeOnBackground(cgImage: CGImage, background: CGColor, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - Materialise helpers (used by PPTXPatcher)

    /// Render a source file to PNG data at the given pixel width, preserving transparency.
    ///
    /// Uses ImageIO (CGImageDestination) rather than the pngquant NSImage wrapper.
    /// pngquant's macOS pixel-extraction path calls NSGraphicsContext and NSImage drawing
    /// methods that internally dispatch to the main thread synchronously — saturating the
    /// main thread and causing a spinning beach ball when many tasks run in parallel.
    /// ImageIO is fully thread-safe and produces well-compressed PNGs without touching AppKit.
    static func renderToPNGData(url: URL, widthPx: Int = 2560) throws -> Data {
        let ext = url.pathExtension.lowercased()
        guard let cgImage = renderWithTransparency(url: url, width: widthPx, ext: ext) else {
            throw RendererError.failed(url.lastPathComponent)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil
        ) else { throw RendererError.failed(url.lastPathComponent) }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw RendererError.failed(url.lastPathComponent)
        }
        return data as Data
    }

    /// Render source to WebP data (quality 75) at widthPx using Swift-WebP.
    static func renderToWebPData(url: URL, widthPx: Int = 2560) throws -> Data {
        let ext = url.pathExtension.lowercased()

        // Vector sources (PDF / SVG) are rendered directly from the CGPDFPage into a
        // caller-owned RGBX buffer using CGContext(data: buffer).
        //
        // The alternative — CGContext(data:nil) → makeImage() → ctx.draw(cgImage) — is
        // what caused the spinning beach ball: on Apple Silicon, CGContext(data:nil)
        // allocates an IOSurface (Metal-backed) for the bitmap. Drawing that
        // IOSurface-backed CGImage into a CPU-owned buffer triggers a GPU→CPU readback
        // that CoreGraphics dispatches to the main queue. With several concurrent WebP
        // tasks each doing this, the main thread is flooded and freezes.
        //
        // CGContext(data:callerBuffer) forces CPU-only software rendering — identical
        // visual output, fully thread-safe, no IOSurface, no main-queue dispatch.
        if ext == "pdf" || ext == "svg" {
            let pdfDoc: CGPDFDocument?
            if ext == "svg" {
                pdfDoc = svgToPDFDocument(url: url)
            } else {
                pdfDoc = CGPDFDocument(url as CFURL)
            }
            guard let pdfDoc, let page = pdfDoc.page(at: 1) else {
                throw RendererError.failed(url.lastPathComponent)
            }
            let pageRect = cgPDFVisibleRect(page)
            guard pageRect.width > 0, pageRect.height > 0 else {
                throw RendererError.failed(url.lastPathComponent)
            }
            let scale = CGFloat(widthPx) / pageRect.width
            let w = widthPx, h = max(1, Int(pageRect.height * scale)), stride = w * 4
            var pixels = [UInt8](repeating: 255, count: h * stride) // white background
            try pixels.withUnsafeMutableBytes { buf in
                let cs = CGColorSpaceCreateDeviceRGB()
                guard let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: stride, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { throw RendererError.failed(url.lastPathComponent) }
                ctx.interpolationQuality = .high
                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
                ctx.drawPDFPage(page)
                ctx.restoreGState()
            }
            return try pixels.withUnsafeBytes { buf in
                try WebPEncoder().encode(
                    buf.bindMemory(to: UInt8.self),
                    format: .rgbx,
                    config: .preset(.picture, quality: 75),
                    originWidth: w, originHeight: h, stride: stride
                )
            }
        }

        // Raster: use CGImageSource directly so rawImage is CPU-backed from the start.
        // Calling renderWithTransparency would pass rawImage through CGContext(data:nil),
        // producing an IOSurface-backed intermediate — drawing that into a CPU buffer
        // triggers the same GPU→CPU readback / main-queue dispatch we're trying to avoid.
        // CGImageSource → CGContext(data:callerBuffer) stays entirely on CPU.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let rawImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RendererError.failed(url.lastPathComponent)
        }
        let srcW = rawImage.width, srcH = rawImage.height
        guard srcW > 0, srcH > 0 else { throw RendererError.failed(url.lastPathComponent) }
        let scale = Double(widthPx) / Double(srcW)
        let w = widthPx, h = max(1, Int(Double(srcH) * scale)), stride = w * 4
        var pixels = [UInt8](repeating: 255, count: h * stride) // white background
        try pixels.withUnsafeMutableBytes { buf in
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: stride, space: cs,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw RendererError.failed(url.lastPathComponent) }
            ctx.interpolationQuality = .high
            ctx.draw(rawImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return try pixels.withUnsafeBytes { buf in
            try WebPEncoder().encode(
                buf.bindMemory(to: UInt8.self),
                format: .rgbx,
                config: .preset(.picture, quality: 75),
                originWidth: w, originHeight: h, stride: stride
            )
        }
    }

    private static func renderWithTransparency(url: URL, width: Int, ext: String) -> CGImage? {
        switch ext {
        case "svg":
            // Route through the same SVG→PDF→raster pipeline used for hashing so that
            // the exported PNG is rendered identically to Keynote's PPTX export.
            guard let pdfDoc = svgToPDFDocument(url: url),
                  let page = pdfDoc.page(at: 1) else { return nil }
            let pageRect = cgPDFVisibleRect(page)
            guard pageRect.width > 0, pageRect.height > 0 else { return nil }
            let scale = CGFloat(width) / pageRect.width
            let h = max(1, Int(pageRect.height * scale))
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: width, height: h,
                bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            return ctx.makeImage()

        case "pdf":
            guard let pdfDoc = CGPDFDocument(url as CFURL),
                  let page = pdfDoc.page(at: 1) else { return nil }
            let pageRect = cgPDFVisibleRect(page)
            guard pageRect.width > 0, pageRect.height > 0 else { return nil }
            let scale = CGFloat(width) / pageRect.width
            let h = max(1, Int(pageRect.height * scale))
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: width, height: h,
                bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            return ctx.makeImage()

        default:
            // CGImageSource is thread-safe and AppKit-free — safe for parallel export tasks.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let rawImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let srcW = rawImage.width, srcH = rawImage.height
            guard srcW > 0 else { return nil }
            let scale = Double(width) / Double(srcW)
            let h = max(1, Int(Double(srcH) * scale))
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: width, height: h,
                bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(rawImage, in: CGRect(x: 0, y: 0, width: width, height: h))
            return ctx.makeImage()
        }
    }

    enum RendererError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { return "Render failed: \(m)" }; return nil }
    }
}