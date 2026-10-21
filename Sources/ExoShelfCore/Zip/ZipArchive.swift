import Compression
import Foundation

/// Random access to bytes, from a local file or from a file inside the
/// torrent (fetched piece by piece on demand).
public protocol RandomAccessSource: Sendable {
    var size: Int64 { get }
    func read(_ range: Range<Int64>) async throws -> Data
}

public struct LocalFileSource: RandomAccessSource {
    public let url: URL
    public let size: Int64

    public init(url: URL) throws {
        self.url = url
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        self.size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func read(_ range: Range<Int64>) async throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(range.lowerBound))
        return try h.read(upToCount: Int(range.count)) ?? Data()
    }
}

/// A file inside the torrent, read through the session's piece cache.
public struct TorrentFileSource: RandomAccessSource {
    public let session: TorrentSession
    public let file: TorrentFile
    public let priority: Int

    public init(session: TorrentSession, file: TorrentFile, priority: Int = 0) {
        self.session = session
        self.file = file
        self.priority = priority
    }

    public var size: Int64 { file.length }

    public func read(_ range: Range<Int64>) async throws -> Data {
        try await session.read((file.offset + range.lowerBound)..<(file.offset + range.upperBound), priority: priority)
    }
}

/// A window into another source: how a zip stored (uncompressed) inside
/// another zip is read without unpacking the outer one. eXo keeps its
/// emulator extras, MT-32 ROMs included, in such a nested archive.
public struct SubrangeSource: RandomAccessSource {
    public let base: RandomAccessSource
    public let range: Range<Int64>

    public init(base: RandomAccessSource, range: Range<Int64>) {
        self.base = base
        self.range = range
    }

    public var size: Int64 { range.upperBound - range.lowerBound }

    public func read(_ r: Range<Int64>) async throws -> Data {
        let lo = range.lowerBound + r.lowerBound
        let hi = min(range.upperBound, range.lowerBound + r.upperBound)
        guard lo <= hi else { return Data() }
        return try await base.read(lo..<hi)
    }
}

public struct ZipEntry: Sendable, Hashable, Codable {
    public let name: String
    public let method: UInt16
    public let flags: UInt16
    public let crc32: UInt32
    public let compressedSize: Int64
    public let uncompressedSize: Int64
    public let localHeaderOffset: Int64
    public let externalAttributes: UInt32

    public var isDirectory: Bool { name.hasSuffix("/") }
    public var isEncrypted: Bool { flags & 1 != 0 }
    /// Upper bound of the bytes this entry occupies in the archive, local
    /// header included, assuming a local extra field of at most 1 KiB.
    public var approximateSpan: Range<Int64> {
        localHeaderOffset..<(localHeaderOffset + 30 + Int64(name.utf8.count) + 1024 + compressedSize)
    }
}

public enum ZipError: Error, CustomStringConvertible {
    case notAZip
    case truncated
    case unsupportedMethod(UInt16, String)
    case encrypted(String)
    case corrupt(String)
    case unsafePath(String)

    public var description: String {
        switch self {
        case .notAZip: return "not a zip archive"
        case .truncated: return "zip archive is truncated"
        case .unsupportedMethod(let m, let n): return "\(n) uses compression method \(m)"
        case .encrypted(let n): return "\(n) is encrypted"
        case .corrupt(let n): return "\(n) is damaged (CRC mismatch)"
        case .unsafePath(let n): return "refusing to extract \(n) outside the target folder"
        }
    }
}

/// Reads a zip's central directory and its entries over any random-access
/// source, zip64 included. Supports stored and deflated entries, which is
/// what eXo's archives use.
public struct ZipArchive: Sendable {
    public let source: RandomAccessSource
    public let entries: [ZipEntry]

    public init(source: RandomAccessSource, entries: [ZipEntry]) {
        self.source = source
        self.entries = entries
    }

