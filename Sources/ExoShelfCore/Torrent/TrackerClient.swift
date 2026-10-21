import Foundation
import Network

public struct AnnounceRequest: Sendable {
    public var infoHash: Data
    public var peerID: Data
    public var port: UInt16
    public var downloaded: Int64
    public var left: Int64
    public var uploaded: Int64
    public var event: Event
    public var numWant: Int32 = 200

    public enum Event: Int32, Sendable {
        case none = 0, completed = 1, started = 2, stopped = 3
        var httpName: String? {
            switch self {
            case .none: return nil
            case .completed: return "completed"
            case .started: return "started"
            case .stopped: return "stopped"
            }
        }
    }
}

public struct AnnounceResponse: Sendable {
    public var interval: TimeInterval
    public var seeders: Int?
    public var leechers: Int?
    public var peers: [PeerAddress]
}

public enum TrackerError: Error, CustomStringConvertible {
    case unsupportedScheme(String)
    case failure(String)
    case malformed
    case timeout

    public var description: String {
        switch self {
        case .unsupportedScheme(let s): return "unsupported tracker scheme \(s)"
        case .failure(let s): return "tracker said: \(s)"
        case .malformed: return "malformed tracker response"
        case .timeout: return "tracker timed out"
        }
    }
}

public enum TrackerClient {
    public static func announce(_ url: String, _ request: AnnounceRequest) async throws -> AnnounceResponse {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased() else { throw TrackerError.malformed }
        switch scheme {
        case "udp": return try await UDPTracker(url: u).announce(request)
        case "http", "https": return try await httpAnnounce(u, request)
        default: throw TrackerError.unsupportedScheme(scheme)
        }
    }

