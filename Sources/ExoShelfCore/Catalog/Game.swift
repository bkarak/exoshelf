import Foundation

/// One title of a collection, as described by eXo's LaunchBox metadata.
public struct Game: Sendable, Codable, Hashable, Identifiable {
    /// The collection the game belongs to: `eXoDOS`, `eXoWin3x`, ...
    public let collection: String
    /// LaunchBox's GUID for the game.
    public let guid: String
    public let title: String
    public let sortTitle: String
    public let year: Int?
    public let developer: String
    public let publisher: String
    public let genres: [String]
    public let series: [String]
    /// eXo's feature playlists from the `Series` field: "Roland MT-32",
    /// "Sound Canvas", "3dfx" and so on.
    public let playlists: [String]
    public let notes: String
    public let maxPlayers: Int
    public let playMode: String
    public let source: String
    public let rating: String
    public let communityRating: Double
    /// eXo's short folder name, e.g. `DOOM`; the game unpacks into it.
    public let shortcode: String
    /// Base name of eXo's launcher, e.g. `DOOM (1993)`; the game's archive is
    /// `eXo/<collection>/<launcherName>.zip`.
    public let launcherName: String

    public init(collection: String, guid: String, title: String, sortTitle: String, year: Int?, developer: String,
                publisher: String, genres: [String], series: [String], playlists: [String], notes: String,
                maxPlayers: Int, playMode: String, source: String, rating: String, communityRating: Double,
                shortcode: String, launcherName: String) {
        self.collection = collection
        self.guid = guid
        self.title = title
        self.sortTitle = sortTitle
        self.year = year
        self.developer = developer
        self.publisher = publisher
        self.genres = genres
        self.series = series
        self.playlists = playlists
        self.notes = notes
        self.maxPlayers = maxPlayers
        self.playMode = playMode
        self.source = source
        self.rating = rating
        self.communityRating = communityRating
        self.shortcode = shortcode
        self.launcherName = launcherName
    }

    /// Unique across collections: a GUID is only promised unique within one.
    public var id: String { "\(collection):\(guid)" }

    public var archivePath: String { "eXo/\(collection)/\(launcherName).zip" }
    /// Folder of eXo's launch files for this game, relative to the library root.
    public var configFolder: String {
        "eXo/\(collection)/\(ExoCollection.named(collection)?.launcherFolder ?? "!dos")/\(shortcode)"
    }
    /// Folder the game unpacks into, relative to the library root.
    public var gameFolder: String { "eXo/\(collection)/\(shortcode)" }

    public var decade: Int? { year.map { $0 / 10 * 10 } }

    /// The lowercase text a search matches against.
    public var searchText: String {
        ([title, developer, publisher] + genres + series + [year.map(String.init) ?? ""]).joined(separator: " ").lowercased()
    }

    /// The same game with its archive (and, where eXo names the folder after
    /// the archive, its folder) spelled as the torrent spells it.
    func respelled(launcherName newName: String) -> Game {
        let folder = shortcode.caseInsensitiveCompare(launcherName) == .orderedSame ? newName : shortcode
        return Game(collection: collection, guid: guid, title: title, sortTitle: sortTitle, year: year, developer: developer,
                    publisher: publisher, genres: genres, series: series, playlists: playlists, notes: notes,
                    maxPlayers: maxPlayers, playMode: playMode, source: source, rating: rating,
                    communityRating: communityRating, shortcode: folder, launcherName: newName)
    }

    enum CodingKeys: String, CodingKey {
        case collection, guid = "id", title, sortTitle, year, developer, publisher, genres, series, playlists, notes
        case maxPlayers, playMode, source, rating, communityRating, shortcode, launcherName
    }

    /// Catalogues saved before ExoShelf knew more than one collection carry
    /// no collection; they are eXoDOS.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decodeIfPresent(String.self, forKey: .collection) ?? ExoCollection.exoDOS.id
        guid = try c.decode(String.self, forKey: .guid)
        title = try c.decode(String.self, forKey: .title)
        sortTitle = try c.decode(String.self, forKey: .sortTitle)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        developer = try c.decode(String.self, forKey: .developer)
        publisher = try c.decode(String.self, forKey: .publisher)
        genres = try c.decode([String].self, forKey: .genres)
        series = try c.decode([String].self, forKey: .series)
        playlists = try c.decode([String].self, forKey: .playlists)
        notes = try c.decode(String.self, forKey: .notes)
        maxPlayers = try c.decode(Int.self, forKey: .maxPlayers)
        playMode = try c.decode(String.self, forKey: .playMode)
        source = try c.decode(String.self, forKey: .source)
        rating = try c.decode(String.self, forKey: .rating)
        communityRating = try c.decode(Double.self, forKey: .communityRating)
        shortcode = try c.decode(String.self, forKey: .shortcode)
        launcherName = try c.decode(String.self, forKey: .launcherName)
    }
}

