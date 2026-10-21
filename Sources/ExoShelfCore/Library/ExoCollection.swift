import Foundation

/// How a collection's games are started.
public enum LauncherKind: String, Sendable, Codable {
    /// DOSBox Staging, with eXo's per-game `dosbox.conf`.
    case dosbox
    /// ScummVM, with the engine id and build eXo's launch index names.
    case scummvm
}

/// Where a collection keeps the MT-32 ROMs and the SoundCanvas soundfont:
/// an `mt32/` folder in a zip, possibly inside another zip.
public struct SoundFilesSource: Sendable, Hashable {
    /// The outer zip, as a path inside the torrent.
    public let archive: String
    /// The zip inside it that holds `mt32/`, if any.
    public let inner: String?
}

/// One of eXo's collections: a torrent, and where the catalogue, art,
/// configs and games sit inside it. All of them unpack into the same `eXo`
/// folder, each into its own `eXo/<id>`, as eXo's own merged install does.
public struct ExoCollection: Sendable, Hashable, Identifiable {
    /// eXo's name for the collection, which is also its folder under `eXo/`.
    public let id: String
    /// What it holds, for the interface: "DOS games".
    public let summary: String
    public let torrentURL: URL
    /// The LaunchBox metadata archive: catalogue and art.
    public let metadataArchive: String
    /// Catalogue files inside the metadata archive; their games are merged.
    public let catalogXML: [String]
    /// `Images/<platform>/` folders of the metadata archive.
    public let imagePlatforms: [String]
    /// Name of the per-game launcher folder in the collection folder: `!dos`.
    /// LaunchBox points each game at `eXo/<id>/<launcherFolder>/<shortcode>/<name>.bat`.
    public let launcherFolder: String
    /// The archive of eXo's per-game launch configs, if the launcher needs them.
    public let configArchive: String?
    /// True when configs are fetched game by game rather than unpacked whole;
    /// eXoWin3x's archive is mostly manuals.
    public let configsPerGame: Bool
    public let soundFiles: SoundFilesSource
    public let launcher: LauncherKind

    /// The collection's folder relative to the library root: `eXo/eXoDOS`.
    public var folder: String { "eXo/\(id)" }
    /// The torrent's file name, as eXo publishes it.
    public var torrentFileName: String { torrentURL.lastPathComponent }
}

extension ExoCollection {
    public static let exoDOS = ExoCollection(
        id: "eXoDOS",
        summary: "DOS games",
        torrentURL: URL(string: "https://www.retro-exo.com/eXoDOS.torrent")!,
        metadataArchive: "Content/XODOSMetadata.zip",
        catalogXML: ["xml/all/MS-DOS.xml"],
        imagePlatforms: ["MS-DOS"],
        launcherFolder: "!dos",
        configArchive: "Content/!DOSmetadata.zip",
        configsPerGame: false,
        soundFiles: SoundFilesSource(archive: "eXo/util/util.zip", inner: "EXTDOS.zip"),
        launcher: .dosbox
    )

    public static let exoWin3x = ExoCollection(
        id: "eXoWin3x",
        summary: "Windows 3.x games",
        torrentURL: URL(string: "https://www.retro-exo.com/eXoWin3x.torrent")!,
        metadataArchive: "Content/XOWin3xMetadata.zip",
        catalogXML: ["xml/Windows 3x.xml"],
        imagePlatforms: ["Windows 3x"],
        launcherFolder: "!win3x",
        configArchive: "Content/!Win3Xmetadata.zip",
        configsPerGame: true,
        soundFiles: SoundFilesSource(archive: "eXo/util/util3x.zip", inner: "mt32.zip"),
        launcher: .dosbox
    )

    public static let exoScummVM = ExoCollection(
        id: "eXoScummVM",
        summary: "ScummVM games",
        torrentURL: URL(string: "https://www.retro-exo.com/eXoScummVM.torrent")!,
        metadataArchive: "Content/XOScummVMMetadata.zip",
        catalogXML: ["xml/all/ScummVM.xml", "xml/all/ScummVM SVN.xml"],
        imagePlatforms: ["ScummVM", "ScummVM SVN"],
        launcherFolder: "!ScummVM",
        configArchive: nil,
        configsPerGame: false,
        soundFiles: SoundFilesSource(archive: "eXo/util/utilSVM.zip", inner: "EXTsvm.zip"),
        launcher: .scummvm
    )

    /// Every collection ExoShelf can run, in the order the interface lists them.
    public static let all: [ExoCollection] = [exoDOS, exoWin3x, exoScummVM]

    /// The collection with this id, ignoring case: eXo's own catalogue spells
    /// eXoWin3x both ways.
    public static func named(_ id: String) -> ExoCollection? {
        all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
}
