import Foundation

/// Receives verified pieces for one download job.
public protocol PieceSink: Sendable {
    func write(piece: Int, data: Data) async throws
}

/// Verified pieces kept on disk so that range reads (zip directories, box
/// art, the catalogue) and the pieces two neighbouring games share are
/// downloaded once. Files are named by piece index under the info hash.
public actor PieceCache {
    public let directory: URL
    private let maxBytes: Int64
    private var writesSinceTrim = 0

    public init(directory: URL, maxBytes: Int64 = 2 << 30) {
        self.directory = directory
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ piece: Int) -> URL { directory.appendingPathComponent("\(piece).piece") }

    public func has(_ piece: Int) -> Bool {
        FileManager.default.fileExists(atPath: url(piece).path)
    }

    public func read(_ piece: Int) -> Data? {
        let u = url(piece)
        guard let d = try? Data(contentsOf: u, options: .mappedIfSafe) else { return nil }
        // Touch it so trimming keeps recently used pieces.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return d
    }

    public func store(_ piece: Int, _ data: Data) {
        try? data.write(to: url(piece), options: .atomic)
        writesSinceTrim += 1
        if writesSinceTrim >= 32 {
            writesSinceTrim = 0
            trim()
        }
    }

    public var totalBytes: Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    public func clear() {
        for e in entries() { try? FileManager.default.removeItem(at: e.url) }
    }

    private func entries() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { u in
            guard u.pathExtension == "piece", let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
    }

    private func trim() {
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        all.sort { $0.date < $1.date }
        for e in all where total > maxBytes {
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }
}

/// Stores every piece in the cache; range reads assemble from there.
struct CacheSink: PieceSink {
    let cache: PieceCache
    func write(piece: Int, data: Data) async throws {
        await cache.store(piece, data)
    }
}

/// Writes the part of each piece that belongs to one file into `<file>.part`,
/// recording finished pieces next to it so an interrupted download resumes.
/// Pieces that spill into a neighbouring file also go to the cache: the
/// neighbour will want them.
actor FileSink: PieceSink {
    let file: TorrentFile
    let pieceLength: Int64
    let partURL: URL
    let stateURL: URL
    let cache: PieceCache
    private var handle: FileHandle?
    private(set) var done: Set<Int>

    init(file: TorrentFile, pieceLength: Int, destination: URL, cache: PieceCache) throws {
        self.file = file
        self.pieceLength = Int64(pieceLength)
        self.partURL = destination.appendingPathExtension("part")
        self.stateURL = destination.appendingPathExtension("part-pieces")
        self.cache = cache
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: partURL.path),
           let data = try? Data(contentsOf: stateURL),
           let list = try? JSONDecoder().decode([Int].self, from: data) {
            done = Set(list)
        } else {
            done = []
            fm.createFile(atPath: partURL.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: partURL)
        // Sparse on APFS: the full length costs nothing until written.
        try h.truncate(atOffset: UInt64(file.length))
        handle = h
    }

    func write(piece: Int, data: Data) async throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        let pieceStart = Int64(piece) * pieceLength
        let pieceEnd = pieceStart + Int64(data.count)
        let start = max(pieceStart, file.offset)
        let end = min(pieceEnd, file.offset + file.length)
        guard start < end else { return }
        let slice = data.subdata(in: Int(start - pieceStart)..<Int(end - pieceStart))
        try handle.seek(toOffset: UInt64(start - file.offset))
        try handle.write(contentsOf: slice)
        if pieceStart < file.offset || pieceEnd > file.offset + file.length {
            await cache.store(piece, data)
        }
        done.insert(piece)
        if let json = try? JSONEncoder().encode(done.sorted()) {
            try? json.write(to: stateURL, options: .atomic)
        }
    }

    /// Moves the finished file into place.
    func finish(to destination: URL) throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: partURL, to: destination)
        try? fm.removeItem(at: stateURL)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
