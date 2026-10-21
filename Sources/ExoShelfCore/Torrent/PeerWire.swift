import Foundation

/// Messages of the peer wire protocol (BEP 3), plus the extension protocol
/// (BEP 10) and the fast-extension messages a peer may send anyway.
public enum PeerMessage: Sendable, Equatable {
    case keepAlive
    case choke
    case unchoke
    case interested
    case notInterested
    case have(piece: Int)
    case bitfield(Data)
    case request(piece: Int, begin: Int, length: Int)
    case piece(piece: Int, begin: Int, block: Data)
    case cancel(piece: Int, begin: Int, length: Int)
    case port(UInt16)
    case suggest(piece: Int)
    case haveAll
    case haveNone
    case reject(piece: Int, begin: Int, length: Int)
    case allowedFast(piece: Int)
    case extended(id: UInt8, payload: Data)
    case unknown(id: UInt8)

    public func encoded() -> Data {
        var out = Data()
        func header(_ length: Int, _ id: UInt8) {
            out.appendUInt32(UInt32(length))
            out.append(id)
        }
        switch self {
        case .keepAlive:
            out.appendUInt32(0)
        case .choke: header(1, 0)
        case .unchoke: header(1, 1)
        case .interested: header(1, 2)
        case .notInterested: header(1, 3)
        case .have(let piece):
            header(5, 4); out.appendUInt32(UInt32(piece))
        case .bitfield(let bits):
            header(1 + bits.count, 5); out.append(bits)
        case .request(let piece, let begin, let length):
            header(13, 6); out.appendUInt32(UInt32(piece)); out.appendUInt32(UInt32(begin)); out.appendUInt32(UInt32(length))
        case .piece(let piece, let begin, let block):
            header(9 + block.count, 7); out.appendUInt32(UInt32(piece)); out.appendUInt32(UInt32(begin)); out.append(block)
        case .cancel(let piece, let begin, let length):
            header(13, 8); out.appendUInt32(UInt32(piece)); out.appendUInt32(UInt32(begin)); out.appendUInt32(UInt32(length))
        case .port(let port):
            header(3, 9); out.append(UInt8(port >> 8)); out.append(UInt8(port & 0xFF))
        case .suggest(let piece):
            header(5, 0x0D); out.appendUInt32(UInt32(piece))
        case .haveAll: header(1, 0x0E)
        case .haveNone: header(1, 0x0F)
        case .reject(let piece, let begin, let length):
            header(13, 0x10); out.appendUInt32(UInt32(piece)); out.appendUInt32(UInt32(begin)); out.appendUInt32(UInt32(length))
        case .allowedFast(let piece):
            header(5, 0x11); out.appendUInt32(UInt32(piece))
        case .extended(let id, let payload):
            header(2 + payload.count, 20); out.append(id); out.append(payload)
        case .unknown(let id):
            header(1, id)
        }
        return out
    }

    /// Parses one message body (the bytes after the 4-byte length prefix).
    public static func decode(_ body: Data) throws -> PeerMessage {
        guard let id = body.first else { return .keepAlive }
        let rest = body.dropFirst()
        func u32(_ at: Int) throws -> Int {
            guard rest.count >= at + 4 else { throw PeerWireError.malformed(id: id) }
            return Int(rest.readUInt32(at: rest.startIndex + at))
        }
        switch id {
        case 0: return .choke
        case 1: return .unchoke
        case 2: return .interested
        case 3: return .notInterested
        case 4: return .have(piece: try u32(0))
        case 5: return .bitfield(Data(rest))
        case 6: return .request(piece: try u32(0), begin: try u32(4), length: try u32(8))
        case 7:
            guard rest.count >= 8 else { throw PeerWireError.malformed(id: id) }
            return .piece(piece: try u32(0), begin: try u32(4), block: Data(rest.dropFirst(8)))
        case 8: return .cancel(piece: try u32(0), begin: try u32(4), length: try u32(8))
        case 9:
            guard rest.count >= 2 else { throw PeerWireError.malformed(id: id) }
            let p = rest.startIndex
            return .port(UInt16(rest[p]) << 8 | UInt16(rest[p + 1]))
        case 0x0D: return .suggest(piece: try u32(0))
        case 0x0E: return .haveAll
        case 0x0F: return .haveNone
        case 0x10: return .reject(piece: try u32(0), begin: try u32(4), length: try u32(8))
        case 0x11: return .allowedFast(piece: try u32(0))
        case 20:
            guard let ext = rest.first else { throw PeerWireError.malformed(id: id) }
            return .extended(id: ext, payload: Data(rest.dropFirst()))
        default: return .unknown(id: id)
        }
    }
}

public enum PeerWireError: Error, CustomStringConvertible {
    case malformed(id: UInt8)
    case badHandshake
    case wrongInfoHash
    case messageTooLarge(Int)
    case closed
    case timeout