    static func httpAnnounce(_ url: URL, _ r: AnnounceRequest) async throws -> AnnounceResponse {
        // info_hash and peer_id are raw bytes; URLComponents would encode the
        // percent signs a second time, so the query is built by hand.
        var query = "info_hash=\(percentEncode(r.infoHash))&peer_id=\(percentEncode(r.peerID))"
        query += "&port=\(r.port)&uploaded=\(r.uploaded)&downloaded=\(r.downloaded)&left=\(r.left)"
        query += "&compact=1&no_peer_id=1&numwant=\(r.numWant)"
        if let e = r.event.httpName { query += "&event=\(e)" }
        var s = url.absoluteString
        s += s.contains("?") ? "&" : "?"
        s += query
        guard let full = URL(string: s) else { throw TrackerError.malformed }
        var req = URLRequest(url: full, timeoutInterval: 10)
        req.setValue("ExoShelf/0.1", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let v = try BencodeDecoder.decode(data)
        if let reason = v["failure reason"]?.string { throw TrackerError.failure(reason) }
        var peers: [PeerAddress] = []
        if let compact = v["peers"]?.data {
            peers += PeerAddress.parseCompact(compact)
        } else if let list = v["peers"]?.list {
            for p in list {
                if let ip = p["ip"]?.string, let port = p["port"]?.int, port > 0, port < 65536 {
                    peers.append(PeerAddress(host: ip, port: UInt16(port)))
                }
            }
        }
        if let six = v["peers6"]?.data { peers += PeerAddress.parseCompact6(six) }
        return AnnounceResponse(
            interval: TimeInterval(v["interval"]?.int ?? 1800),
            seeders: v["complete"]?.int.map(Int.init),
            leechers: v["incomplete"]?.int.map(Int.init),
            peers: peers
        )
    }

    static func percentEncode(_ data: Data) -> String {
        var out = ""
        for b in data {
            let c = Character(UnicodeScalar(b))
            if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || "-_.~".contains(c) {
                out.append(c)
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }
}

/// BEP 15. One short-lived UDP flow per announce; a connection id is not
/// cached because announces are minutes apart and ids live two minutes.
final class UDPTracker: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "exoshelf.udp-tracker")
    private var connection: NWConnection?
    private var pending: CheckedContinuation<Data, Error>?

    init(url: URL) throws {
        guard let host = url.host, let port = url.port else { throw TrackerError.malformed }
        self.host = host
        self.port = UInt16(port)
    }

    func announce(_ r: AnnounceRequest) async throws -> AnnounceResponse {
        // IPv4 only: the reply format depends on the transport's address
        // family, and a dual-stack tracker reached over IPv6 would answer with
        // 18-byte peers that the IPv4 parser misreads.
        let params = NWParameters.udp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        connection = conn
        conn.start(queue: queue)
        defer { conn.cancel() }

        let tid1 = UInt32.random(in: .min ... .max)
        var connect = Data()
        connect.appendUInt64(0x41727101980)
        connect.appendUInt32(0)
        connect.appendUInt32(tid1)
        let connReply = try await exchange(connect, expectAtLeast: 16)
        guard connReply.readUInt32(at: connReply.startIndex) == 0,
              connReply.readUInt32(at: connReply.startIndex + 4) == tid1 else {
            throw try errorOrMalformed(connReply)
        }
        let connectionID = connReply.readUInt64(at: connReply.startIndex + 8)

        let tid2 = UInt32.random(in: .min ... .max)
        var ann = Data()
        ann.appendUInt64(connectionID)
        ann.appendUInt32(1)
        ann.appendUInt32(tid2)
        ann.append(r.infoHash)
        ann.append(r.peerID)
        ann.appendUInt64(UInt64(r.downloaded))
        ann.appendUInt64(UInt64(r.left))
        ann.appendUInt64(UInt64(r.uploaded))
        ann.appendUInt32(UInt32(r.event.rawValue))
        ann.appendUInt32(0)
        ann.appendUInt32(UInt32.random(in: .min ... .max))
        ann.appendUInt32(UInt32(bitPattern: r.numWant))
        ann.appendUInt16(r.port)
        let reply = try await exchange(ann, expectAtLeast: 20)
        let b = reply.startIndex
        guard reply.readUInt32(at: b) == 1, reply.readUInt32(at: b + 4) == tid2 else {
            throw try errorOrMalformed(reply)
        }
        let interval = TimeInterval(reply.readUInt32(at: b + 8))
        let leechers = Int(reply.readUInt32(at: b + 12))
        let seeders = Int(reply.readUInt32(at: b + 16))
        let peers = PeerAddress.parseCompact(reply.subdata(in: (b + 20)..<reply.endIndex))
        return AnnounceResponse(interval: max(interval, 60), seeders: seeders, leechers: leechers, peers: peers)
    }

    private func errorOrMalformed(_ reply: Data) throws -> Error {
        if reply.count >= 8, reply.readUInt32(at: reply.startIndex) == 3 {
            let message = String(decoding: reply.dropFirst(8), as: UTF8.self)
            return TrackerError.failure(message)
        }
        return TrackerError.malformed
    }

    /// Sends a datagram and waits for the reply, retrying twice.
    private func exchange(_ packet: Data, expectAtLeast minimum: Int) async throws -> Data {
        for attempt in 0..<3 {
            do {
                let reply = try await sendOnce(packet, timeout: 3 + Double(attempt) * 2)
                if reply.count >= minimum || (reply.count >= 8 && reply.readUInt32(at: reply.startIndex) == 3) {
                    return reply
                }
            } catch TrackerError.timeout {
                continue
            }
        }
        throw TrackerError.timeout
    }

    private func sendOnce(_ packet: Data, timeout: TimeInterval) async throws -> Data {
        guard let conn = connection else { throw TrackerError.malformed }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            queue.async { [self] in
                pending = c
                conn.send(content: packet, completion: .contentProcessed { [weak self] error in
                    // Completions run on `queue`, like everything else here.
                    if let error { self?.finish(.failure(error)) }
                })
                conn.receiveMessage { [weak self] data, _, _, error in
                    if let error { self?.finish(.failure(error)) } else { self?.finish(.success(data ?? Data())) }
                }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(TrackerError.timeout))
                }
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let c = pending else { return }
        pending = nil
        c.resume(with: result)
    }
}
