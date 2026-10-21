import Foundation
import Testing
@testable import ExoShelfCore

@Suite struct CatalogTests {
    static let xml = """
    <?xml version="1.0" standalone="yes"?>
    <LaunchBox>
      <Game>
        <ApplicationPath>eXo\\eXoDOS\\!dos\\captlsm\\Capitalism (1995).bat</ApplicationPath>
        <Developer>Enlight Software</Developer>
        <ID>0a84694c-91f2-40bb-921f-c9f276fedb30</ID>
        <Notes>Business &amp; strategy.</Notes>
        <Publisher>Interactive Magic Ltd.</Publisher>
        <ReleaseDate>1995-01-01T00:00:00-06:00</ReleaseDate>
        <Title>Capitalism</Title>
        <Series>Capitalism series; Playlist: Roland MT-32; Playlist: Sound Canvas</Series>
        <Genre>Construction and Management Simulation; Strategy</Genre>
        <MaxPlayers>1</MaxPlayers>
      </Game>
      <Game>
        <ApplicationPath>Setup eXoDOS.bat</ApplicationPath>
        <ID>setup</ID>
        <Title>eXoDOS</Title>
      </Game>
      <Game>
        <ApplicationPath>eXo\\eXoDOS\\!dos\\kq2\\King's Quest II - Romancing the Throne (1985).bat</ApplicationPath>
        <ID>kq2-id</ID>
        <Title>King's Quest II: Romancing the Throne</Title>
        <ReleaseDate>1985-01-01T00:00:00-06:00</ReleaseDate>
        <Developer>Sierra On-Line</Developer>
        <Genre>Adventure</Genre>
      </Game>
    </LaunchBox>
    """

    @Test func parsesLaunchBoxGames() throws {
        let games = try LaunchBoxParser.parse(Data(Self.xml.utf8))
        #expect(games.count == 2)
        let g = games[0]
        #expect(g.collection == "eXoDOS")
        #expect(g.guid == "0a84694c-91f2-40bb-921f-c9f276fedb30")
        #expect(g.id == "eXoDOS:0a84694c-91f2-40bb-921f-c9f276fedb30")
        #expect(g.title == "Capitalism")
        #expect(g.year == 1995)
        #expect(g.shortcode == "captlsm")
        #expect(g.archivePath == "eXo/eXoDOS/Capitalism (1995).zip")
        #expect(g.configFolder == "eXo/eXoDOS/!dos/captlsm")
        #expect(g.genres == ["Construction and Management Simulation", "Strategy"])
        #expect(g.series == ["Capitalism series"])
        #expect(g.playlists == ["Roland MT-32", "Sound Canvas"])
        #expect(g.notes == "Business & strategy.")
    }

    @Test func searchRanksTitlesAndIgnoresPunctuation() throws {
        let games = try LaunchBoxParser.parse(Data(Self.xml.utf8))
        let search = CatalogSearch(games)
        #expect(search.search("kings quest").map(\.guid) == ["kq2-id"])
        #expect(search.search("sierra 1985").map(\.guid) == ["kq2-id"])
        #expect(search.search("strategy").map(\.guid) == ["0a84694c-91f2-40bb-921f-c9f276fedb30"])
        #expect(search.search("").count == 2)
        #expect(search.search("zzz").isEmpty)
    }

    @Test func matchesBoxArtLikeLaunchBox() throws {
        let games = try LaunchBoxParser.parse(Data(Self.xml.utf8))
        func entry(_ name: String, _ offset: Int64) -> ZipEntry {
            ZipEntry(name: name, method: 8, flags: 0, crc32: 0, compressedSize: 10, uncompressedSize: 10, localHeaderOffset: offset, externalAttributes: 0)
        }
        let entries = [
            entry("Images/MS-DOS/Box - Front/Europe/Capitalism-01.jpg", 1),
            entry("Images/MS-DOS/Box - Front/Capitalism-02.jpg", 2),
            entry("Images/MS-DOS/Box - Front/King_s Quest II_ Romancing the Throne-01.jpg", 3),
            entry("Images/MS-DOS/Screenshot - Gameplay/Capitalism-01.png", 4),
        ]
        let index = MediaIndex.build(archivePath: "x", entries: entries, games: games)
        #expect(index.covers["0a84694c-91f2-40bb-921f-c9f276fedb30"]?.localHeaderOffset == 2)
        #expect(index.covers["kq2-id"]?.localHeaderOffset == 3)
        #expect(index.screenshots["0a84694c-91f2-40bb-921f-c9f276fedb30"]?.count == 1)
    }
}
