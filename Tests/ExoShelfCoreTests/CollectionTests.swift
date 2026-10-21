import Foundation
import Testing
@testable import ExoShelfCore

@Suite struct CollectionTests {
    static let win3xXML = """
    <?xml version="1.0" standalone="yes"?>
    <LaunchBox>
      <Game>
        <ApplicationPath>eXo\\eXoWin3X\\!win3x\\3DMaze\\3D Maze (1991).bat</ApplicationPath>
        <ID>maze-id</ID>
        <Title>3D Maze</Title>
        <ReleaseDate>1991-01-01T00:00:00-06:00</ReleaseDate>
        <Genre>Puzzle; Strategy</Genre>
        <Platform>Windows 3x</Platform>
      </Game>
      <Game>
        <ApplicationPath>eXo\\eXoWin3x\\!win3x\\DiscHist\\Discover History (1997).bat</ApplicationPath>
        <ID>hist-id</ID>
        <Title>Discover History</Title>
      </Game>
      <Game>
        <ApplicationPath>eXo\\eXoDOS\\!dos\\kq2\\King's Quest II (1985).bat</ApplicationPath>
        <ID>kq2-id</ID>
        <Title>King's Quest II</Title>
      </Game>
      <Game>
        <ApplicationPath>Setup eXoWin3x.bat</ApplicationPath>
        <ID>setup</ID>
        <Title>eXoWin3x</Title>
      </Game>
    </LaunchBox>
    """

    static let scummvmXML = """
    <?xml version="1.0" standalone="yes"?>
    <LaunchBox>
      <Game>
        <ApplicationPath>eXo\\eXoScummVM\\!ScummVM\\Lure of the Temptress (Multi-Platform)\\Lure of the Temptress (Multi-Platform).bat</ApplicationPath>
        <ID>lure-id</ID>
        <Title>Lure of the Temptress</Title>
      </Game>
      <Game>
        <ApplicationPath>eXo\\eXoScummVM\\!ScummVM\\Escape from Hell (DOS)\\Escape from Hell (DOS).bat</ApplicationPath>
        <ID>hell-id</ID>
        <Title>Escape from Hell</Title>
      </Game>
      <Game>
        <ApplicationPath>eXo\\Update\\updateScummVM.bat</ApplicationPath>
        <ID>update</ID>
        <Title>Update</Title>
      </Game>
    </LaunchBox>
    """

    @Test func registryIsConsistent() {
        let ids = ExoCollection.all.map(\.id)
        #expect(ids == ["eXoDOS", "eXoWin3x", "eXoScummVM"])
        #expect(Set(ids).count == ids.count)
        // eXo's own catalogue spells it eXoWin3X.
        #expect(ExoCollection.named("eXoWin3X") == .exoWin3x)
        #expect(ExoCollection.named("exoscummvm") == .exoScummVM)
        #expect(ExoCollection.named("eXoWin9x") == nil)
        for c in ExoCollection.all {
            #expect(c.folder == "eXo/\(c.id)")
            #expect(c.torrentURL.host == "www.retro-exo.com")
            #expect(c.torrentFileName == "\(c.id).torrent")
            #expect(!c.catalogXML.isEmpty && !c.imagePlatforms.isEmpty)
        }
        #expect(ExoCollection.exoDOS.launcher == .dosbox && !ExoCollection.exoDOS.configsPerGame)
        #expect(ExoCollection.exoWin3x.launcher == .dosbox && ExoCollection.exoWin3x.configsPerGame)
        #expect(ExoCollection.exoScummVM.launcher == .scummvm && ExoCollection.exoScummVM.configArchive == nil)
    }

    @Test func parsesWin3xAndRespellsItsFolder() throws {
        let games = try LaunchBoxParser.parse(Data(Self.win3xXML.utf8), collection: .exoWin3x)
        // The eXoDOS row and the setup entry are not Win3x games.
        #expect(games.map(\.guid) == ["maze-id", "hist-id"])
        let maze = games[0]
        #expect(maze.collection == "eXoWin3x")
        #expect(maze.id == "eXoWin3x:maze-id")
        #expect(maze.shortcode == "3DMaze")
        #expect(maze.archivePath == "eXo/eXoWin3x/3D Maze (1991).zip")
        #expect(maze.configFolder == "eXo/eXoWin3x/!win3x/3DMaze")
        #expect(maze.gameFolder == "eXo/eXoWin3x/3DMaze")
        #expect(maze.year == 1991)
    }

    @Test func parsesScummVMWithFolderNamedAfterTheGame() throws {
        let games = try LaunchBoxParser.parse(Data(Self.scummvmXML.utf8), collection: .exoScummVM)
        #expect(games.map(\.guid) == ["lure-id", "hell-id"])
        let lure = games[0]
        #expect(lure.shortcode == "Lure of the Temptress (Multi-Platform)")
        #expect(lure.launcherName == lure.shortcode)
        #expect(lure.archivePath == "eXo/eXoScummVM/Lure of the Temptress (Multi-Platform).zip")
        #expect(lure.gameFolder == "eXo/eXoScummVM/Lure of the Temptress (Multi-Platform)")
    }