    public var description: String {
        switch self {
        case .malformed(let id): return "malformed peer message \(id)"
        case .badHandshake: return "bad handshake"
        case .wrongInfoHash: return "peer serves another torrent"
        case .messageTooLarge(let n): return "peer message of \(n) bytes"
        case .closed: return "connection closed"
        case .timeout: return "timed out"
        }
    }
}

/// The 68-byte opening exchange.
public struct Handshake: Sendable, Equatable {
    public static let protocolName = Data("BitTorrent protocol".utf8)
    public static let length = 68

    public var reserved: Data
    public var infoHash: Data
    public var peerID: Data

    public init(reserved: Data, infoHash: Data, peerID: Data) {
        self.reserved = reserved
        self.infoHash = infoHash
        self.peerID = peerID
    }

    /// Our reserved bytes: only the extension protocol bit (BEP 10). We do
    /// not set the fast-extension bit, so peers must not send have-all,
    /// reject and friends; we still parse them if they do.
    public static var ourReserved: Data {
        var r = Data(repeating: 0, count: 8)
        r[5] = 0x10
        return r
    }

    public var supportsExtensions: Bool { reserved.count == 8 && reserved[reserved.startIndex + 5] & 0x10 != 0 }

    public func encoded() -> Data {
        var out = Data()
        out.append(UInt8(Self.protocolName.count))
        out.append(Self.protocolName)
        out.append(reserved)
        out.append(infoHash)
        out.append(peerID)
        return out
    }

    public static func decode(_ data: Data) throws -> Handshake {
        guard data.count >= length else { throw PeerWireError.badHandshake }
        let b = data.startIndex
        guard data[b] == 19, data.subdata(in: (b + 1)..<(b + 20)) == protocolName else { throw PeerWireError.badHandshake }
        return Handshake(
            reserved: data.subdata(in: (b + 20)..<(b + 28)),
            infoHash: data.subdata(in: (b + 28)..<(b + 48)),
            peerID: data.subdata(in: (b + 48)..<(b + 68))
        )
    }
}

/// An IPv4 or IPv6 peer endpoint.
public struct PeerAddress: Sendable, Hashable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// Compact peer list from trackers and PEX: 6 bytes per IPv4 peer.
    public static func parseCompact(_ data: Data) -> [PeerAddress] {
        var out: [PeerAddress] = []
        let bytes = [UInt8](data)
        var i = 0
        while i + 6 <= bytes.count {
            let host = "\(bytes[i]).\(bytes[i + 1]).\(bytes[i + 2]).\(bytes[i + 3])"
            let port = UInt16(bytes[i + 4]) << 8 | UInt16(bytes[i + 5])
            if port != 0 { out.append(PeerAddress(host: host, port: port)) }
            i += 6
        }
        return out
    }

    /// 18 bytes per IPv6 peer (`peers6`, `added6`).
    public static func parseCompact6(_ data: Data) -> [PeerAddress] {
        var out: [PeerAddress] = []
        let bytes = [UInt8](data)
        var i = 0
        while i + 18 <= bytes.count {
            var groups: [String] = []
            for g in 0..<8 {
                let v = UInt16(bytes[i + g * 2]) << 8 | UInt16(bytes[i + g * 2 + 1])
                groups.append(String(v, radix: 16))
            }
            let port = UInt16(bytes[i + 16]) << 8 | UInt16(bytes[i + 17])
            if port != 0 { out.append(PeerAddress(host: groups.joined(separator: ":"), port: port)) }
            i += 18
        }
        return out
    }

    /// Addresses we never dial: connecting to a LAN address makes macOS ask
    /// for Local Network access, and loopback or unspecified hosts are noise.
    public var isRoutable: Bool {
        if host.contains(":") {
            let h = host.lowercased()
            return !(h == "0:0:0:0:0:0:0:1" || h.hasPrefix("fe80") || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("0:0:0:0"))
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (100, 64...127): return false
        case (172, 16...31): return false
        case (224...255, _): return false
        default: return true
        }
    }
}

extension Data {
    mutating func appendUInt32(_ v: UInt32) {
        append(UInt8(truncatingIfNeeded: v >> 24))
        append(UInt8(truncatingIfNeeded: v >> 16))
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v))
    }

    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v))
    }

    mutating func appendUInt64(_ v: UInt64) {
        appendUInt32(UInt32(truncatingIfNeeded: v >> 32))
        appendUInt32(UInt32(truncatingIfNeeded: v))
    }

    /// Big-endian read at an absolute index.
    func readUInt32(at i: Index) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func readUInt16(at i: Index) -> UInt16 {
        UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    func readUInt64(at i: Index) -> UInt64 {
        UInt64(readUInt32(at: i)) << 32 | UInt64(readUInt32(at: i + 4))
    }

    /// Little-endian reads, for zip structures.
    func le16(_ i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }

    func le32(_ i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }

    func le64(_ i: Int) -> UInt64 {
        UInt64(le32(i)) | UInt64(le32(i + 4)) << 32
    }
}
