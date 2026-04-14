import Foundation
import Accelerate
import CoreGraphics

/// Image hashing using the same algorithms as the Python app:
///  - aHash (average hash)
///  - pHash (DCT perceptual hash, matching scipy's DCT-II)
///  - colorMoments (9-element vector: mean/stddev/skewness per R/G/B)
///
/// All heavy computation uses Accelerate/vDSP — no external dependencies.
enum ImageHasher {

    // DCT-II setup for size 32 (created once, thread-safe read-only after init)
    nonisolated(unsafe) private static let dct32: OpaquePointer = {
        guard let setup = vDSP_DCT_CreateSetup(nil, 32, .II) else {
            fatalError("vDSP_DCT_CreateSetup(32) failed")
        }
        return setup
    }()

    // MARK: - aHash

    /// Average hash: resize to 8×8 grayscale, compare each pixel to mean.
    static func aHash(from cgImage: CGImage) -> UInt64? {
        guard let pixels = grayscalePixels(cgImage, width: 8, height: 8) else { return nil }
        var mean: Float = 0
        vDSP_meanv(pixels, 1, &mean, 64)
        var hash: UInt64 = 0
        for (i, p) in pixels.enumerated() where p > mean {
            hash |= (1 << i)
        }
        return hash
    }

    // MARK: - pHash

    /// DCT perceptual hash: resize to 32×32 grayscale, 2D DCT, top-left 8×8, median threshold.
    static func pHash(from cgImage: CGImage) -> UInt64? {
        guard let pixels = grayscalePixels(cgImage, width: 32, height: 32) else { return nil }

        // Row-wise DCT
        var rowDCT = [Float](repeating: 0, count: 1024)
        for row in 0..<32 {
            let base = row * 32
            let rowIn = Array(pixels[base ..< base + 32])
            var rowOut = [Float](repeating: 0, count: 32)
            vDSP_DCT_Execute(dct32, rowIn, &rowOut)
            rowDCT.replaceSubrange(base ..< base + 32, with: rowOut)
        }

        // Transpose 32×32
        var transposed = [Float](repeating: 0, count: 1024)
        vDSP_mtrans(rowDCT, 1, &transposed, 1, 32, 32)

        // Column-wise DCT (now rows after transpose)
        var colDCT = [Float](repeating: 0, count: 1024)
        for row in 0..<32 {
            let base = row * 32
            var rowIn = Array(transposed[base ..< base + 32])
            var rowOut = [Float](repeating: 0, count: 32)
            vDSP_DCT_Execute(dct32, rowIn, &rowOut)
            colDCT.replaceSubrange(base ..< base + 32, with: rowOut)
        }

        // Transpose back to get 2D DCT
        var dct2D = [Float](repeating: 0, count: 1024)
        vDSP_mtrans(colDCT, 1, &dct2D, 1, 32, 32)

        // Extract top-left 8×8 (64 values)
        var sub = [Float](repeating: 0, count: 64)
        for row in 0..<8 {
            for col in 0..<8 {
                sub[row * 8 + col] = dct2D[row * 32 + col]
            }
        }

        // Median of non-DC values (indices 1..63)
        var nonDC = Array(sub[1...])
        nonDC.sort()
        let median = nonDC[nonDC.count / 2]

        var hash: UInt64 = 0
        for (i, val) in sub.enumerated() where val > median {
            hash |= (1 << i)
        }
        return hash
    }

    // MARK: - Color moments

    /// Returns 9 floats: [mean_R, std_R, skew_R, mean_G, std_G, skew_G, mean_B, std_B, skew_B]
    static func colorMoments(from cgImage: CGImage) -> [Float]? {
        guard let rgba = rgbaPixels(cgImage, width: 256, height: 256) else { return nil }
        let n = vDSP_Length(256 * 256)
        var moments = [Float](repeating: 0, count: 9)

        for ch in 0..<3 {
            // Extract channel (stride 4 for RGBA)
            var channel = [Float](repeating: 0, count: Int(n))
            for i in 0..<Int(n) { channel[i] = Float(rgba[i * 4 + ch]) / 255.0 }

            // Mean
            var mean: Float = 0
            vDSP_meanv(channel, 1, &mean, n)
            moments[ch * 3] = mean

            // Deviation from mean
            var negMean = -mean
            var diff = [Float](repeating: 0, count: Int(n))
            vDSP_vsadd(channel, 1, &negMean, &diff, 1, n)

            // Variance → stddev
            var sq = [Float](repeating: 0, count: Int(n))
            vDSP_vsq(diff, 1, &sq, 1, n)
            var variance: Float = 0
            vDSP_meanv(sq, 1, &variance, n)
            moments[ch * 3 + 1] = sqrt(max(0, variance))

            // Skewness: cbrt(E[diff^3])
            var cubed = [Float](repeating: 0, count: Int(n))
            vDSP_vmul(sq, 1, diff, 1, &cubed, 1, n)
            var meanCubed: Float = 0
            vDSP_meanv(cubed, 1, &meanCubed, n)
            moments[ch * 3 + 2] = cbrt(meanCubed)
        }

        return moments
    }

    // MARK: - Distances

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    static func colorMomentDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        var distSq: Float = 0
        vDSP_distancesq(a, 1, b, 1, &distSq, vDSP_Length(a.count))
        return sqrt(distSq)
    }

    // MARK: - Pixel extraction

    private static func grayscalePixels(_ cgImage: CGImage, width: Int, height: Int) -> [Float]? {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width, space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let ptr = ctx.data else { return nil }
        let count = width * height
        return (0..<count).map { Float(ptr.load(fromByteOffset: $0, as: UInt8.self)) }
    }

    private static func rgbaPixels(_ cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // White background before drawing (matches Python convention)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}

// MARK: - Fingerprinter (combines renderer + hasher)

enum ImageFingerprinter {

    static func fingerprint(url: URL) -> ImageFingerprint {
        let filename = url.lastPathComponent
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        guard let cgImage = ImageRenderer.renderForHashing(url: url, maxDim: 256) else {
            return ImageFingerprint(filename: filename, fileSizeBytes: fileSize,
                                    aHash: nil, pHash: nil, colorMoments: nil,
                                    width: nil, height: nil, thumbnailData: nil,
                                    error: "render failed")
        }

        let aHash = ImageHasher.aHash(from: cgImage)
        let pHash = ImageHasher.pHash(from: cgImage)
        let cm = ImageHasher.colorMoments(from: cgImage)

        // Thumbnail at max 260×180
        let thumbCG = ImageRenderer.renderThumbnail(url: url)
        let thumbData: Data? = thumbCG.flatMap { cgThumb -> Data? in
            let mutableData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                mutableData, "public.png" as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(dest, cgThumb, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return mutableData as Data
        }

        return ImageFingerprint(
            filename: filename,
            fileSizeBytes: fileSize,
            aHash: aHash,
            pHash: pHash,
            colorMoments: cm,
            width: cgImage.width,
            height: cgImage.height,
            thumbnailData: thumbData,
            error: nil
        )
    }
}
