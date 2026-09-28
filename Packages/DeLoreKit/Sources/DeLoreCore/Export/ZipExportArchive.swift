#if canImport(Compression)
import Compression
import Foundation

/// Minimal ZIP reader for Instagram exports: central directory (incl. ZIP64), stored and
/// deflate entries. Reads entries on demand from disk; the archive is never loaded whole.
public final class ZipExportArchive: ExportArchive, @unchecked Sendable {
    private struct Entry {
        let method: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let encrypted: Bool
    }

    /// Guards against zip bombs; message files are far smaller than this.
    public static let maximumEntrySize: UInt64 = 256 * 1024 * 1024

    private let url: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init(url: URL) throws {
        self.url = url
        try readCentralDirectory()
    }

    public func entryPaths() throws -> [String] {
        lock.withLock { Array(entries.keys) }
    }

    public func contents(of path: String) throws -> Data {
        guard let entry = lock.withLock({ entries[path] }) else { throw ExportArchiveError.entryNotFound }
        guard !entry.encrypted else { throw ExportArchiveError.encryptedArchive }
        guard entry.uncompressedSize <= Self.maximumEntrySize, entry.compressedSize <= Self.maximumEntrySize else {
            throw ExportArchiveError.entryTooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try read(handle, at: entry.localHeaderOffset, count: 30)
        guard header.uint32(at: 0) == 0x0403_4B50 else { throw ExportArchiveError.unsupportedFormat }
        let nameLength = UInt64(header.uint16(at: 26))
        let extraLength = UInt64(header.uint16(at: 28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        let compressed = try read(handle, at: dataOffset, count: Int(entry.compressedSize))

        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ExportArchiveError.unsupportedFormat
        }
    }

    private func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP uses.
                return compression_decode_buffer(dst, expectedSize, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ExportArchiveError.unreadable }
        return output
    }

    private func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ExportArchiveError.unreadable
        }
        return data
    }

    private func readCentralDirectory() throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ExportArchiveError.unreadable
        }
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let tailLength = min(fileSize, 65_557)
        let tail = try read(handle, at: fileSize - tailLength, count: Int(tailLength))

        guard let eocd = tail.lastIndex(ofSignature: 0x0605_4B50) else { throw ExportArchiveError.unsupportedFormat }
        var entryCount = UInt64(tail.uint16(at: eocd + 10))
        var directorySize = UInt64(tail.uint32(at: eocd + 12))
        var directoryOffset = UInt64(tail.uint32(at: eocd + 16))

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: locator sits immediately before the classic end record.
            guard eocd >= 20, tail.uint32(at: eocd - 20) == 0x0706_4B50 else { throw ExportArchiveError.unsupportedFormat }
            let zip64Offset = tail.uint64(at: eocd - 20 + 8)
            let record = try read(handle, at: zip64Offset, count: 56)
            guard record.uint32(at: 0) == 0x0606_4B50 else { throw ExportArchiveError.unsupportedFormat }
            entryCount = record.uint64(at: 32)
            directorySize = record.uint64(at: 40)
            directoryOffset = record.uint64(at: 48)
        }

        guard directorySize < 512 * 1024 * 1024 else { throw ExportArchiveError.unsupportedFormat }
        let directory = try read(handle, at: directoryOffset, count: Int(directorySize))

        var parsed: [String: Entry] = [:]
        var cursor = 0
        for _ in 0..<entryCount {
            guard cursor + 46 <= directory.count, directory.uint32(at: cursor) == 0x0201_4B50 else {
                throw ExportArchiveError.unsupportedFormat
            }
            let flags = directory.uint16(at: cursor + 8)
            let method = directory.uint16(at: cursor + 10)
            var compressedSize = UInt64(directory.uint32(at: cursor + 20))
            var uncompressedSize = UInt64(directory.uint32(at: cursor + 24))
            let nameLength = Int(directory.uint16(at: cursor + 28))
            let extraLength = Int(directory.uint16(at: cursor + 30))
            let commentLength = Int(directory.uint16(at: cursor + 32))
            var localOffset = UInt64(directory.uint32(at: cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength <= directory.count else { throw ExportArchiveError.unsupportedFormat }
            let nameData = directory.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)

            // ZIP64 extended information: values appear only for fields that overflowed.
            var extraCursor = nameStart + nameLength
            let extraEnd = extraCursor + extraLength
            while extraCursor + 4 <= extraEnd {
                let headerID = directory.uint16(at: extraCursor)
                let size = Int(directory.uint16(at: extraCursor + 2))
                var fieldCursor = extraCursor + 4
                if headerID == 0x0001 {
                    if uncompressedSize == 0xFFFF_FFFF, fieldCursor + 8 <= extraEnd {
                        uncompressedSize = directory.uint64(at: fieldCursor)
                        fieldCursor += 8
                    }
                    if compressedSize == 0xFFFF_FFFF, fieldCursor + 8 <= extraEnd {
                        compressedSize = directory.uint64(at: fieldCursor)
                        fieldCursor += 8
                    }
                    if localOffset == 0xFFFF_FFFF, fieldCursor + 8 <= extraEnd {
                        localOffset = directory.uint64(at: fieldCursor)
                    }
                }
                extraCursor += 4 + size
            }

            if !name.hasSuffix("/") {
                parsed[name] = Entry(
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset,
                    encrypted: flags & 0x1 != 0
                )
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        entries = parsed
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }

    func lastIndex(ofSignature signature: UInt32) -> Int? {
        guard count >= 22 else { return nil }
        var offset = count - 22
        while offset >= 0 {
            if uint32(at: offset) == signature { return offset }
            offset -= 1
        }
        return nil
    }
}
#endif