    public static func open(_ source: RandomAccessSource) async throws -> ZipArchive {
        let size = source.size
        guard size >= 22 else { throw ZipError.notAZip }
        let tailLength = min(size, 65_557)
        let tail = try await source.read((size - tailLength)..<size)
        guard let eocd = findBackwards(tail, signature: 0x0605_4B50) else { throw ZipError.notAZip }

        var cdCount = Int64(tail.le16(eocd + 10))
        var cdSize = Int64(tail.le32(eocd + 12))
        var cdOffset = Int64(tail.le32(eocd + 16))

        if cdCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, eocd >= 20, tail.le32(eocd - 20) == 0x0706_4B50 {
            let zip64Offset = Int64(tail.le64(eocd - 20 + 8))
            let rec = try await source.read(zip64Offset..<(zip64Offset + 56))
            guard rec.count == 56, rec.le32(0) == 0x0606_4B50 else { throw ZipError.notAZip }
            cdCount = Int64(rec.le64(32))
            cdSize = Int64(rec.le64(40))
            cdOffset = Int64(rec.le64(48))
        }
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= size else { throw ZipError.truncated }
        let cd = try await source.read(cdOffset..<(cdOffset + cdSize))
        guard cd.count == cdSize else { throw ZipError.truncated }
        return ZipArchive(source: source, entries: try parseCentralDirectory(cd, expected: Int(cdCount)))
    }

