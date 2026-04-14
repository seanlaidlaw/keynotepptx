import Foundation
import Snappy

// MARK: - Minimal protobuf reader

struct ProtoReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    var hasMore: Bool { offset < data.count }
    var remaining: Int { data.count - offset }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw ProtoError.unexpectedEOF }
        let byte = data[data.startIndex.advanced(by: offset)]
        offset += 1
        return byte
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift = 0
        repeat {
            let byte = try readByte()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw ProtoError.varintOverflow }
        } while true
    }

    /// Read `count` raw bytes.
    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw ProtoError.unexpectedEOF }
        let start = data.startIndex.advanced(by: offset)
        let slice = data[start ..< start.advanced(by: count)]
        offset += count
        return Data(slice)
    }

    /// Read a varint length prefix, then that many bytes.
    mutating func readLengthDelimited() throws -> Data {
        let length = Int(try readVarint())
        return try readBytes(count: length)
    }

    mutating func readFixed32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }

    mutating func readFixed64() throws -> UInt64 {
        let bytes = try readBytes(count: 8)
        return bytes.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
    }

    mutating func skipField(wireType: UInt8) throws {
        switch wireType {
        case 0: _ = try readVarint()
        case 1: _ = try readFixed64()
        case 2: _ = try readLengthDelimited()
        case 5: _ = try readFixed32()
        default: throw ProtoError.unknownWireType(wireType)
        }
    }

    enum ProtoError: Error {
        case unexpectedEOF
        case varintOverflow
        case unknownWireType(UInt8)
    }
}

// MARK: - IWA types

struct IWAMessageInfo: Sendable {
    let type: UInt32
    let length: UInt32
    let objectReferences: [UInt64]
    let dataReferences: [UInt64]
}

struct IWAArchiveHeader: Sendable {
    let identifier: UInt64
    let messageInfos: [IWAMessageInfo]
}

// MARK: - Decoder

/// Decodes Keynote's IWA chunk format:
///   Repeated chunks: 0x00 | 3-byte-LE-compressed-length | snappy-payload
///   Within each decompressed payload, repeated archives:
///   [varint: ArchiveInfo-byte-count] [ArchiveInfo protobuf] [message payloads]
enum IWADecoder {

    static func decode(_ raw: Data) throws -> [(header: IWAArchiveHeader, payload: Data)] {
        var results: [(header: IWAArchiveHeader, payload: Data)] = []
        var offset = 0

        while offset < raw.count {
            // Magic byte
            guard raw[raw.startIndex.advanced(by: offset)] == 0x00 else {
                throw IWAError.invalidMagicByte(raw[raw.startIndex.advanced(by: offset)])
            }
            offset += 1

            guard offset + 3 <= raw.count else { throw IWAError.truncatedChunk }
            let b0 = Int(raw[raw.startIndex.advanced(by: offset)])
            let b1 = Int(raw[raw.startIndex.advanced(by: offset + 1)])
            let b2 = Int(raw[raw.startIndex.advanced(by: offset + 2)])
            let compressedLength = b0 | (b1 << 8) | (b2 << 16)
            offset += 3

            guard offset + compressedLength <= raw.count else { throw IWAError.truncatedChunk }
            let compressedSlice = raw[raw.startIndex.advanced(by: offset) ..< raw.startIndex.advanced(by: offset + compressedLength)]
            offset += compressedLength

            // Decompress; fall back to raw if decompression fails (matches Python codec.py)
            let compressed = Data(compressedSlice)
            let uncompressed: Data
            do {
                uncompressed = try compressed.uncompressedUsingSnappy()
            } catch {
                uncompressed = compressed
            }

            let archives = try parseArchives(from: uncompressed)
            results.append(contentsOf: archives)
        }

        return results
    }

    // MARK: - Archive parsing

    private static func parseArchives(from data: Data) throws -> [(header: IWAArchiveHeader, payload: Data)] {
        var reader = ProtoReader(data)
        var results: [(header: IWAArchiveHeader, payload: Data)] = []

        while reader.hasMore {
            // varint: size of the upcoming ArchiveInfo protobuf
            let headerSize: UInt64
            do { headerSize = try reader.readVarint() } catch { break }
            guard headerSize > 0, Int(headerSize) <= reader.remaining else { break }

            let headerData = try reader.readBytes(count: Int(headerSize))
            let archiveHeader = try parseArchiveHeader(from: headerData)

            let totalPayload = archiveHeader.messageInfos.reduce(0) { $0 + Int($1.length) }
            guard totalPayload <= reader.remaining else { break }
            let payload = try reader.readBytes(count: totalPayload)

            results.append((header: archiveHeader, payload: payload))
        }

        return results
    }

    private static func parseArchiveHeader(from data: Data) throws -> IWAArchiveHeader {
        var reader = ProtoReader(data)
        var identifier: UInt64 = 0
        var messageInfos: [IWAMessageInfo] = []

        while reader.hasMore {
            let tag = try reader.readVarint()
            let fieldNumber = tag >> 3
            let wireType = UInt8(tag & 0x7)

            switch fieldNumber {
            case 1:
                identifier = try reader.readVarint()
            case 2:
                let msgData = try reader.readLengthDelimited()
                messageInfos.append(try parseMessageInfo(from: msgData))
            default:
                try reader.skipField(wireType: wireType)
            }
        }

        return IWAArchiveHeader(identifier: identifier, messageInfos: messageInfos)
    }

    private static func parseMessageInfo(from data: Data) throws -> IWAMessageInfo {
        var reader = ProtoReader(data)
        var type: UInt32 = 0
        var length: UInt32 = 0
        var objectRefs: [UInt64] = []
        var dataRefs: [UInt64] = []

        while reader.hasMore {
            let tag = try reader.readVarint()
            let fieldNumber = tag >> 3
            let wireType = UInt8(tag & 0x7)

            switch fieldNumber {
            case 1: type = UInt32(try reader.readVarint())
            case 3: length = UInt32(try reader.readVarint())
            case 5: objectRefs = try unpackVarints(from: try reader.readLengthDelimited())
            case 6: dataRefs = try unpackVarints(from: try reader.readLengthDelimited())
            default: try reader.skipField(wireType: wireType)
            }
        }

        return IWAMessageInfo(type: type, length: length,
                              objectReferences: objectRefs, dataReferences: dataRefs)
    }

    private static func unpackVarints(from data: Data) throws -> [UInt64] {
        var reader = ProtoReader(data)
        var values: [UInt64] = []
        while reader.hasMore {
            values.append(try reader.readVarint())
        }
        return values
    }

    // MARK: - Error

    enum IWAError: Error, LocalizedError {
        case invalidMagicByte(UInt8)
        case truncatedChunk

        var errorDescription: String? {
            switch self {
            case .invalidMagicByte(let b): return "Invalid IWA magic byte: 0x\(String(b, radix: 16))"
            case .truncatedChunk: return "IWA chunk truncated"
            }
        }
    }
}
