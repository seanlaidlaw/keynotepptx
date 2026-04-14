import Foundation
import SwiftUI

// MARK: - Input items

struct PPTXMediaItem: Sendable {
    let filename: String
    let absolutePath: URL
    let slideNumbers: [Int]
    let isMasterOnly: Bool
}

struct KeynoteMediaItem: Sendable {
    let filename: String
    let absolutePath: URL
    let slideNumbers: [Int]
    let objectID: String
}

// MARK: - Fingerprinting

struct ImageFingerprint: Sendable {
    let filename: String
    let fileSizeBytes: Int
    let aHash: UInt64?
    let pHash: UInt64?
    let colorMoments: [Float]?
    let width: Int?
    let height: Int?
    let thumbnailData: Data?   // PNG data; converted to NSImage on MainActor
    let error: String?
}

// MARK: - Matching

enum ReplacementKind: String, Sendable {
    case svg, pdf, raster
}

struct CandidateMatch: Identifiable, Sendable {
    let id: UUID
    let keynoteFilename: String
    let keynotePath: URL
    let fileExtension: String
    let fileSizeBytes: Int
    let thumbnailData: Data?
    let aHashDistance: Int
    let pHashDistance: Int
    let colorMomentDistance: Float
    let replacementKind: ReplacementKind

    init(
        keynoteFilename: String, keynotePath: URL,
        fileExtension: String, fileSizeBytes: Int,
        thumbnailData: Data?,
        aHashDistance: Int, pHashDistance: Int, colorMomentDistance: Float,
        replacementKind: ReplacementKind
    ) {
        self.id = UUID()
        self.keynoteFilename = keynoteFilename
        self.keynotePath = keynotePath
        self.fileExtension = fileExtension
        self.fileSizeBytes = fileSizeBytes
        self.thumbnailData = thumbnailData
        self.aHashDistance = aHashDistance
        self.pHashDistance = pHashDistance
        self.colorMomentDistance = colorMomentDistance
        self.replacementKind = replacementKind
    }
}

enum MatchQuality: String, Sendable {
    case xmlExact = "xml_exact"
    case exact
    case strong
    case review
    case poor
    case noMatch = "no_match"

    var label: String {
        switch self {
        case .xmlExact: return "XML match"
        case .exact: return "Exact"
        case .strong: return "Strong"
        case .review: return "Review"
        case .poor: return "Poor"
        case .noMatch: return "No match"
        }
    }

    var color: Color {
        switch self {
        case .xmlExact, .exact: return .green
        case .strong: return .blue
        case .review: return .yellow
        case .poor: return .orange
        case .noMatch: return .red
        }
    }
}

enum RowChoice: Equatable, Sendable {
    case keynoteFile(filename: String)
    case customFile(url: URL)
    case skip
}

struct MappingRow: Identifiable, Sendable {
    let id: UUID
    let pptxItem: PPTXMediaItem
    let pptxFingerprint: ImageFingerprint
    var topCandidates: [CandidateMatch]
    var quality: MatchQuality
    var isXmlExact: Bool
    var selectedChoice: RowChoice

    init(
        pptxItem: PPTXMediaItem, pptxFingerprint: ImageFingerprint,
        topCandidates: [CandidateMatch], quality: MatchQuality,
        isXmlExact: Bool, selectedChoice: RowChoice
    ) {
        self.id = UUID()
        self.pptxItem = pptxItem
        self.pptxFingerprint = pptxFingerprint
        self.topCandidates = topCandidates
        self.quality = quality
        self.isXmlExact = isXmlExact
        self.selectedChoice = selectedChoice
    }
}

// MARK: - App phases & modes

enum AppPhase: Sendable {
    case welcome
    case processing
    case review
    case patchOptions
    case patching
    case done(outputURL: URL)
    case error(String)
}

enum PatchMode: String, CaseIterable, Sendable {
    case vectorInPlace = "vector_in_place"
    case embedPNG = "embed_png"
    case embedWebP75 = "embed_webp_75"

    var displayName: String {
        switch self {
        case .vectorInPlace: return "Embed vector images"
        case .embedPNG: return "Embed as high quality PNG"
        case .embedWebP75: return "Embed as WebP quality 75"
        }
    }

    var detail: String {
        switch self {
        case .vectorInPlace:
            return "Use selected SVG/PDF files directly. Best for PowerPoint on Mac/Windows that support embedded SVG."
        case .embedPNG:
            return "Convert selected SVG/PDF replacements to PNG at 2560 px wide. Maximum compatibility."
        case .embedWebP75:
            return "Convert to PNG then compress to WebP at quality 75. Smaller file, but slower to open."
        }
    }
}
