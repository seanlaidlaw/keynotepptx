import Foundation
import AppKit
import PDFKit
import CoreGraphics

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

    // MARK: - Raster

    private static func renderRaster(url: URL, maxDim: Int) -> CGImage? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        let srcSize = img.size
        guard srcSize.width > 0, srcSize.height > 0 else { return nil }
        let scale = min(CGFloat(maxDim) / max(srcSize.width, srcSize.height), 1.0)
        let targetW = max(1, Int(srcSize.width * scale))
        let targetH = max(1, Int(srcSize.height * scale))
        return compositeOnWhite(nsImage: img, width: targetW, height: targetH)
    }

    // MARK: - SVG (native macOS 12+ _NSSVGImageRep)

    private static func renderSVG(url: URL, maxDim: Int) -> CGImage? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        let srcSize = img.size
        guard srcSize.width > 0, srcSize.height > 0 else { return nil }
        let scale = CGFloat(maxDim) / max(srcSize.width, srcSize.height)
        let targetW = max(1, Int(srcSize.width * scale))
        let targetH = max(1, Int(srcSize.height * scale))
        return compositeOnWhite(nsImage: img, width: targetW, height: targetH)
    }

    // MARK: - PDF

    private static func renderPDF(url: URL, maxDim: Int) -> CGImage? {
        guard let pdfDoc = PDFDocument(url: url),
              let page = pdfDoc.page(at: 0) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let scale = CGFloat(maxDim) / max(pageRect.width, pageRect.height)
        let targetW = max(1, Int(pageRect.width * scale))
        let targetH = max(1, Int(pageRect.height * scale))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: targetW, height: targetH,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // White background
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))

        // Draw PDF page scaled to target size
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        page.draw(with: .mediaBox, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        return ctx.makeImage()
    }

    // MARK: - White-background compositing

    private static func compositeOnWhite(nsImage: NSImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        nsImage.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }

    // MARK: - Materialise helpers (used by PPTXPatcher)

    /// Render a source file to PNG data at the given pixel width, preserving transparency.
    static func renderToPNGData(url: URL, widthPx: Int = 2560) throws -> Data {
        let ext = url.pathExtension.lowercased()
        guard let cgImage = renderWithTransparency(url: url, width: widthPx, ext: ext) else {
            throw RendererError.failed(url.lastPathComponent)
        }
        guard let dest = CGImageDestinationCreateWithData(
            NSMutableData() as CFMutableData, "public.png" as CFString, 1, nil
        ) else { throw RendererError.failed("CGImageDestination") }
        let mutableData = NSMutableData()
        let dest2 = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest2, cgImage, nil)
        guard CGImageDestinationFinalize(dest2) else { throw RendererError.failed("finalize") }
        return mutableData as Data
    }

    /// Render source to WebP data (quality 75) at widthPx.
    static func renderToWebPData(url: URL, widthPx: Int = 2560) throws -> Data {
        let ext = url.pathExtension.lowercased()
        guard let cgImage = renderWithTransparency(url: url, width: widthPx, ext: ext) else {
            throw RendererError.failed(url.lastPathComponent)
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData, "org.webmproject.webp" as CFString, 1, nil
        ) else { throw RendererError.failed("WebP destination") }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.75]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RendererError.failed("WebP finalize") }
        return mutableData as Data
    }

    private static func renderWithTransparency(url: URL, width: Int, ext: String) -> CGImage? {
        switch ext {
        case "svg":
            guard let img = NSImage(contentsOf: url) else { return nil }
            let srcSize = img.size
            guard srcSize.width > 0 else { return nil }
            let scale = CGFloat(width) / srcSize.width
            let h = max(1, Int(srcSize.height * scale))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: width, height: h,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            img.draw(in: CGRect(x: 0, y: 0, width: width, height: h))
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()

        case "pdf":
            guard let pdfDoc = PDFDocument(url: url),
                  let page = pdfDoc.page(at: 0) else { return nil }
            let pageRect = page.bounds(for: .mediaBox)
            guard pageRect.width > 0 else { return nil }
            let scale = CGFloat(width) / pageRect.width
            let h = max(1, Int(pageRect.height * scale))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: width, height: h,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            return ctx.makeImage()

        default:
            guard let img = NSImage(contentsOf: url) else { return nil }
            let srcSize = img.size
            guard srcSize.width > 0 else { return nil }
            let scale = CGFloat(width) / srcSize.width
            let h = max(1, Int(srcSize.height * scale))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: width, height: h,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            img.draw(in: CGRect(x: 0, y: 0, width: width, height: h))
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }
    }

    enum RendererError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { return "Render failed: \(m)" }; return nil }
    }
}