    static func parseCentralDirectory(_ cd: Data, expected: Int) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        entries.reserveCapacity(expected)
        var p = 0
        while p + 46 <= cd.count, cd.le32(p) == 0x0201_4B50 {
            let flags = cd.le16(p + 8)
            let method = cd.le16(p + 10)
            let crc = cd.le32(p + 16)
            var compressed = Int64(cd.le32(p + 20))
            var uncompressed = Int64(cd.le32(p + 24))
            let nameLength = Int(cd.le16(p + 28))
            let extraLength = Int(cd.le16(p + 30))
            let commentLength = Int(cd.le16(p + 32))
            let external = cd.le32(p + 38)
            var offset = Int64(cd.le32(p + 42))
            let nameStart = p + 46
            guard nameStart + nameLength + extraLength <= cd.count else { throw ZipError.truncated }
            let nameBytes = cd.subdata(in: (cd.startIndex + nameStart)..<(cd.startIndex + nameStart + nameLength))
            let name = decodeName(nameBytes, utf8: flags & 0x800 != 0)

            // zip64 extended information: only the fields that overflowed are present.
            var e = nameStart + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let tag = cd.le16(e)
                let len = Int(cd.le16(e + 2))
                var f = e + 4
                if tag == 0x0001 {
                    if uncompressed == 0xFFFF_FFFF, f + 8 <= e + 4 + len { uncompressed = Int64(cd.le64(f)); f += 8 }
                    if compressed == 0xFFFF_FFFF, f + 8 <= e + 4 + len { compressed = Int64(cd.le64(f)); f += 8 }
                    if offset == 0xFFFF_FFFF, f + 8 <= e + 4 + len { offset = Int64(cd.le64(f)); f += 8 }
                }
                e += 4 + len
            }
            entries.append(ZipEntry(
                name: name, method: method, flags: flags, crc32: crc,
                compressedSize: compressed, uncompressedSize: uncompressed,
                localHeaderOffset: offset, externalAttributes: external
            ))
            p = extraEnd + commentLength
        }
        return entries
    }

    private static func findBackwards(_ data: Data, signature: UInt32) -> Int? {
        var i = data.count - 22
        while i >= 0 {
            if data.le32(i) == signature { return i }
            i -= 1
        }
        return nil
    }

    static func decodeName(_ bytes: Data, utf8: Bool) -> String {
        if utf8, let s = String(data: bytes, encoding: .utf8) { return s }
        if bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        // Legacy archives use code page 437. Many tools write UTF-8 without
        // setting the flag, so try that first.
        if let s = String(data: bytes, encoding: .utf8) { return s }
        return String(bytes.map { CP437.character($0) })
    }

    public func entry(named name: String) -> ZipEntry? {
        entries.first { $0.name == name } ?? entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Byte range of the entry's compressed data, from its local header.
    public func dataRange(of entry: ZipEntry) async throws -> Range<Int64> {
        let header = try await source.read(entry.localHeaderOffset..<(entry.localHeaderOffset + 30))
        guard header.count == 30, header.le32(0) == 0x0403_4B50 else { throw ZipError.truncated }
        let start = entry.localHeaderOffset + 30 + Int64(header.le16(26)) + Int64(header.le16(28))
        return start..<(start + entry.compressedSize)
    }

    /// Opens a zip stored without compression inside this one.
    public func nested(_ entry: ZipEntry) async throws -> ZipArchive {
        guard entry.method == 0 else { throw ZipError.unsupportedMethod(entry.method, entry.name) }
        let range = try await dataRange(of: entry)
        return try await ZipArchive.open(SubrangeSource(base: source, range: range))
    }

    /// The whole entry in memory. For small entries: XML, configs, images.
    public func data(of entry: ZipEntry) async throws -> Data {
        guard !entry.isEncrypted else { throw ZipError.encrypted(entry.name) }
        let range = try await dataRange(of: entry)
        let raw = try await source.read(range)
        guard raw.count == entry.compressedSize else { throw ZipError.truncated }
        let out: Data
        switch entry.method {
        case 0:
            out = raw
        case 8:
            out = try Inflater.inflate(raw, expectedSize: Int(entry.uncompressedSize), name: entry.name)
        default:
            throw ZipError.unsupportedMethod(entry.method, entry.name)
        }
        guard CRC32.checksum(out) == entry.crc32 else { throw ZipError.corrupt(entry.name) }
        return out
    }

    /// Extracts entries into `directory`, streaming large ones from a local
    /// archive. `filter` picks entries; `progress` sees uncompressed bytes.
    public func extract(
        to directory: URL,
        filter: (ZipEntry) -> Bool = { _ in true },
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        let root = directory.standardizedFileURL
        let selected = entries.filter(filter)
        let total = selected.reduce(Int64(0)) { $0 + $1.uncompressedSize }
        var done: Int64 = 0
        for entry in selected {
            let target = try Self.safeTarget(for: entry.name, in: root)
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let local = source as? LocalFileSource, entry.uncompressedSize > 8 << 20 {
                try await streamExtract(entry, from: local, to: target)
            } else {
                let d = try await data(of: entry)
                try d.write(to: target)
            }
            // Keep the executable bit if the archive recorded unix modes.
            let mode = (entry.externalAttributes >> 16) & 0o777
            if mode & 0o111 != 0 { try? fm.setAttributes([.posixPermissions: NSNumber(value: mode | 0o600)], ofItemAtPath: target.path) }
            done += entry.uncompressedSize
            progress?(done, total)
        }
    }

    static func safeTarget(for name: String, in root: URL) throws -> URL {
        let cleaned = name.replacingOccurrences(of: "\\", with: "/")
        let parts = cleaned.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.contains(".."), !cleaned.hasPrefix("/") else { throw ZipError.unsafePath(name) }
        var url = root
        for part in parts { url.appendPathComponent(part) }
        return url
    }

    private func streamExtract(_ entry: ZipEntry, from local: LocalFileSource, to target: URL) async throws {
        guard !entry.isEncrypted else { throw ZipError.encrypted(entry.name) }
        let range = try await dataRange(of: entry)
        let input = try FileHandle(forReadingFrom: local.url)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(range.lowerBound))
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var crc = CRC32()
        var remaining: Int64 = range.upperBound - range.lowerBound
        let chunk = 4 << 20

        switch entry.method {
        case 0:
            while remaining > 0 {
                let d = try input.read(upToCount: min(chunk, Int(remaining))) ?? Data()
                guard !d.isEmpty else { throw ZipError.truncated }
                crc.update(d)
                try output.write(contentsOf: d)
                remaining -= Int64(d.count)
            }
        case 8:
            let inflater = try Inflater()
            while remaining > 0 {
                let d = try input.read(upToCount: min(chunk, Int(remaining))) ?? Data()
                guard !d.isEmpty else { throw ZipError.truncated }
                remaining -= Int64(d.count)
                let out = try inflater.process(d, final: remaining == 0)
                crc.update(out)
                try output.write(contentsOf: out)
            }
        default:
            throw ZipError.unsupportedMethod(entry.method, entry.name)
        }
        guard crc.value == entry.crc32 else { throw ZipError.corrupt(entry.name) }
    }
}