/// The parsed catalogue plus where it came from.
public struct Catalog: Sendable, Codable {
    public static let formatVersion = 1

    public var formatVersion: Int
    /// Nil in catalogues saved before there was more than one collection.
    public var collection: String?
    public var torrentInfoHash: String
    public var createdAt: Date
    public var games: [Game]

    public init(collection: String, torrentInfoHash: String, games: [Game]) {
        self.formatVersion = Self.formatVersion
        self.collection = collection
        self.torrentInfoHash = torrentInfoHash
        self.createdAt = Date()
        self.games = games
    }

    public var genres: [String] {
        Array(Set(games.flatMap(\.genres))).sorted()
    }

    /// The games whose archive is in the torrent. A catalogue path that
    /// differs from the torrent's only in case (three eXoScummVM titles) is
    /// respelled the torrent's way, since the archive's folder follows it.
    public static func keepingArchived(_ games: [Game], torrentPaths: some Sequence<String>) -> [Game] {
        var exact = Set<String>()
        var folded: [String: String] = [:]
        for p in torrentPaths {
            exact.insert(p)
            folded[p.lowercased()] = folded[p.lowercased()] ?? p
        }
        return games.compactMap { g in
            if exact.contains(g.archivePath) { return g }
            guard let actual = folded[g.archivePath.lowercased()] else { return nil }
            let name = String((actual as NSString).lastPathComponent.dropLast(4))
            return g.respelled(launcherName: name)
        }
    }
}

/// Streams one of eXo's LaunchBox platform files (`MS-DOS.xml` is ~37 MB)
/// into games.
public final class LaunchBoxParser: NSObject, XMLParserDelegate {
    private let collection: ExoCollection
    private var games: [Game] = []
    private var fields: [String: String] = [:]
    private var current: String?
    private var text = ""
    private var inGame = false

    init(collection: ExoCollection) {
        self.collection = collection
    }

    public static func parse(_ data: Data, collection: ExoCollection = .exoDOS) throws -> [Game] {
        let p = LaunchBoxParser(collection: collection)
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return p.games
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "Game" {
            inGame = true
            fields = [:]
        } else if inGame {
            current = name
            text = ""
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "Game" {
            inGame = false
            if let g = Self.game(from: fields, in: collection) { games.append(g) }
        } else if inGame, current == name {
            fields[name] = text
            current = nil
        }
    }

    static func game(from f: [String: String], in collection: ExoCollection) -> Game? {
        // Only real titles: eXo's own setup and update entries point
        // elsewhere. The folder names are compared ignoring case, because
        // most eXoWin3x rows say `eXoWin3X` where the torrent says `eXoWin3x`.
        let app = (f["ApplicationPath"] ?? "").replacingOccurrences(of: "\\", with: "/")
        let parts = app.split(separator: "/").map(String.init)
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        guard parts.count == 5, same(parts[0], "eXo"), same(parts[1], collection.id), same(parts[2], collection.launcherFolder),
              parts[4].lowercased().hasSuffix(".bat"), let id = f["ID"], let title = f["Title"] else { return nil }
        let launcher = String(parts[4].dropLast(4))
        let year = (f["ReleaseDate"]).flatMap { Int($0.prefix(4)) }
        let seriesAll = split(f["Series"])
        let playlists = seriesAll.filter { $0.hasPrefix("Playlist: ") }.map { String($0.dropFirst("Playlist: ".count)) }
        let series = seriesAll.filter { !$0.hasPrefix("Playlist: ") }
        let sort = (f["SortTitle"].flatMap { $0.isEmpty ? nil : $0 }) ?? sortKey(title)
        return Game(
            collection: collection.id,
            guid: id,
            title: title,
            sortTitle: sort,
            year: year,
            developer: f["Developer"] ?? "",
            publisher: f["Publisher"] ?? "",
            genres: split(f["Genre"]),
            series: series,
            playlists: playlists,
            notes: f["Notes"] ?? "",
            maxPlayers: Int(f["MaxPlayers"] ?? "") ?? 1,
            playMode: f["PlayMode"] ?? "",
            source: f["Source"] ?? "",
            rating: f["Rating"] ?? "",
            communityRating: Double(f["CommunityStarRating"] ?? "") ?? 0,
            shortcode: parts[3],
            launcherName: launcher
        )
    }

    private static func split(_ s: String?) -> [String] {
        (s ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "The Secret of Monkey Island" sorts under S, as on a shelf.
    static func sortKey(_ title: String) -> String {
        for article in ["The ", "A ", "An "] where title.hasPrefix(article) && title.count > article.count + 1 {
            return String(title.dropFirst(article.count)) + ", " + article.trimmingCharacters(in: .whitespaces)
        }
        return title
    }
}