    @Test func sameGUIDInTwoCollectionsStaysTwoGames() throws {
        let a = try LaunchBoxParser.parse(Data(Self.win3xXML.utf8), collection: .exoWin3x)[0]
        let xml = Self.win3xXML.replacingOccurrences(of: "eXo\\eXoWin3X\\!win3x", with: "eXo\\eXoDOS\\!dos")
        let b = try LaunchBoxParser.parse(Data(xml.utf8), collection: .exoDOS)[0]
        #expect(a.guid == b.guid)
        #expect(a.id != b.id)
    }

    @Test func keepsArchivedGamesInTheTorrentsSpelling() throws {
        let games = try LaunchBoxParser.parse(Data(Self.scummvmXML.utf8), collection: .exoScummVM)
        let torrent = [
            "eXo/eXoScummVM/Lure of the Temptress (Multi-Platform).zip",
            "eXo/eXoScummVM/Escape From Hell (DOS).zip",
        ]
        let kept = Catalog.keepingArchived(games, torrentPaths: torrent)
        #expect(kept.count == 2)
        #expect(kept[0] == games[0])
        // The archive's folder follows the archive, so the shortcode does too.
        #expect(kept[1].launcherName == "Escape From Hell (DOS)")
        #expect(kept[1].shortcode == "Escape From Hell (DOS)")
        #expect(kept[1].archivePath == "eXo/eXoScummVM/Escape From Hell (DOS).zip")
        #expect(kept[1].guid == "hell-id" && kept[1].title == "Escape from Hell")

        let dropped = Catalog.keepingArchived(games, torrentPaths: [torrent[0]])
        #expect(dropped.map(\.guid) == ["lure-id"])

        // A Win3x shortcode is not the archive name and keeps its spelling.
        let win = try LaunchBoxParser.parse(Data(Self.win3xXML.utf8), collection: .exoWin3x)
        let respelled = Catalog.keepingArchived(win, torrentPaths: ["eXo/eXoWin3x/3D MAZE (1991).zip"])
        #expect(respelled.map(\.shortcode) == ["3DMaze"])
        #expect(respelled.map(\.launcherName) == ["3D MAZE (1991)"])
    }

    @Test func readsCataloguesSavedBeforeCollections() throws {
        let json = """
        {"formatVersion":1,"torrentInfoHash":"abc","createdAt":0,"games":[{"id":"g1","title":"Doom","sortTitle":"Doom",
        "year":1993,"developer":"id","publisher":"id","genres":["Action"],"series":[],"playlists":[],"notes":"",
        "maxPlayers":4,"playMode":"","source":"","rating":"","communityRating":4.5,"shortcode":"DOOM","launcherName":"DOOM (1993)"}]}
        """
        let cat = try JSONDecoder().decode(Catalog.self, from: Data(json.utf8))
        #expect(cat.collection == nil)
        #expect(cat.games[0].collection == "eXoDOS")
        #expect(cat.games[0].guid == "g1")
        #expect(cat.games[0].id == "eXoDOS:g1")

        // And what is saved now comes back the same, collection included.
        let games = try LaunchBoxParser.parse(Data(Self.win3xXML.utf8), collection: .exoWin3x)
        let now = Catalog(collection: "eXoWin3x", torrentInfoHash: "def", games: games)
        let back = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(now))
        #expect(back.collection == "eXoWin3x")
        #expect(back.games == games)
    }

    @Test func indexesArtUnderTheCollectionsPlatforms() throws {
        let games = try LaunchBoxParser.parse(Data(Self.win3xXML.utf8), collection: .exoWin3x)
        func entry(_ name: String, _ offset: Int64) -> ZipEntry {
            ZipEntry(name: name, method: 8, flags: 0, crc32: 0, compressedSize: 10, uncompressedSize: 10, localHeaderOffset: offset, externalAttributes: 0)
        }
        let entries = [
            entry("Images/MS-DOS/Box - Front/3D Maze-01.jpg", 1),
            entry("Images/Windows 3x/Box - Front/3D Maze-01.jpg", 2),
            entry("Images/Windows 3x/Screenshot - Gameplay/Discover History-01.png", 3),
        ]
        let index = MediaIndex.build(archivePath: "x", entries: entries, games: games, platforms: ExoCollection.exoWin3x.imagePlatforms)
        #expect(index.covers["maze-id"]?.localHeaderOffset == 2)
        #expect(index.screenshots["hist-id"]?.count == 1)

        // eXoScummVM keeps its unstable titles under a second platform.
        let svm = try LaunchBoxParser.parse(Data(Self.scummvmXML.utf8), collection: .exoScummVM)
        let svmIndex = MediaIndex.build(archivePath: "x", entries: [
            entry("Images/ScummVM/Box - Front/Lure of the Temptress-01.jpg", 4),
            entry("Images/ScummVM SVN/Box - Front/Escape from Hell-01.jpg", 5),
        ], games: svm, platforms: ExoCollection.exoScummVM.imagePlatforms)
        #expect(svmIndex.covers["lure-id"]?.localHeaderOffset == 4)
        #expect(svmIndex.covers["hell-id"]?.localHeaderOffset == 5)
    }

    @Test func mapsEXOBuildsToOfficialReleases() {
        #expect(ScummVM.release(forBuild: "") == "2.8.0")
        #expect(ScummVM.release(forBuild: "2.5") == "2.5.0")
        #expect(ScummVM.release(forBuild: "2.9.0") == "2.9.0")
        #expect(ScummVM.release(forBuild: "2026.1.0") == "2026.1.0")
        #expect(ScummVM.release(forBuild: "svn2.3_18903") == "2.5.0")
        #expect(ScummVM.release(forBuild: "svn3.0.0git19492") == "2026.1.0")
        // A version eXo adds later is taken at its word.
        #expect(ScummVM.release(forBuild: "2026.4") == "2026.4.0")
        #expect(ScummVM.release(forBuild: "2026.4.0") == "2026.4.0")
        #expect(ScummVM.diskImage("2.9.0").1.absoluteString == "https://downloads.scummvm.org/frs/scummvm/2.9.0/scummvm-2.9.0-macosx.dmg")
    }
}