/// Raw DEFLATE through the Compression framework (its ZLIB algorithm is
/// headerless deflate, exactly what zip stores).
final class Inflater {
    private var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
    private var finished = false
    private let bufferSize = 1 << 20
    private let buffer: UnsafeMutablePointer<UInt8>

    init() throws {
        buffer = .allocate(capacity: bufferSize)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            buffer.deallocate()
            throw ZipError.unsupportedMethod(8, "deflate stream")
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        buffer.deallocate()
    }

    func process(_ input: Data, final: Bool) throws -> Data {
        var out = Data()
        guard !finished else { return out }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self)
            stream.src_ptr = base.baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = base.count
            let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            // Keep calling until the decoder has nothing more to give: on the
            // last chunk that means END, otherwise input used up with room
            // to spare in the output buffer.
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let before = stream.src_size
                let status = compression_stream_process(&stream, flags)
                let produced = bufferSize - stream.dst_size
                out.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END { finished = true; break }
                guard status == COMPRESSION_STATUS_OK else { throw ZipError.corrupt("deflate stream") }
                if !final, stream.src_size == 0, stream.dst_size > 0 { break }
                if produced == 0, stream.src_size == before {
                    // No progress: truncated input on the final chunk.
                    if final { throw ZipError.truncated }
                    break
                }
            }
        }
        return out
    }

    static func inflate(_ data: Data, expectedSize: Int, name: String) throws -> Data {
        if expectedSize == 0 { return Data() }
        let inflater = try Inflater()
        let out = try inflater.process(data, final: true)
        guard out.count == expectedSize else { throw ZipError.corrupt(name) }
        return out
    }
}

/// CRC-32 (IEEE), slicing-by-4.
struct CRC32 {
    private static let tables: [[UInt32]] = {
        var t = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 4)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            t[0][i] = c
        }
        for i in 0..<256 {
            for k in 1..<4 { t[k][i] = (t[k - 1][i] >> 8) ^ t[0][Int(t[k - 1][i] & 0xFF)] }
        }
        return t
    }()

    private var crc: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { crc ^ 0xFFFF_FFFF }

    mutating func update(_ data: Data) {
        let t0 = Self.tables[0], t1 = Self.tables[1], t2 = Self.tables[2], t3 = Self.tables[3]
        var c = crc
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = p.count
            while i + 4 <= n {
                c ^= UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
                c = t3[Int(c & 0xFF)] ^ t2[Int((c >> 8) & 0xFF)] ^ t1[Int((c >> 16) & 0xFF)] ^ t0[Int(c >> 24)]
                i += 4
            }
            while i < n {
                c = t0[Int((c ^ UInt32(p[i])) & 0xFF)] ^ (c >> 8)
                i += 1
            }
        }
        crc = c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.value
    }
}

enum CP437 {
    private static let high: [Character] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}"
    )

    static func character(_ b: UInt8) -> Character {
        b < 0x80 ? Character(UnicodeScalar(b)) : high[Int(b) - 0x80]
    }
}
