import Foundation
import Testing
@testable import ExoShelfCore

@Suite struct TorrentTests {
    @Test func bencodeRoundTrip() throws {
        let v: BValue = .dict(["a": .int(-3), "b": .list([.bytes(Data("xy".utf8)), .int(0)]), "c": .dict(["z": .bytes(Data())])])
        let encoded = BencodeEncoder.encode(v)
        #expect(String(decoding: encoded, as: UTF8.self) == "d1:ai-3e1:bl2:xyi0ee1:cd1:z0:ee")
        #expect(try BencodeDecoder.decode(encoded) == v)
    }

    @Test func bencodeRejectsGarbage() {
        #expect(throws: BencodeError.self) { try BencodeDecoder.decode(Data("i12".utf8)) }
        #expect(throws: BencodeError.self) { try BencodeDecoder.decode(Data("5:abc".utf8)) }
        #expect(throws: BencodeError.self) { try BencodeDecoder.decode(Data("x".utf8)) }
    }

    @Test func parsesMultiFileTorrentAndInfoHash() throws {
        let pieceLength = 32
        let files: BValue = .list([
            .dict(["length": .int(40), "path": .list([.bytes(Data("eXo".utf8)), .bytes(Data("a.zip".utf8))])]),
            .dict(["length": .int(30), "path": .list([.bytes(Data("b.zip".utf8))])]),
        ])
        let info: BValue = .dict(["name": .bytes(Data("eXoDOS".utf8)), "piece length": .int(Int64(pieceLength)), "pieces": .bytes(Data(count: 60)), "files": files])
        let torrent: BValue = .dict(["announce": .bytes(Data("udp://t:1/announce".utf8)), "info": info])
        let data = BencodeEncoder.encode(torrent)
        let meta = try TorrentMeta(data: data)
        #expect(meta.files.map(\.path) == ["eXo/a.zip", "b.zip"])
        #expect(meta.files[1].offset == 40)
        #expect(meta.pieceCount == 3)
        #expect(meta.size(ofPiece: 2) == 6)
        #expect(meta.pieces(covering: meta.files[1].byteRange) == 1...2)
        #expect(meta.trackers == [["udp://t:1/announce"]])
        // The info hash is taken over the info dictionary's exact bytes.
        let infoBytes = BencodeEncoder.encode(info)
        #expect(meta.infoHash.count == 20)
        #expect(meta.infoHashHex == sha1Hex(infoBytes))
    }

    @Test func wireMessagesRoundTrip() throws {
        let messages: [PeerMessage] = [
            .choke, .unchoke, .interested, .notInterested, .have(piece: 83163),
            .bitfield(Data([0xFF, 0x80])), .request(piece: 5, begin: 16384, length: 16384),
            .piece(piece: 7, begin: 0, block: Data([1, 2, 3])), .cancel(piece: 1, begin: 2, length: 3),
            .extended(id: 1, payload: Data("d5:added0:e".utf8)),
        ]
        for m in messages {
            let encoded = m.encoded()
            let length = Int(encoded.readUInt32(at: 0))
            #expect(length == encoded.count - 4)
            #expect(try PeerMessage.decode(encoded.dropFirst(4)) == m)
        }
    }

    @Test func handshakeRoundTrip() throws {
        let hs = Handshake(reserved: Handshake.ourReserved, infoHash: Data(repeating: 7, count: 20), peerID: Data("-XS0100-abcdefghijkl".utf8))
        let encoded = hs.encoded()
        #expect(encoded.count == 68)
        let back = try Handshake.decode(encoded)
        #expect(back == hs)
        #expect(back.supportsExtensions)
    }

    @Test func compactPeers() {
        let v4 = PeerAddress.parseCompact(Data([192, 0, 2, 1, 0x1A, 0xE1, 10, 0, 0, 1, 0, 80]))
        #expect(v4 == [PeerAddress(host: "192.0.2.1", port: 6881), PeerAddress(host: "10.0.0.1", port: 80)])
        #expect(v4[0].isRoutable)
        #expect(!v4[1].isRoutable)
        #expect(!PeerAddress(host: "192.168.1.5", port: 1).isRoutable)
        #expect(!PeerAddress(host: "172.20.0.1", port: 1).isRoutable)
        #expect(PeerAddress(host: "172.32.0.1", port: 1).isRoutable)
    }

    @Test func bitfieldMasksSpareBits() throws {
        let b = try #require(Bitfield(count: 10, data: Data([0xFF, 0xFF])))
        #expect(b.setCount == 10)
        #expect(b[9])
        #expect(!b[10])
        #expect(Bitfield(count: 10, data: Data([0xFF])) == nil)
    }

    @Test func percentEncodesBinary() {
        #expect(TrackerClient.percentEncode(Data([0x00, 0x41, 0x7E, 0xFF, 0x2D])) == "%00A~%FF-")
    }

    private func sha1Hex(_ d: Data) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try? p.run()
        input.fileHandleForWriting.write(d)
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        return String(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(40))
    }
}