@Suite struct SupportMigrationTests {
    private func folders() throws -> EnginePaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exoshelf-migrate-\(UUID().uuidString)")
        let paths = EnginePaths(support: root.appendingPathComponent("support"), caches: root.appendingPathComponent("caches"),
                                library: root.appendingPathComponent("lib"))
        for d in [paths.support, paths.caches.appendingPathComponent("covers"), paths.caches.appendingPathComponent("pieces/abc123")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return paths
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    @Test func movesTheSingleCollectionLayoutIntoEXODOS() throws {
        let p = try folders()
        let s = p.support
        try write("torrent", s.appendingPathComponent("eXoDOS.torrent"))
        try write("{}", s.appendingPathComponent("catalog.json"))
        try write("{}", s.appendingPathComponent("media.json"))
        try write(#"{"installed":{"g1":{"installedAt":0,"playCount":2}},"favorites":["g1"]}"#, s.appendingPathComponent("library.json"))
        try write("conf", s.appendingPathComponent("launch/DOOM.conf"))
        try write("log", s.appendingPathComponent("logs/DOOM.log"))
        try write("jpg", p.caches.appendingPathComponent("covers/g1.jpg"))
        try write("piece", p.caches.appendingPathComponent("pieces/abc123/0.piece"))

        SupportMigration.migrate(p)

        let dos = p.support(.exoDOS)
        #expect(read(dos.appendingPathComponent("eXoDOS.torrent")) == "torrent")
        #expect(read(dos.appendingPathComponent("launch/DOOM.conf")) == "conf")
        #expect(read(dos.appendingPathComponent("logs/DOOM.log")) == "log")
        #expect(read(p.caches.appendingPathComponent("covers/eXoDOS/g1.jpg")) == "jpg")
        // The piece cache was always per info hash and stays put.
        #expect(read(p.caches.appendingPathComponent("pieces/abc123/0.piece")) == "piece")
        for old in SupportMigration.supportItems {
            #expect(!FileManager.default.fileExists(atPath: s.appendingPathComponent(old).path))
        }
        // The installs survive the move.
        let state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: dos.appendingPathComponent("library.json")))
        #expect(state.installed["g1"]?.playCount == 2)
        #expect(state.favorites == ["g1"])

        // Running again changes nothing.
        SupportMigration.migrate(p)
        #expect(read(dos.appendingPathComponent("eXoDOS.torrent")) == "torrent")
    }

    @Test func neverOverwritesTheNewLayout() throws {
        let p = try folders()
        try write("old", p.support.appendingPathComponent("library.json"))
        try write("new", p.support(.exoDOS).appendingPathComponent("library.json"))
        SupportMigration.migrate(p)
        #expect(read(p.support(.exoDOS).appendingPathComponent("library.json")) == "new")
        #expect(read(p.support.appendingPathComponent("library.json")) == "old")
    }

    @Test func engineLoadsAMigratedShelf() async throws {
        let p = try folders()
        // No torrent, so no catalogue: but the library state must load, and
        // land under eXoDOS with the collection in each game's id.
        try write(#"{"installed":{"g1":{"installedAt":0,"playCount":1}},"favorites":["g2"]}"#, p.support.appendingPathComponent("library.json"))
        let engine = ExoEngine(paths: p)
        #expect(await engine.load().isEmpty)
        let shelf = await engine.shelfState()
        #expect(shelf.installed == ["eXoDOS:g1"])
        #expect(shelf.favorites == ["eXoDOS:g2"])
        #expect(await engine.libraryState(of: .exoWin3x).installed.isEmpty)
    }
}
