import CryptoKit
import Foundation
import os

/// Progress of one download job, delivered about once a second.
public struct TransferProgress: Sendable, Equatable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    /// Session-wide download rate in bytes per second.
    public var bytesPerSecond: Double
    public var connectedPeers: Int
    public var unchokedPeers: Int
    public var knownPeers: Int

    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}

public struct SessionStats: Sendable, Equatable {
    public var connectedPeers: Int
    public var unchokedPeers: Int
    public var knownPeers: Int
    public var bytesPerSecond: Double
    public var downloadedBytes: Int64
    public var activeJobs: Int
}

public enum TorrentSessionError: Error, CustomStringConvertible {
    case outOfRange
    case cancelled
    case sink(String)

    public var description: String {
        switch self {
        case .outOfRange: return "byte range outside the torrent"
        case .cancelled: return "download cancelled"
        case .sink(let s): return "could not store downloaded data: \(s)"
        }
    }
}

/// A leeching BitTorrent client for one torrent, built for fetching chosen
/// files and byte ranges out of a very large torrent. It dials out only and
/// never uploads, finds peers through trackers and PEX, requests 16 KiB
/// blocks from every unchoked peer, and verifies each piece against its
/// SHA-1 before a sink sees it.
public actor TorrentSession {
    public let meta: TorrentMeta
    public let cache: PieceCache
    let peerID: Data
    private let log = Logger(subsystem: "exoshelf", category: "torrent")

    public var maxPeers = 55
    private let maxConnecting = 16
    private let maxActivePieces = 16
    private static let blockSize = 16 * 1024

    // Peers
    private var peers: [Int: Peer] = [:]
    private var nextPeerKey = 0
    private var candidates: [PeerAddress: Candidate] = [:]
    private var connecting: Set<PeerAddress> = []
    private var banned: Set<PeerAddress> = []

    // Pieces
    private var jobs: [Int: Job] = [:]
    private var nextJobID = 0
    private var active: [Int: ActivePiece] = [:]
    private var verifying: Set<Int> = []
    private var strikes: [PeerAddress: Int] = [:]

    // Trackers
    private var trackers: [TrackerState]
    private var announcedOnce = false

    // Accounting
    private var downloaded: Int64 = 0
    private var rateWindow: [(Date, Int64)] = []
    private var lastJobAt = Date()
    private var ticker: Task<Void, Never>?

    public init(meta: TorrentMeta, cacheDirectory: URL, cacheBytes: Int64 = 2 << 30) {
        self.meta = meta
        self.cache = PieceCache(directory: cacheDirectory.appendingPathComponent(meta.infoHashHex), maxBytes: cacheBytes)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var id = Data("-XS0100-".utf8)
        for _ in 0..<12 { id.append(UInt8(ascii: alphabet.randomElement()!.unicodeScalars.first!)) }
        self.peerID = id
        self.trackers = meta.trackers.flatMap { $0 }.map { TrackerState(url: $0) }
    }

    // MARK: - Public API

    /// Downloads one file of the torrent to `destination`. Resumes a
    /// previous `.part` file; returns once the file is complete and in place.
    public func download(
        file: TorrentFile,
        to destination: URL,
        priority: Int = 10,
        progress: (@Sendable (TransferProgress) -> Void)? = nil
    ) async throws {
        guard let range = meta.pieces(covering: file.byteRange) else {
            // An empty file: nothing to fetch.
            FileManager.default.createFile(atPath: destination.path, contents: Data())
            return
        }
        let sink = try FileSink(file: file, pieceLength: meta.pieceLength, destination: destination, cache: cache)
        let already = await sink.done
        var needed: [Int] = []
        for p in range where !already.contains(p) {
            if let cached = await cache.read(p), cached.count == meta.size(ofPiece: p) {
                try await sink.write(piece: p, data: cached)
            } else {
                needed.append(p)
            }
        }
        let alreadyBytes = bytes(of: file.byteRange, inPieces: Set(range).subtracting(needed))
        do {
            try await run(pieces: needed, sink: sink, priority: priority, range: file.byteRange, startBytes: alreadyBytes, progress: progress)
            try await sink.finish(to: destination)
        } catch {
            await sink.close()
            throw error
        }
    }

    /// Reads bytes `range` of the torrent's concatenated data, fetching the
    /// pieces that hold them into the cache first.
    public func read(_ range: Range<Int64>, priority: Int = 0) async throws -> Data {
        guard let pieceRange = meta.pieces(covering: range) else {
            if range.isEmpty { return Data() }
            throw TorrentSessionError.outOfRange
        }
        var needed: [Int] = []
        for p in pieceRange where !(await cache.has(p)) { needed.append(p) }
        if !needed.isEmpty {
            try await run(pieces: needed, sink: CacheSink(cache: cache), priority: priority, range: range, startBytes: 0, progress: nil)
        }
        var out = Data()
        out.reserveCapacity(Int(range.count))
        for p in pieceRange {
            guard let data = await cache.read(p) else {
                // Evicted between fetch and read (a tiny cache); fetch again.
                return try await read(range, priority: priority)
            }
            let pieceStart = meta.offset(ofPiece: p)
            let lo = Int(max(range.lowerBound, pieceStart) - pieceStart)
            let hi = Int(min(range.upperBound, pieceStart + Int64(data.count)) - pieceStart)
            out.append(data.subdata(in: lo..<hi))
        }
        return out
    }

    /// True when every piece holding `range` is already in the cache.
    public func isCached(_ range: Range<Int64>) async -> Bool {
        guard let pieceRange = meta.pieces(covering: range) else { return range.isEmpty }
        for p in pieceRange where !(await cache.has(p)) { return false }
        return true
    }

    public func stats() -> SessionStats {
        SessionStats(
            connectedPeers: peers.count,
            unchokedPeers: peers.values.filter { !$0.choked }.count,
            knownPeers: candidates.count,
            bytesPerSecond: rate(),
            downloadedBytes: downloaded,
            activeJobs: jobs.count
        )
    }

    /// Drops every connection; jobs in flight fail with `cancelled`.
    public func shutdown() {
        ticker?.cancel()
        ticker = nil
        for job in jobs.values { job.continuation?.resume(throwing: TorrentSessionError.cancelled) }
        jobs.removeAll()
        active.removeAll()
        for p in peers.values { p.connection.close() }
        peers.removeAll()
    }

    /// Adds peers from outside the trackers, e.g. a user-supplied address.
    public func addPeers(_ addresses: [PeerAddress]) {
        addCandidates(addresses)
    }

    // MARK: - Jobs

    private func run(
        pieces: [Int],
        sink: PieceSink,
        priority: Int,
        range: Range<Int64>,
        startBytes: Int64,
        progress: (@Sendable (TransferProgress) -> Void)?
    ) async throws {
        if pieces.isEmpty {
            progress?(TransferProgress(completedBytes: Int64(range.count), totalBytes: Int64(range.count), bytesPerSecond: rate(), connectedPeers: peers.count, unchokedPeers: 0, knownPeers: candidates.count))
            return
        }
        let id = nextJobID
        nextJobID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                    return
                }
                let job = Job(id: id, priority: priority, pieces: pieces, sink: sink, range: range, completedBytes: startBytes, progress: progress, continuation: c)
                jobs[id] = job
                lastJobAt = Date()
                startTicker()
                for peer in peers.values { updateInterest(peer) }
                for peer in peers.values { fill(peer) }
                connectMore()
                announceIfDue()
            }
        } onCancel: {
            Task { await self.cancelJob(id) }
        }
    }

    private func cancelJob(_ id: Int) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.continuation?.resume(throwing: CancellationError())
        job.continuation = nil
        dropUnwantedActivePieces()
    }

    private func failJob(_ id: Int, _ error: Error) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.continuation?.resume(throwing: error)
        job.continuation = nil
        dropUnwantedActivePieces()
    }

    private func isWanted(_ piece: Int) -> Bool {
        jobs.values.contains { $0.remaining.contains(piece) }
    }

    private func dropUnwantedActivePieces() {
        for (index, piece) in active where !isWanted(index) {
            for (peerKey, begins) in piece.requesters {
                guard let peer = peers[peerKey] else { continue }
                var cancels: [PeerMessage] = []
                for begin in begins {
                    peer.outstanding.removeValue(forKey: BlockKey(piece: index, begin: begin))
                    cancels.append(.cancel(piece: index, begin: begin, length: blockLength(piece: index, begin: begin)))
                }
                peer.connection.send(cancels)
            }
            active.removeValue(forKey: index)
        }
        for peer in peers.values { updateInterest(peer) }
    }

    /// Jobs in the order their pieces are served: priority, then age.
    private var orderedJobs: [Job] {
        jobs.values.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
    }

    // MARK: - Ticker

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
    }

    private func tick() {
        let now = Date()
        if jobs.isEmpty {
            // Idle: let peers go after a while; candidates are kept.
            if now.timeIntervalSince(lastJobAt) > 45, !peers.isEmpty {
                for p in peers.values { p.connection.close() }
                peers.removeAll()
            }
            return
        }
        lastJobAt = now

        for peer in peers.values {
            // Requests nobody answered: hand the blocks to someone else.
            let stale = peer.outstanding.filter { now.timeIntervalSince($0.value) > 25 }
            for (key, _) in stale {
                peer.outstanding.removeValue(forKey: key)
                active[key.piece]?.release(key.begin, by: peer.key)
            }
            if !stale.isEmpty { peer.pipeline = max(2, peer.pipeline / 2) }
            // Snubbed: unchoked and asked, but silent for a long time.
            if !peer.outstanding.isEmpty || !peer.choked, now.timeIntervalSince(peer.lastBlockAt) > 60, now.timeIntervalSince(peer.connectedAt) > 60 {
                drop(peer, reason: "snubbed")
                continue
            }
            // Choked and useless for minutes: free the slot.
            if peer.choked, now.timeIntervalSince(peer.connectedAt) > 120, now.timeIntervalSince(peer.lastBlockAt) > 120, peers.count >= maxPeers - 5 {
                drop(peer, reason: "choked too long")
                continue
            }
            peer.updateRate(now: now)
            let target = Int(peer.rate * 4 / Double(Self.blockSize)) + 4
            peer.pipeline = min(max(4, target), peer.maxRequests)
            if now.timeIntervalSince(peer.lastSentAt) > 90 {
                peer.lastSentAt = now
                peer.connection.send(.keepAlive)
            }
            fill(peer)
        }
        connectMore()
        announceIfDue()
        let r = rate()
        let stats = (peers.count, peers.values.filter { !$0.choked }.count, candidates.count)
        for job in jobs.values {
            job.progress?(TransferProgress(completedBytes: job.completedBytes, totalBytes: job.totalBytes, bytesPerSecond: r, connectedPeers: stats.0, unchokedPeers: stats.1, knownPeers: stats.2))
        }
    }

    private func rate() -> Double {
        let now = Date()
        rateWindow.removeAll { now.timeIntervalSince($0.0) > 5 }
        guard let first = rateWindow.first else { return 0 }
        let bytes = rateWindow.reduce(0) { $0 + $1.1 }
        return Double(bytes) / max(1, now.timeIntervalSince(first.0))
    }

    // MARK: - Trackers

    private func announceIfDue() {
        guard !jobs.isEmpty else { return }
        let now = Date()
        let hungry = peers.count < 15 && untriedCandidates() < 20
        for t in trackers where !t.inFlight {
            let due = now >= t.nextAnnounce || (hungry && t.lastSuccess.map { now.timeIntervalSince($0) > 120 } == true)
            guard due else { continue }
            t.inFlight = true
            let request = AnnounceRequest(
                infoHash: meta.infoHash, peerID: peerID, port: 6881,
                downloaded: downloaded, left: max(1, meta.totalLength - downloaded), uploaded: 0,
                event: t.announced ? .none : .started
            )
            let url = t.url
            Task { [weak self] in
                do {
                    let response = try await TrackerClient.announce(url, request)
                    await self?.trackerSucceeded(url, response)
                } catch {
                    await self?.trackerFailed(url, error)
                }
            }
        }
    }

    private func trackerSucceeded(_ url: String, _ response: AnnounceResponse) {
        guard let t = trackers.first(where: { $0.url == url }) else { return }
        t.inFlight = false
        t.announced = true
        t.failures = 0
        t.lastSuccess = Date()
        t.nextAnnounce = Date().addingTimeInterval(min(max(response.interval, 120), 1800))
        log.debug("tracker \(url, privacy: .public): \(response.peers.count) peers")
        addCandidates(response.peers)
        connectMore()
    }

    private func trackerFailed(_ url: String, _ error: Error) {
        guard let t = trackers.first(where: { $0.url == url }) else { return }
        t.inFlight = false
        t.failures += 1
        t.nextAnnounce = Date().addingTimeInterval(min(3600, 120 * pow(2, Double(min(t.failures, 5)))))
        log.debug("tracker \(url, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }

    // MARK: - Connections

    private func addCandidates(_ addresses: [PeerAddress]) {
        for a in addresses where a.isRoutable && !banned.contains(a) && candidates[a] == nil {
            candidates[a] = Candidate()
        }
    }

    private func untriedCandidates() -> Int {
        let now = Date()
        let connected = Set(peers.values.map(\.address))
        return candidates.filter { !connected.contains($0.key) && !connecting.contains($0.key) && $0.value.nextAttempt <= now }.count
    }

    private func connectMore() {
        guard !jobs.isEmpty else { return }
        let now = Date()
        let connected = Set(peers.values.map(\.address))
        var pool = candidates.filter { !connected.contains($0.key) && !connecting.contains($0.key) && $0.value.nextAttempt <= now }
            .map { ($0.key, $0.value.failures) }
        pool.shuffle()
        pool.sort { $0.1 < $1.1 }
        for (address, _) in pool {
            guard connecting.count < maxConnecting, peers.count + connecting.count < maxPeers else { break }
            connecting.insert(address)
            Task { [weak self] in await self?.dial(address) }
        }
    }

    private func dial(_ address: PeerAddress) async {
        let conn = PeerConnection(address: address)
        let ours = Handshake(reserved: Handshake.ourReserved, infoHash: meta.infoHash, peerID: peerID)
        do {
            let theirs = try await conn.open(ours: ours, timeout: 10)
            connecting.remove(address)
            guard theirs.infoHash == meta.infoHash else { throw PeerWireError.wrongInfoHash }
            guard theirs.peerID != peerID else { throw PeerWireError.badHandshake }
            guard !jobs.isEmpty, peers.count < maxPeers else {
                conn.close()
                return
            }
            candidates[address]?.failures = 0
            let peer = Peer(key: nextPeerKey, address: address, connection: conn, pieceCount: meta.pieceCount)
            nextPeerKey += 1
            peers[peer.key] = peer
            if theirs.supportsExtensions {
                let hello: BValue = .dict([
                    "m": .dict(["ut_pex": .int(1)]),
                    "v": .bytes(Data("ExoShelf 0.1".utf8)),
                    "reqq": .int(250),
                ])
                conn.send(.extended(id: 0, payload: BencodeEncoder.encode(hello)))
            }
            let key = peer.key
            Task { [weak self] in
                do {
                    for try await message in conn.messages {
                        await self?.handle(key, message)
                    }
                    await self?.closed(key, nil)
                } catch {
                    await self?.closed(key, error)
                }
            }
        } catch {
            connecting.remove(address)
            conn.close()
            if var c = candidates[address] {
                c.failures += 1
                c.nextAttempt = Date().addingTimeInterval(min(1800, 60 * pow(2, Double(min(c.failures, 5)))))
                candidates[address] = c
                if c.failures >= 6 { candidates.removeValue(forKey: address) }
            }
        }
    }

    private func closed(_ key: Int, _ error: Error?) {
        guard let peer = peers.removeValue(forKey: key) else { return }
        releaseRequests(of: peer)
        if var c = candidates[peer.address] {
            c.nextAttempt = Date().addingTimeInterval(90)
            candidates[peer.address] = c
        }
        connectMore()
    }

    private func drop(_ peer: Peer, reason: String) {
        log.debug("dropping \(peer.address.description, privacy: .public): \(reason, privacy: .public)")
        peers.removeValue(forKey: peer.key)
        releaseRequests(of: peer)
        peer.connection.close()
        if var c = candidates[peer.address] {
            c.failures += 1
            c.nextAttempt = Date().addingTimeInterval(300)
            candidates[peer.address] = c
        }
    }

    private func releaseRequests(of peer: Peer) {
        peer.outstanding.removeAll()
        for piece in active.values { piece.releaseAll(by: peer.key) }
    }

    // MARK: - Messages

    private func handle(_ key: Int, _ message: PeerMessage) {
        guard let peer = peers[key] else { return }
        switch message {
        case .keepAlive:
            break
        case .choke:
            peer.choked = true
            releaseRequests(of: peer)
        case .unchoke:
            peer.choked = false
            fill(peer)
        case .interested, .notInterested, .request, .cancel, .port, .suggest, .allowedFast, .unknown:
            break
        case .have(let index):
            peer.has.set(index)
            if !peer.interested, isWanted(index) { updateInterest(peer) }
            fill(peer)
        case .bitfield(let bits):
            guard let b = Bitfield(count: meta.pieceCount, data: bits) else {
                drop(peer, reason: "bad bitfield")
                return
            }
            peer.has = b
            updateInterest(peer)
        case .haveAll:
            peer.has = .full(count: meta.pieceCount)
            updateInterest(peer)
        case .haveNone:
            break
        case .reject(let index, let begin, _):
            let k = BlockKey(piece: index, begin: begin)
            peer.outstanding.removeValue(forKey: k)
            active[index]?.release(begin, by: key)
        case .piece(let index, let begin, let block):
            received(peer, index: index, begin: begin, block: block)
        case .extended(let id, let payload):
            extended(peer, id: id, payload: payload)
        }
    }

    private func extended(_ peer: Peer, id: UInt8, payload: Data) {
        guard let v = try? BencodeDecoder.decode(payload) else { return }
        if id == 0 {
            if let pex = v["m"]?["ut_pex"]?.int, pex > 0, pex < 256 { peer.pexID = UInt8(pex) }
            if let reqq = v["reqq"]?.int, reqq > 0 { peer.maxRequests = Int(min(reqq, 250)) }
            return
        }
        // We announced ut_pex as id 1; peers address us with our id.
        if id == 1 {
            var found: [PeerAddress] = []
            if let added = v["added"]?.data { found += PeerAddress.parseCompact(added) }
            if let added6 = v["added6"]?.data { found += PeerAddress.parseCompact6(added6) }
            addCandidates(found)
            connectMore()
        }
    }

    private func updateInterest(_ peer: Peer) {
        let wanted = jobs.values.contains { job in job.remaining.contains { peer.has[$0] } }
        if wanted != peer.interested {
            peer.interested = wanted
            peer.lastSentAt = Date()
            peer.connection.send(wanted ? .interested : .notInterested)
        }
    }

    private func blockLength(piece: Int, begin: Int) -> Int {
        min(Self.blockSize, meta.size(ofPiece: piece) - begin)
    }

    // MARK: - Scheduling

    /// Tops up the peer's request pipeline.
    private func fill(_ peer: Peer) {
        guard !peer.choked, peer.interested else { return }
        var requests: [PeerMessage] = []
        let now = Date()
        while peer.outstanding.count < peer.pipeline {
            guard let (index, begin) = nextBlock(for: peer) else { break }
            let length = blockLength(piece: index, begin: begin)
            peer.outstanding[BlockKey(piece: index, begin: begin)] = now
            active[index]?.markRequested(begin, by: peer.key)
            requests.append(.request(piece: index, begin: begin, length: length))
        }
        if !requests.isEmpty {
            peer.lastSentAt = now
            peer.connection.send(requests)
        }
    }

    private func nextBlock(for peer: Peer) -> (Int, Int)? {
        let order = orderedJobs
        // 1. Unrequested blocks of pieces already under way, highest priority first.
        let underway = active.keys.filter { peer.has[$0] }.sorted { rank($0, order) < rank($1, order) }
        for index in underway {
            if let begin = active[index]?.firstUnrequestedBlock() { return (index, begin) }
        }
        // 2. Start a new piece.
        if active.count < maxActivePieces {
            for job in order {
                for index in job.order where job.remaining.contains(index) && active[index] == nil && !verifying.contains(index) && peer.has[index] {
                    active[index] = ActivePiece(index: index, size: meta.size(ofPiece: index), blockSize: Self.blockSize)
                    if let begin = active[index]?.firstUnrequestedBlock() { return (index, begin) }
                }
            }
        }
        // 3. Endgame: nothing new left to start, so double up on blocks still
        //    in flight elsewhere; the first answer wins and the rest are cancelled.
        let unstarted = jobs.values.contains { job in job.remaining.contains { active[$0] == nil && !verifying.contains($0) } }
        if !unstarted {
            for index in underway {
                guard let piece = active[index] else { continue }
                if let begin = piece.endgameBlock(excluding: peer.key) { return (index, begin) }
            }
        }
        return nil
    }

    private func rank(_ piece: Int, _ order: [Job]) -> (Int, Int, Int) {
        for job in order where job.remaining.contains(piece) { return (job.priority, job.id, piece) }
        return (Int.max, Int.max, piece)
    }

    private func received(_ peer: Peer, index: Int, begin: Int, block: Data) {
        let key = BlockKey(piece: index, begin: begin)
        peer.outstanding.removeValue(forKey: key)
        let now = Date()
        peer.lastBlockAt = now
        peer.windowBytes += Int64(block.count)
        downloaded += Int64(block.count)
        if let last = rateWindow.last, now.timeIntervalSince(last.0) < 0.25 {
            rateWindow[rateWindow.count - 1].1 += Int64(block.count)
        } else {
            rateWindow.append((now, Int64(block.count)))
        }

        guard let piece = active[index], begin % Self.blockSize == 0, block.count == blockLength(piece: index, begin: begin) else {
            fill(peer)
            return
        }
        let blockIndex = begin / Self.blockSize
        piece.release(begin, by: peer.key)
        if piece.received[blockIndex] {
            fill(peer)
            return
        }
        piece.data.replaceSubrange(begin..<(begin + block.count), with: block)
        piece.received[blockIndex] = true
        piece.receivedCount += 1
        piece.contributors.insert(peer.address)
        // Endgame duplicates: tell the others to stop sending this block.
        for otherKey in piece.peersAsking(for: begin) {
            piece.release(begin, by: otherKey)
            if let other = peers[otherKey] {
                other.outstanding.removeValue(forKey: key)
                other.connection.send(.cancel(piece: index, begin: begin, length: block.count))
            }
        }

        if piece.receivedCount == piece.blockCount {
            active.removeValue(forKey: index)
            verifying.insert(index)
            let expected = meta.hash(ofPiece: index)
            let data = piece.data
            let contributors = piece.contributors
            Task.detached(priority: .userInitiated) { [weak self] in
                let ok = Data(Insecure.SHA1.hash(data: data)) == expected
                await self?.verified(index, data: data, ok: ok, contributors: contributors)
            }
        }
        fill(peer)
    }

    private func verified(_ index: Int, data: Data, ok: Bool, contributors: Set<PeerAddress>) {
        verifying.remove(index)
        guard ok else {
            log.info("piece \(index) failed its hash check")
            for address in contributors {
                strikes[address, default: 0] += 1
                if strikes[address, default: 0] >= 2 {
                    banned.insert(address)
                    candidates.removeValue(forKey: address)
                    if let peer = peers.values.first(where: { $0.address == address }) { drop(peer, reason: "sent bad data") }
                }
            }
            for peer in peers.values { fill(peer) }
            return
        }
        for job in jobs.values where job.remaining.contains(index) {
            job.remaining.remove(index)
            job.completedBytes += bytes(of: job.range, inPieces: [index])
            job.pendingWrites += 1
            let sink = job.sink
            let id = job.id
            Task { [weak self] in
                do {
                    try await sink.write(piece: index, data: data)
                    await self?.written(id, error: nil)
                } catch {
                    await self?.written(id, error: error)
                }
            }
        }
        for peer in peers.values {
            updateInterest(peer)
            fill(peer)
        }
    }

    private func written(_ id: Int, error: Error?) {
        guard let job = jobs[id] else { return }
        job.pendingWrites -= 1
        if let error {
            failJob(id, TorrentSessionError.sink(String(describing: error)))
            return
        }
        if job.remaining.isEmpty, job.pendingWrites == 0 {
            jobs.removeValue(forKey: id)
            job.progress?(TransferProgress(completedBytes: job.totalBytes, totalBytes: job.totalBytes, bytesPerSecond: rate(), connectedPeers: peers.count, unchokedPeers: peers.values.filter { !$0.choked }.count, knownPeers: candidates.count))
            job.continuation?.resume()
            job.continuation = nil
        }
    }

    /// How many bytes of `range` the given pieces hold.
    private func bytes(of range: Range<Int64>, inPieces pieces: Set<Int>) -> Int64 {
        var total: Int64 = 0
        for p in pieces {
            let start = meta.offset(ofPiece: p)
            let end = start + Int64(meta.size(ofPiece: p))
            let lo = max(start, range.lowerBound)
            let hi = min(end, range.upperBound)
            if hi > lo { total += hi - lo }
        }
        return total
    }
}

// MARK: - State types

private struct BlockKey: Hashable {
    let piece: Int
    let begin: Int
}

private struct Candidate {
    var failures = 0
    var nextAttempt = Date.distantPast
}

private final class TrackerState {
    let url: String
    var nextAnnounce = Date.distantPast
    var inFlight = false
    var announced = false
    var failures = 0
    var lastSuccess: Date?

    init(url: String) { self.url = url }
}

private final class Peer {
    let key: Int
    let address: PeerAddress
    let connection: PeerConnection
    var has: Bitfield
    var choked = true
    var interested = false
    var outstanding: [BlockKey: Date] = [:]
    var pipeline = 8
    var maxRequests = 128
    var pexID: UInt8?
    let connectedAt = Date()
    var lastBlockAt = Date()
    var lastSentAt = Date()
    var windowBytes: Int64 = 0
    var rate: Double = 0
    private var windowStart = Date()

    init(key: Int, address: PeerAddress, connection: PeerConnection, pieceCount: Int) {
        self.key = key
        self.address = address
        self.connection = connection
        self.has = Bitfield(count: pieceCount)
    }

    func updateRate(now: Date) {
        let span = now.timeIntervalSince(windowStart)
        guard span >= 2 else { return }
        let current = Double(windowBytes) / span
        rate = rate == 0 ? current : rate * 0.6 + current * 0.4
        windowBytes = 0
        windowStart = now
    }
}

private final class ActivePiece {
    let index: Int
    let blockCount: Int
    let blockSize: Int
    var data: Data
    var received: [Bool]
    var receivedCount = 0
    /// How many peers each block is currently requested from.
    private var askers: [UInt8]
    /// Blocks each peer has been asked for, by block offset.
    private(set) var requesters: [Int: Set<Int>] = [:]
    var contributors: Set<PeerAddress> = []
    /// No block below this index is free; keeps the scan short.
    private var hint = 0

    init(index: Int, size: Int, blockSize: Int) {
        self.index = index
        self.blockSize = blockSize
        self.blockCount = (size + blockSize - 1) / blockSize
        self.data = Data(count: size)
        self.received = Array(repeating: false, count: blockCount)
        self.askers = Array(repeating: 0, count: blockCount)
    }

    func firstUnrequestedBlock() -> Int? {
        var b = hint
        while b < blockCount {
            if !received[b] && askers[b] == 0 {
                hint = b
                return b * blockSize
            }
            b += 1
        }
        hint = blockCount
        return nil
    }

    func endgameBlock(excluding peer: Int) -> Int? {
        let mine = requesters[peer] ?? []
        for b in 0..<blockCount where !received[b] && askers[b] < 2 && !mine.contains(b * blockSize) {
            return b * blockSize
        }
        return nil
    }

    func markRequested(_ begin: Int, by peer: Int) {
        let b = begin / blockSize
        guard b < blockCount else { return }
        if requesters[peer, default: []].insert(begin).inserted { askers[b] += 1 }
    }

    func release(_ begin: Int, by peer: Int) {
        let b = begin / blockSize
        guard b < blockCount, requesters[peer]?.remove(begin) != nil else { return }
        askers[b] -= 1
        if askers[b] == 0, !received[b] { hint = min(hint, b) }
    }

    func releaseAll(by peer: Int) {
        guard let begins = requesters.removeValue(forKey: peer) else { return }
        for begin in begins {
            let b = begin / blockSize
            askers[b] -= 1
            if askers[b] == 0, !received[b] { hint = min(hint, b) }
        }
    }

    func peersAsking(for begin: Int) -> [Int] {
        requesters.compactMap { $0.value.contains(begin) ? $0.key : nil }
    }
}

private final class Job {
    let id: Int
    let priority: Int
    /// Pieces in the order they should be fetched.
    let order: [Int]
    var remaining: Set<Int>
    let sink: PieceSink
    let range: Range<Int64>
    let totalBytes: Int64
    var completedBytes: Int64
    var pendingWrites = 0
    let progress: (@Sendable (TransferProgress) -> Void)?
    var continuation: CheckedContinuation<Void, Error>?

    init(id: Int, priority: Int, pieces: [Int], sink: PieceSink, range: Range<Int64>, completedBytes: Int64, progress: (@Sendable (TransferProgress) -> Void)?, continuation: CheckedContinuation<Void, Error>) {
        self.id = id
        self.priority = priority
        self.order = pieces
        self.remaining = Set(pieces)
        self.sink = sink
        self.range = range
        self.totalBytes = Int64(range.count)
        self.completedBytes = completedBytes
        self.progress = progress
        self.continuation = continuation
    }
}
