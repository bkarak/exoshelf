import CryptoKit
import Foundation

/// One file inside a multi-file torrent, placed in the torrent's single
/// concatenated byte stream.
public struct TorrentFile: Sendable, Hashable {
    public let index: Int
    /// Path relative to the torrent's root folder, `/`-separated.
    public let path: String
    public let length: Int64
    /// Byte offset of the file in the concatenated stream.
    public let offset: Int64

    public var byteRange: Range<Int64> { offset..<(offset + length) }
}

public enum TorrentMetaError: Error, CustomStringConvertible {
    case notADictionary
    case missing(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .notADictionary: return "The torrent file is not a bencoded dictionary."
        case .missing(let key): return "The torrent file has no '\(key)'."
        case .unsupported(let what): return "Unsupported torrent: \(what)."
        }
    }
}

/// The parts of a .torrent file the downloader needs. Only v1 torrents are
/// supported; eXo's torrents are made with qBittorrent in v1 mode.
public struct TorrentMeta: Sendable {
    public let name: String
    public let infoHash: Data
    public let pieceLength: Int
    public let pieceCount: Int
    public let totalLength: Int64
    public let files: [TorrentFile]
    /// Announce URLs grouped by tier, as in BEP 12.
    public let trackers: [[String]]
    public let comment: String?
    private let pieceHashes: Data

    public init(data: Data) throws {
        var decoder = BencodeDecoder(data)
        let root = try decoder.decode()
        guard case .dict(let top) = root else { throw TorrentMetaError.notADictionary }
        guard let info = top["info"]?.dict, let infoRange = decoder.rawRanges["info"] else {
            throw TorrentMetaError.missing("info")
        }
        if info["meta version"]?.int == 2, info["pieces"] == nil {
            throw TorrentMetaError.unsupported("v2-only torrent")
        }
        guard let pieceLength = info["piece length"]?.int, pieceLength > 0 else {
            throw TorrentMetaError.missing("piece length")
        }
        guard let pieces = info["pieces"]?.data, pieces.count % 20 == 0 else {
            throw TorrentMetaError.missing("pieces")
        }
        let name = info["name.utf-8"]?.string ?? info["name"]?.string ?? "torrent"

        var files: [TorrentFile] = []
        var offset: Int64 = 0
        if let list = info["files"]?.list {
            for (i, item) in list.enumerated() {
                guard let length = item["length"]?.int else { throw TorrentMetaError.missing("files[\(i)].length") }
                let parts = (item["path.utf-8"]?.list ?? item["path"]?.list ?? []).compactMap(\.string)
                // BEP 47 padding files hold no data of their own.
                let isPad = (item["attr"]?.string ?? "").contains("p")
                if !isPad {
                    files.append(TorrentFile(index: files.count, path: parts.joined(separator: "/"), length: length, offset: offset))
                }
                offset += length
            }
        } else if let length = info["length"]?.int {
            files.append(TorrentFile(index: 0, path: name, length: length, offset: 0))
            offset = length
        } else {
            throw TorrentMetaError.missing("files")
        }

        var tiers: [[String]] = []
        if let list = top["announce-list"]?.list {
            for tier in list {
                let urls = (tier.list ?? []).compactMap(\.string).filter { !$0.isEmpty }
                if !urls.isEmpty { tiers.append(urls) }
            }
        }
        if let announce = top["announce"]?.string, !tiers.flatMap({ $0 }).contains(announce) {
            tiers.insert([announce], at: 0)
        }

        let infoBytes = data.subdata(in: (data.startIndex + infoRange.lowerBound)..<(data.startIndex + infoRange.upperBound))
        self.infoHash = Data(Insecure.SHA1.hash(data: infoBytes))
        self.name = name
        self.pieceLength = Int(pieceLength)
        self.pieceHashes = pieces
        self.pieceCount = pieces.count / 20
        self.totalLength = offset
        self.files = files
        self.trackers = tiers
        self.comment = top["comment"]?.string

        let expected = (offset + pieceLength - 1) / pieceLength
        guard expected == Int64(pieceCount) else {
            throw TorrentMetaError.unsupported("\(pieceCount) piece hashes for \(expected) pieces")
        }
    }

    public var infoHashHex: String { infoHash.map { String(format: "%02x", $0) }.joined() }

    public func hash(ofPiece index: Int) -> Data {
        let start = pieceHashes.startIndex + index * 20
        return pieceHashes.subdata(in: start..<(start + 20))
    }

    public func size(ofPiece index: Int) -> Int {
        if index == pieceCount - 1 {
            let rest = Int(totalLength - Int64(index) * Int64(pieceLength))
            return rest
        }
        return pieceLength
    }

    public func offset(ofPiece index: Int) -> Int64 { Int64(index) * Int64(pieceLength) }

    /// Pieces that hold any byte of `range` in the concatenated stream.
    public func pieces(covering range: Range<Int64>) -> ClosedRange<Int>? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= totalLength else { return nil }
        let first = Int(range.lowerBound / Int64(pieceLength))
        let last = Int((range.upperBound - 1) / Int64(pieceLength))
        return first...last
    }

    public func file(atPath path: String) -> TorrentFile? {
        files.first { $0.path == path }
    }

    /// Case-insensitive suffix match, for paths that eXo spells inconsistently.
    public func file(endingWith suffix: String) -> TorrentFile? {
        let lower = suffix.lowercased()
        return files.first { $0.path.lowercased().hasSuffix(lower) }
    }

    /// Files that share no piece with anything but themselves are cheap to
    /// fetch; the rest drag a neighbour's bytes along. Used to size downloads.
    public func downloadCost(of file: TorrentFile) -> Int64 {
        guard let pieces = pieces(covering: file.byteRange) else { return 0 }
        return Int64(pieces.count) * Int64(pieceLength)
    }
}
