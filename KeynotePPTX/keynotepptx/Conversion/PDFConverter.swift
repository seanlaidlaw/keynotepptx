import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// Source - https://stackoverflow.com/a/45777595
// Posted by Mike Henderson, modified by community. See post 'Timeline' for change history.
// Retrieved 2026-04-15, License - CC BY-SA 3.0
// Adapted: uses UniformTypeIdentifiers (replaces deprecated kUTType* constants), respects
// PDF CropBox via ImageRenderer.cgPDFVisibleRect, and is marked @discardableResult.

struct PDFImageFileType {
    let uti: CFString
    let fileExtension: String

    static let bmp  = PDFImageFileType(uti: UTType.bmp.identifier  as CFString, fileExtension: "bmp")
    static let gif  = PDFImageFileType(uti: UTType.gif.identifier  as CFString, fileExtension: "gif")
    static let jpeg = PDFImageFileType(uti: UTType.jpeg.identifier as CFString, fileExtension: "jpg")
    static let png  = PDFImageFileType(uti: UTType.png.identifier  as CFString, fileExtension: "png")
    static let tiff = PDFImageFileType(uti: UTType.tiff.identifier as CFString, fileExtension: "tiff")
}

/// Converts every page in a PDF to an image file at a specified DPI.
///
/// Use `dpiMatchingReference(pdfURL:referencePixelWidth:)` to derive the DPI that
/// reproduces the exact pixel width of a known reference image — this matches the
/// DPI Keynote uses internally when rasterising assets for PPTX export.
///
/// - Parameters:
///   - sourceURL:      URL of the source PDF.
///   - destinationURL: Directory to write output images into (must exist).
///   - fileType:       Output image format (default `.png`).
///   - dpi:            Render resolution in dots per inch (default 200).
/// - Returns: Array of output file URLs, one per PDF page, in page order.
@discardableResult
func convertPDF(
    at sourceURL: URL,
    to destinationURL: URL,
    fileType: PDFImageFileType = .png,
    dpi: CGFloat = 200
) throws -> [URL] {
    guard let pdfDocument = CGPDFDocument(sourceURL as CFURL) else {
        throw PDFConverterError.cannotOpen(sourceURL)
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let scale = dpi / 72.0
    let pageCount = pdfDocument.numberOfPages

    // Pre-fill with sentinel values; each slot is written exactly once below.
    var urls = [URL](repeating: URL(fileURLWithPath: "/"), count: pageCount)

    // Concurrent rendering — each iteration writes to a unique index (safe).
    DispatchQueue.concurrentPerform(iterations: pageCount) { i in
        let page = pdfDocument.page(at: i + 1)!
        let pageRect = ImageRenderer.cgPDFVisibleRect(page)
        let width  = max(1, Int(pageRect.width  * scale))
        let height = max(1, Int(pageRect.height * scale))

        guard let image = ImageRenderer.renderPDFPageOpaque(
            page: page, pageRect: pageRect, scale: scale,
            width: width, height: height, cs: colorSpace
        ) else { return }

        let stem     = sourceURL.deletingPathExtension().lastPathComponent
        let imageURL = destinationURL.appendingPathComponent("\(stem)-Page\(i + 1).\(fileType.fileExtension)")

        guard let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, fileType.uti, 1, nil as CFDictionary?) else { return }
        CGImageDestinationAddImage(dest, image, nil as CFDictionary?)
        CGImageDestinationFinalize(dest)

        urls[i] = imageURL
    }
    return urls
}

/// Returns the DPI at which `convertPDF` should render the PDF so that the output
/// page has exactly `referencePixelWidth` pixels wide — matching the reference PNG.
///
/// - Parameters:
///   - pdfURL:              URL of the PDF to render.
///   - referencePixelWidth: Pixel width of the reference PNG (e.g. from the PPTX).
/// - Returns: The computed DPI, or `nil` if the PDF cannot be opened.
func dpiMatchingReference(pdfURL: URL, referencePixelWidth: Int) -> CGFloat? {
    guard let doc  = CGPDFDocument(pdfURL as CFURL),
          let page = doc.page(at: 1) else { return nil }
    let pageRect = ImageRenderer.cgPDFVisibleRect(page)
    guard pageRect.width > 0 else { return nil }
    return CGFloat(referencePixelWidth) / pageRect.width * 72.0
}

// MARK: - Errors

enum PDFConverterError: Error, LocalizedError {
    case cannotOpen(URL)

    var errorDescription: String? {
        if case .cannotOpen(let url) = self {
            return "Cannot open PDF at \(url.path)"
        }
        return nil
    }
}
