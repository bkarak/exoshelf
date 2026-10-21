import Foundation

/// Where each game's box art and screenshots sit inside eXo's metadata zip,
/// so they can be fetched one by one without re-reading its directory
/// (38,000 entries for eXoDOS). Keyed by the game's LaunchBox GUID.
public struct MediaIndex: Sendable, Codable {
    public static let formatVersion = 1

    public var formatVersion = Self.formatVersion
    public var archivePath: String
    public var covers: [String: ZipEntry] = [:]
    public var screenshots: [String: [ZipEntry]] = [:]

    public init(archivePath: String) {
        self.archivePath = archivePath
    }

    /// Matches LaunchBox's image names to games. LaunchBox names an image
    /// after the title with file-system-hostile characters turned into `_`,
    /// plus `-NN`, optionally inside a region folder, under
    /// `Images/<platform>/<kind>/`.
    public static func build(archivePath: String, entries: [ZipEntry], games: [Game], platforms: [String] = ["MS-DOS"]) -> MediaIndex {
        var index = MediaIndex(archivePath: archivePath)
        let kinds = ["Box - Front", "Screenshot - Game Title", "Screenshot - Gameplay"]
        var byKind: [String: [String: [(rank: Int, entry: ZipEntry)]]] = [:]
        var looseByKind: [String: [String: [(rank: Int, entry: ZipEntry)]]] = [:]

        for entry in entries where !entry.isDirectory {
            for kind in kinds {
                guard let prefix = platforms.lazy.map({ "Images/\($0)/\(kind)/" }).first(where: entry.name.hasPrefix) else { continue }
                let rest = entry.name.dropFirst(prefix.count)
                let parts = rest.split(separator: "/")
                guard let file = parts.last, parts.count <= 2 else { continue }
                guard let (base, number) = splitImageName(String(file)) else { continue }
                let region = parts.count == 2 ? String(parts[0]) : ""
                let rank = regionRank(region) * 100 + number
                byKind[kind, default: [:]][base.lowercased(), default: []].append((rank, entry))
                looseByKind[kind, default: [:]][looseKey(base), default: []].append((rank, entry))
            }
        }

        for game in games {
            let exact = sanitize(game.title).lowercased()
            let loose = looseKey(game.title)
            let looseNoYear = looseKey(stripYear(game.title))
            func find(_ kind: String) -> [ZipEntry] {
                let hits = byKind[kind]?[exact] ?? looseByKind[kind]?[loose] ?? looseByKind[kind]?[looseNoYear] ?? []
                return hits.sorted { $0.rank < $1.rank }.map(\.entry)
            }
            if let cover = find("Box - Front").first { index.covers[game.guid] = cover }
            let shots = find("Screenshot - Game Title").prefix(1) + find("Screenshot - Gameplay").prefix(4)
            if !shots.isEmpty { index.screenshots[game.guid] = Array(shots) }
        }
        return index
    }

    static func sanitize(_ title: String) -> String {
        let bad: Set<Character> = [":", "'", "/", "\\", "?", "*", "\"", "<", ">", "|"]
        return String(title.map { bad.contains($0) ? "_" : $0 })
    }

    static func looseKey(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func stripYear(_ title: String) -> String {
        guard let r = title.range(of: #" \(\d{4}\)$"#, options: .regularExpression) else { return title }
        return String(title[..<r.lowerBound])
    }

    /// `Akalabeth_ World of Doom-02.jpg` → ("Akalabeth_ World of Doom", 2).
    static func splitImageName(_ file: String) -> (String, Int)? {
        guard let dot = file.lastIndex(of: ".") else { return nil }
        let stem = file[..<dot]
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let num = stem[stem.index(after: dash)...]
        guard num.count == 2, let n = Int(num) else { return nil }
        return (String(stem[..<dash]), n)
    }

    /// Prefer the art eXo filed at the top level, then the regions an
    /// English-language shelf would show first.
    static func regionRank(_ region: String) -> Int {
        switch region {
        case "": return 0
        case "North America": return 1
        case "United States": return 2
        case "World": return 3
        case "Europe": return 4
        case "United Kingdom": return 5
        default: return 9
        }
    }
}
