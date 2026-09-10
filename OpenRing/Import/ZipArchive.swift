import Foundation
import Compression

/// Minimal read-only ZIP reader.
///
/// iOS has no public unzip API, and pulling in a package for one screen is not worth it, so
/// this walks the central directory itself and inflates entries with the Compression
/// framework. Only the two methods a real export uses are supported: stored and deflate.
enum ZipArchive {

    struct Entry {
        var name: String
        var data: Data
    }

    enum ZipError: LocalizedError {
        case notAZip
        case unsupportedCompression(UInt16, entry: String)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notAZip:
                return "That file is not a ZIP archive."
            case .unsupportedCompression(let method, let entry):
                return "\(entry) uses an unsupported compression method (\(method))."
            case .corrupt(let detail):
                return "The archive looks damaged: \(detail)"
            }
        }
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4B50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50

    static func entries(in rawArchive: Data) throws -> [Entry] {
        // Re-wrap so indices are zero-based: a sliced `Data` keeps its parent's indices and
        // every offset below is an absolute file offset.
        let archive = Data(rawArchive)
        guard let eocd = findEndOfCentralDirectory(in: archive) else { throw ZipError.notAZip }

        let entryCount = Int(readUInt16(archive, eocd + 10))
        var offset = Int(readUInt32(archive, eocd + 16))
        var entries: [Entry] = []

        for _ in 0..<entryCount {
            guard offset + 46 <= archive.count,
                  readUInt32(archive, offset) == centralFileHeaderSignature else {
                throw ZipError.corrupt("central directory entry at \(offset)")
            }
            let method = readUInt16(archive, offset + 10)
            let compressedSize = Int(readUInt32(archive, offset + 20))
            let uncompressedSize = Int(readUInt32(archive, offset + 24))
            let nameLength = Int(readUInt16(archive, offset + 28))
            let extraLength = Int(readUInt16(archive, offset + 30))
            let commentLength = Int(readUInt16(archive, offset + 32))
            let localHeaderOffset = Int(readUInt32(archive, offset + 42))

            let nameStart = archive.startIndex + offset + 46
            guard nameStart + nameLength <= archive.endIndex else { throw ZipError.corrupt("entry name") }
            let name = String(decoding: archive[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            // Directories and macOS resource-fork noise are not data.
            let isDirectory = name.hasSuffix("/")
            let isMetadata = name.hasPrefix("__MACOSX/") || name.hasPrefix(".")
            if !isDirectory && !isMetadata {
                let data = try extract(
                    from: archive,
                    localHeaderOffset: localHeaderOffset,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    name: name
                )
                entries.append(Entry(name: name, data: data))
            }

            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func extract(
        from archive: Data,
        localHeaderOffset: Int,
        method: UInt16,
        compressedSize: Int,
        uncompressedSize: Int,
        name: String
    ) throws -> Data {
        guard localHeaderOffset + 30 <= archive.count,
              readUInt32(archive, localHeaderOffset) == localFileHeaderSignature else {
            throw ZipError.corrupt("local header for \(name)")
        }
        // The local header repeats the name and extra lengths, and they can differ from the
        // central directory's, so always read them here.
        let nameLength = Int(readUInt16(archive, localHeaderOffset + 26))
        let extraLength = Int(readUInt16(archive, localHeaderOffset + 28))
        let start = localHeaderOffset + 30 + nameLength + extraLength
        let end = start + compressedSize
        guard end <= archive.count else { throw ZipError.corrupt("truncated data for \(name)") }
        let payload = archive.subdata(in: (archive.startIndex + start)..<(archive.startIndex + end))

        switch method {
        case 0:
            return payload
        case 8:
            guard let inflated = inflate(payload, expectedSize: uncompressedSize) else {
                throw ZipError.corrupt("could not inflate \(name)")
            }
            return inflated
        default:
            throw ZipError.unsupportedCompression(method, entry: name)
        }
    }

    /// ZIP stores raw DEFLATE, which is what `COMPRESSION_ZLIB` means in Apple's framework.
    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        // Zero is legal in the header when sizes live in a data descriptor; guess generously.
        let capacity = expectedSize > 0 ? expectedSize : max(data.count * 8, 64 * 1024)
        var output = Data(count: capacity)

        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase, capacity,
                    sourceBase, data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return Data(output.prefix(written))
    }

    // MARK: - Byte access

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        // The EOCD sits at the end, after a comment of up to 64 KB.
        let lowerBound = max(0, data.count - 22 - 65_535)
        var offset = data.count - 22
        while offset >= lowerBound {
            if readUInt32(data, offset) == endOfCentralDirectorySignature { return offset }
            offset -= 1
        }
        return nil
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }
}
