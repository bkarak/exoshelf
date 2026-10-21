import Compression
import Foundation
import Testing
@testable import ExoShelfCore

@Suite struct ZipTests {
    @Test func crc32KnownVectors() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
        #expect(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    @Test func crc32IsIncremental() {
        let data = Data((0..<100_003).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var c = CRC32()
        c.update(data.prefix(7))
        c.update(data.dropFirst(7).prefix(50_000))
        c.update(data.dropFirst(50_007))
        #expect(c.value == CRC32.checksum(data))
    }

    @Test func inflateRoundTrip() throws {
        let original = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: ($0 / 7) &* 13 ^ $0 % 251) })
        let compressed = deflate(original)
        #expect(compressed.count < original.count)
        let out = try Inflater.inflate(compressed, expectedSize: original.count, name: "t")
        #expect(out == original)
    }

    @Test func inflateInChunks() throws {
        let original = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0 % 97 &+ $0 / 1000) })
        let compressed = deflate(original)
        let inflater = try Inflater()
        var out = Data()
        var i = 0
        while i < compressed.count {
            let n = min(65_536, compressed.count - i)
            out.append(try inflater.process(compressed.subdata(in: i..<(i + n)), final: i + n == compressed.count))
            i += n
        }
        #expect(out == original)
    }

    @Test func cp437Table() {
        #expect(CP437.character(0x80) == "Ç")
        #expect(CP437.character(0xFF) == "\u{00A0}")
        #expect(CP437.character(0x41) == "A")
    }

    @Test func readsZipMadeByInfoZip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exoshelf-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("GAME/SUB"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = Data((0..<10_000_000).map { UInt8(truncatingIfNeeded: $0 % 253 &* ($0 / 4096)) })
        try big.write(to: dir.appendingPathComponent("GAME/BIG.DAT"))
        try Data("@echo off\r\nimgmount d .\\eXoDOS\\GAME\\cd\\x.iso -t cdrom\r\n".utf8).write(to: dir.appendingPathComponent("GAME/run.bat"))
        try Data(repeating: 0x41, count: 10).write(to: dir.appendingPathComponent("GAME/SUB/stored.txt"))
        let zipURL = dir.appendingPathComponent("game.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-qr", zipURL.path, "GAME"]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)

        let zip = try await ZipArchive.open(try LocalFileSource(url: zipURL))
        #expect(zip.entries.contains { $0.name == "GAME/BIG.DAT" })
        let bat = try #require(zip.entry(named: "game/run.bat"))
        let text = String(decoding: try await zip.data(of: bat), as: UTF8.self)
        #expect(text.contains("imgmount"))

        let out = dir.appendingPathComponent("out")
        try await zip.extract(to: out)
        #expect(try Data(contentsOf: out.appendingPathComponent("GAME/BIG.DAT")) == big)
        #expect(try Data(contentsOf: out.appendingPathComponent("GAME/SUB/stored.txt")).count == 10)
    }

    @Test func rejectsPathTraversal() {
        let root = URL(fileURLWithPath: "/tmp/x")
        #expect(throws: ZipError.self) { try ZipArchive.safeTarget(for: "../evil", in: root) }
        #expect(throws: ZipError.self) { try ZipArchive.safeTarget(for: "a/../../evil", in: root) }
        #expect(throws: ZipError.self) { try ZipArchive.safeTarget(for: "/etc/passwd", in: root) }
        #expect((try? ZipArchive.safeTarget(for: "GAME\\run.bat", in: root).path) == "/tmp/x/GAME/run.bat")
    }

    private func deflate(_ data: Data) -> Data {
        let capacity = data.count + 4096
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { raw in
            compression_encode_buffer(dst, capacity, raw.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(bytes: dst, count: n)
    }
}
