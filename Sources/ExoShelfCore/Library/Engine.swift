import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where ExoShelf keeps things.
public struct EnginePaths: Sendable, Equatable {
    /// Per collection: torrent file, catalogue, art index, library state,
    /// launch configs and logs. Also the ScummVM releases ExoShelf installs.
    public var support: URL
    /// Piece cache and cover thumbnails; safe to delete.
    public var caches: URL
    /// The collection tree (`eXo/...`) that games install into.
    public var library: URL

    public init(support: URL, caches: URL, library: URL) {
        self.support = support
        self.caches = caches
        self.library = library
    }

    public static func standard(library: URL? = nil) -> EnginePaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ExoShelf")
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ExoShelf")
        let lib = library ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Games/ExoShelf")
        return EnginePaths(support: support, caches: caches, library: lib)
    }

    /// `standard`, with `EXOSHELF_SUPPORT`, `EXOSHELF_CACHES` and
    /// `EXOSHELF_LIBRARY` taking precedence, for development and scripts.
    public static func fromEnvironment(library: URL? = nil) -> EnginePaths {
        let env = ProcessInfo.processInfo.environment
        var p = standard(library: env["EXOSHELF_LIBRARY"].map { URL(fileURLWithPath: $0) } ?? library)
        if let s = env["EXOSHELF_SUPPORT"] { p.support = URL(fileURLWithPath: s) }
        if let c = env["EXOSHELF_CACHES"] { p.caches = URL(fileURLWithPath: c) }
        return p
    }

    /// DOSBox and ScummVM run here; eXo's configs are relative to it.
    public var workingDirectory: URL { library.appendingPathComponent("eXo") }
    /// eXo's MT-32 ROMs and SoundCanvas soundfont, shared by every collection.
    public var mt32: URL { workingDirectory.appendingPathComponent("mt32") }
    /// ScummVM releases ExoShelf installed for itself.
    public var emulators: URL { support.appendingPathComponent("Emulators") }

    public func support(_ c: ExoCollection) -> URL { support.appendingPathComponent(c.id) }
    /// Every torrent's piece cache, each in a folder named by its info hash.
    public var pieces: URL { caches.appendingPathComponent("pieces") }
    func covers(_ c: ExoCollection) -> URL { caches.appendingPathComponent("covers/\(c.id)") }
    func screenshots(_ c: ExoCollection) -> URL { caches.appendingPathComponent("screenshots/\(c.id)") }
}

public enum SetupStep: Sendable, Equatable {
    case downloadingTorrent
    case readingArchiveIndex
    case downloadingCatalog
    case indexingArt
    case done
}

public enum InstallPhase: Sendable, Equatable {
    case preparing(String)
    case downloading(TransferProgress)
    case extracting(Double)
}

public enum InstallState: Sendable, Equatable {
    case notInstalled
    /// A download was interrupted; this many bytes are on disk.
    case partial(Int64)
    case installed
}

/// How the emulated screen is drawn.
public enum DisplayShader: String, Sendable, CaseIterable, Codable {
    /// Crisp, evenly scaled pixels, close to eXo's `normal2x` setups.
    case sharp
    /// Staging's adaptive CRT emulation.
    case crt
    /// Whatever the game's config or the user's Staging defaults say.
    case unchanged

    var configText: String? {
        switch self {
        case .sharp: return "[render]\nshader=sharp\n"
        case .crt: return "[render]\nshader=crt-auto\n"
        case .unchanged: return nil
        }
    }
}

public struct LaunchOptions: Sendable {
    /// DOSBox Staging, which runs eXoDOS and eXoWin3x.
    public var dosbox: URL?
    /// A ScummVM for every eXoScummVM game, instead of the release eXo pins.
    public var scummvm: URL?
    /// File name of the config in the game's `!dos` folder, or the key of a
    /// `ScummVMChoice`; nil for eXo's default.
    public var configuration: String?
    public var fullscreen: Bool
    public var shader: DisplayShader
    public var generalMIDI: ConfPatcher.GeneralMIDI
    /// Extra DOSBox config text applied last.
    public var extraConfig: String

    public init(dosbox: URL? = nil, scummvm: URL? = nil, configuration: String? = nil, fullscreen: Bool = false,
                shader: DisplayShader = .sharp, generalMIDI: ConfPatcher.GeneralMIDI = .soundfont, extraConfig: String = "") {
        self.dosbox = dosbox
        self.scummvm = scummvm
        self.configuration = configuration
        self.fullscreen = fullscreen
        self.shader = shader
        self.generalMIDI = generalMIDI
        self.extraConfig = extraConfig
    }
}

/// A selectable way to start a game: eXo's default config, or one of the
/// alternatives its `exception.bat` menu offers (CGA instead of EGA, ...);
/// for ScummVM, an edition and its music.
public struct GameConfiguration: Sendable, Hashable, Identifiable {
    public let file: String
    public let label: String
    public var id: String { file }
}

public enum EngineError: Error, CustomStringConvertible {
    case notSetUp(String)
    case notInCollection(String)
    case notInstalled(String)
    case configMissing(String)
    case emulatorMissing(String)
    /// ScummVM does not see the game in its folder (path, `engine:gameid`).
    case gameNotRecognised(String, String)

    public var description: String {
        switch self {
        case .notSetUp(let c): return "\(c) has not been set up yet."
        case .notInCollection(let t): return "\(t) is not in this version of the collection."
        case .notInstalled(let t): return "\(t) is not installed."
        case .configMissing(let p): return "eXo's launch config is missing: \(p)"
        case .emulatorMissing(let e): return "\(e) is needed to play this game."
        case .gameNotRecognised(let p, let id):
            return "ScummVM does not recognise the game data in \(p) (expected \(id)). The download may be incomplete; reinstall the game."
        }
    }
}

/// What ExoShelf remembers about one collection's shelf. Keys are LaunchBox
/// GUIDs.
public struct LibraryState: Codable, Sendable {
    public struct Record: Codable, Sendable {
        public var installedAt: Date
        public var lastPlayed: Date?
        public var playCount = 0
    }

    public var installed: [String: Record] = [:]
    public var favorites: Set<String> = []
    /// Info hash of the torrent eXo's launch configs (or, for eXoScummVM,
    /// its launch index) were last fetched from.
    public var configsFor: String?
    public var soundFilesFor: String?
}

/// The library state of every collection together, keyed by `Game.id`.
public struct ShelfState: Sendable, Equatable {
    public var installed: Set<String> = []
    public var favorites: Set<String> = []
    public var lastPlayed: [String: Date] = [:]
}

/// Everything below the UI: one torrent session per collection, the
/// catalogues, art, installs and launches. One per library folder.
public actor ExoEngine {
    static let scummvmIndexEntry = "scummvm.txt"

    /// What the engine holds for one collection.
    struct Shelf {
        let collection: ExoCollection
        var meta: TorrentMeta?
        var session: TorrentSession?
        var catalog: Catalog?
        var media: MediaIndex?
        var state = LibraryState()
        var configsTask: Task<Void, Error>?
        var scummvmIndex: ScummVMIndex?
    }

    nonisolated public let paths: EnginePaths
    private var shelves: [String: Shelf] = [:]
    private var soundTask: Task<Void, Error>?
    private var running: [String: Process] = [:]
    private let coverGate = AsyncGate(limit: 6)

    public init(paths: EnginePaths) {
        self.paths = paths
        for c in ExoCollection.all { shelves[c.id] = Shelf(collection: c) }
    }

    private func torrentURL(_ c: ExoCollection) -> URL { paths.support(c).appendingPathComponent(c.torrentFileName) }
    private func catalogURL(_ c: ExoCollection) -> URL { paths.support(c).appendingPathComponent("catalog.json") }
    private func mediaURL(_ c: ExoCollection) -> URL { paths.support(c).appendingPathComponent("media.json") }
    private func stateURL(_ c: ExoCollection) -> URL { paths.support(c).appendingPathComponent("library.json") }
    private func scummvmIndexURL(_ c: ExoCollection) -> URL { paths.support(c).appendingPathComponent(Self.scummvmIndexEntry) }
    private func scummvmINI(_ c: ExoCollection, build: String) -> URL {
        paths.support(c).appendingPathComponent("ini/\(build.isEmpty ? "default" : build).ini")
    }

    private func collection(of game: Game) throws -> ExoCollection {
        guard let c = ExoCollection.named(game.collection) else { throw EngineError.notInCollection(game.title) }
        return c
    }

    // MARK: - Setup

    /// Loads what earlier runs saved, moving a single-collection layout from
    /// before eXoWin3x and eXoScummVM into its eXoDOS folder first. Returns
    /// the collections whose catalogue is ready.
    @discardableResult
    public func load() -> [ExoCollection] {
        SupportMigration.migrate(paths)
        for c in ExoCollection.all { load(c) }
        return readyCollections
    }

    private func load(_ c: ExoCollection) {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: stateURL(c)), let s = try? decoder.decode(LibraryState.self, from: data) {
            shelves[c.id]?.state = s
        }
        guard let data = try? Data(contentsOf: torrentURL(c)), let m = try? TorrentMeta(data: data) else { return }
        shelves[c.id]?.meta = m
        if shelves[c.id]?.session == nil {
            shelves[c.id]?.session = TorrentSession(meta: m, cacheDirectory: paths.pieces)
        }
        if let d = try? Data(contentsOf: catalogURL(c)), let cat = try? decoder.decode(Catalog.self, from: d),
           cat.formatVersion == Catalog.formatVersion, cat.torrentInfoHash == m.infoHashHex,
           (cat.collection ?? ExoCollection.exoDOS.id) == c.id {
            shelves[c.id]?.catalog = cat
        }
        if let d = try? Data(contentsOf: mediaURL(c)), let mi = try? decoder.decode(MediaIndex.self, from: d),
           mi.formatVersion == MediaIndex.formatVersion {
            shelves[c.id]?.media = mi
        }
        if let text = try? String(contentsOf: scummvmIndexURL(c), encoding: .utf8) {
            shelves[c.id]?.scummvmIndex = ScummVMIndex(text: text)
        }
    }

    /// Collections whose catalogue is ready, in `ExoCollection.all` order.
    public var readyCollections: [ExoCollection] {
        ExoCollection.all.filter { shelves[$0.id]?.catalog != nil }
    }

    public func catalog(of collection: ExoCollection) -> Catalog? { shelves[collection.id]?.catalog }

    public func meta(of collection: ExoCollection) -> TorrentMeta? { shelves[collection.id]?.meta }

    public func media(of collection: ExoCollection) -> MediaIndex? { shelves[collection.id]?.media }

    public func libraryState(of collection: ExoCollection) -> LibraryState { shelves[collection.id]?.state ?? LibraryState() }

    /// Every game of every ready collection.
    public var allGames: [Game] {
        ExoCollection.all.flatMap { shelves[$0.id]?.catalog?.games ?? [] }
    }

    /// First run of a collection: fetch eXo's torrent (or use the one
    /// given), then read the catalogue and the art index out of the metadata
    /// archive. About 25 MB of the eXoDOS torrent is downloaded for this.
    public func setUp(_ c: ExoCollection, torrent: Data? = nil, progress: (@Sendable (SetupStep) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: paths.support(c), withIntermediateDirectories: true)
        let torrentData: Data
        if let torrent {
            torrentData = torrent
        } else {
            progress?(.downloadingTorrent)
            let (data, _) = try await URLSession.shared.data(from: c.torrentURL)
            torrentData = data
        }
        let m = try TorrentMeta(data: torrentData)
        try torrentData.write(to: torrentURL(c), options: .atomic)
        if shelves[c.id]?.meta?.infoHash != m.infoHash {
            await shelves[c.id]?.session?.shutdown()
            shelves[c.id]?.session = TorrentSession(meta: m, cacheDirectory: paths.pieces)
            shelves[c.id]?.meta = m
        }
        guard let session = shelves[c.id]?.session, let file = m.file(atPath: c.metadataArchive) else {
            throw EngineError.notInCollection(c.metadataArchive)
        }

        progress?(.readingArchiveIndex)
        let zip = try await ZipArchive.open(TorrentFileSource(session: session, file: file))
        progress?(.downloadingCatalog)
        var parsed: [Game] = []
        for path in c.catalogXML {
            let leaf = (path as NSString).lastPathComponent.lowercased()
            guard let entry = zip.entry(named: path) ?? zip.entries.first(where: { $0.name.lowercased().hasSuffix("/" + leaf) }) else {
                throw EngineError.notInCollection(path)
            }
            parsed += try LaunchBoxParser.parse(try await zip.data(of: entry), collection: c)
        }
        let games = Catalog.keepingArchived(parsed, torrentPaths: m.files.map(\.path))
        let cat = Catalog(collection: c.id, torrentInfoHash: m.infoHashHex, games: games)

        progress?(.indexingArt)
        let mi = MediaIndex.build(archivePath: c.metadataArchive, entries: zip.entries, games: games, platforms: c.imagePlatforms)
        let encoder = JSONEncoder()
        try encoder.encode(cat).write(to: catalogURL(c), options: .atomic)
        try encoder.encode(mi).write(to: mediaURL(c), options: .atomic)
        shelves[c.id]?.catalog = cat
        shelves[c.id]?.media = mi
        progress?(.done)
    }

    /// Peers and transfer rate over every collection's torrent.
    public func sessionStats() async -> SessionStats? {
        var total: SessionStats?
        for c in ExoCollection.all {
            guard let s = await shelves[c.id]?.session?.stats() else { continue }
            guard var t = total else { total = s; continue }
            t.connectedPeers += s.connectedPeers
            t.unchokedPeers += s.unchokedPeers
            t.knownPeers += s.knownPeers
            t.bytesPerSecond += s.bytesPerSecond
            t.downloadedBytes += s.downloadedBytes
            t.activeJobs += s.activeJobs
            total = t
        }
        return total
    }

    // MARK: - Library state

    private func saveState(_ c: ExoCollection) {
        guard let state = shelves[c.id]?.state, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL(c), options: .atomic)
    }

    public func setFavorite(_ game: Game, _ on: Bool) {
        guard let c = ExoCollection.named(game.collection) else { return }
        if on { shelves[c.id]?.state.favorites.insert(game.guid) } else { shelves[c.id]?.state.favorites.remove(game.guid) }
        saveState(c)
    }

    /// Installs, favourites and play dates of every collection, by `Game.id`.
    public func shelfState() -> ShelfState {
        var out = ShelfState()
        for c in ExoCollection.all {
            guard let s = shelves[c.id]?.state else { continue }
            for (guid, record) in s.installed {
                out.installed.insert("\(c.id):\(guid)")
                if let d = record.lastPlayed { out.lastPlayed["\(c.id):\(guid)"] = d }
            }
            for guid in s.favorites { out.favorites.insert("\(c.id):\(guid)") }
        }
        return out
    }

    /// Download size of every game's archive, by `Game.id`.
    public func archiveSizes() -> [String: Int64] {
        var out: [String: Int64] = [:]
        for c in ExoCollection.all {
            guard let meta = shelves[c.id]?.meta, let games = shelves[c.id]?.catalog?.games else { continue }
            let byPath = Dictionary(meta.files.map { ($0.path, $0.length) }, uniquingKeysWith: { a, _ in a })
            for g in games { out[g.id] = byPath[g.archivePath] }
        }
        return out
    }

    public func archiveFile(for game: Game) -> TorrentFile? {
        shelves[game.collection]?.meta?.file(atPath: game.archivePath)
    }

    private func archiveURL(_ game: Game) -> URL { paths.library.appendingPathComponent(game.archivePath) }

    /// The game's folder as it is on disk. eXo's catalogue and archives do
    /// not always agree on case, which matters on a case-sensitive volume.
    private func gameFolderURL(_ game: Game) -> URL {
        ConfPatcher.resolveIgnoringCase(game.gameFolder, in: paths.library) ?? paths.library.appendingPathComponent(game.gameFolder)
    }

    private func configFolderURL(_ game: Game) -> URL {
        ConfPatcher.resolveIgnoringCase(game.configFolder, in: paths.library) ?? paths.library.appendingPathComponent(game.configFolder)
    }

    public func installState(of game: Game) -> InstallState {
        let fm = FileManager.default
        if shelves[game.collection]?.state.installed[game.guid] != nil, fm.fileExists(atPath: gameFolderURL(game).path) { return .installed }
        let part = archiveURL(game).appendingPathExtension("part")
        let pieces = archiveURL(game).appendingPathExtension("part-pieces")
        if fm.fileExists(atPath: part.path),
           let data = try? Data(contentsOf: pieces), let list = try? JSONDecoder().decode([Int].self, from: data),
           let meta = shelves[game.collection]?.meta, let file = archiveFile(for: game) {
            let have = Int64(list.count) * Int64(meta.pieceLength)
            return .partial(min(have, file.length))
        }
        return .notInstalled
    }

    // MARK: - Install

    /// Downloads a game out of its collection's torrent and unpacks it where
    /// eXo's launchers expect it. DOS and Windows 3.x games get eXo's DOSBox
    /// configs and macOS-safe batch files; ScummVM games get eXo's launch
    /// index and the ScummVM release they are pinned to, unless `scummvm`
    /// names one to use instead.
    public func install(_ game: Game, keepArchive: Bool = false, scummvm: URL? = nil,
                        progress: (@Sendable (InstallPhase) -> Void)? = nil) async throws {
        let c = try collection(of: game)
        guard let session = shelves[c.id]?.session else { throw EngineError.notSetUp(c.id) }
        guard let file = archiveFile(for: game) else { throw EngineError.notInCollection(game.title) }

        switch c.launcher {
        case .dosbox:
            progress?(.preparing("Fetching eXo's DOSBox configurations"))
            try await ensureConfigs(for: game)
        case .scummvm:
            progress?(.preparing("Fetching eXo's ScummVM launch index"))
            try await ensureScummVMIndex(c)
        }
        progress?(.preparing("Fetching MT-32 ROMs and the General MIDI soundfont"))
        try await ensureSoundFiles(c)

        let archive = archiveURL(game)
        try await session.download(file: file, to: archive, priority: 10) { p in progress?(.downloading(p)) }

        progress?(.extracting(0))
        let zip = try await ZipArchive.open(LocalFileSource(url: archive))
        let target = paths.library.appendingPathComponent(c.folder)
        try await zip.extract(to: target, progress: { done, total in
            progress?(.extracting(total > 0 ? Double(done) / Double(total) : 1))
        })
        if c.launcher == .dosbox {
            ConfPatcher.patchGameBatches(gameFolder: gameFolderURL(game), workingDirectory: paths.workingDirectory)
        }
        if !keepArchive { try? FileManager.default.removeItem(at: archive) }
        shelves[c.id]?.state.installed[game.guid] = LibraryState.Record(installedAt: Date())
        saveState(c)

        if c.launcher == .scummvm {
            try await ensureScummVM(for: game, using: scummvm, progress: progress)
        }
    }

    /// Removes the game's folder (saved games live there too) and any
    /// archive or partial download.
    public func uninstall(_ game: Game) throws {
        let c = try collection(of: game)
        let fm = FileManager.default
        let folder = gameFolderURL(game)
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        let archive = archiveURL(game)
        for u in [archive, archive.appendingPathExtension("part"), archive.appendingPathExtension("part-pieces")] {
            try? fm.removeItem(at: u)
        }
        shelves[c.id]?.state.installed.removeValue(forKey: game.guid)
        saveState(c)
    }

    /// eXo's per-game DOSBox configs. eXoDOS keeps them in one 15 MB
    /// archive, unpacked into `eXo/eXoDOS/!dos` once per collection version;
    /// eXoWin3x's archive is 680 MB of mostly manuals, so only the game's
    /// own folder is read out of it.
    private func ensureConfigs(for game: Game) async throws {
        let c = try collection(of: game)
        if c.configsPerGame { return try await fetchGameConfigs(game, c) }
        guard let meta = shelves[c.id]?.meta else { throw EngineError.notSetUp(c.id) }
        let folder = paths.library.appendingPathComponent("\(c.folder)/\(c.launcherFolder)")
        if shelves[c.id]?.state.configsFor == meta.infoHashHex, FileManager.default.fileExists(atPath: folder.path) { return }
        if let t = shelves[c.id]?.configsTask { return try await t.value }
        let task = Task { try await self.fetchConfigs(c) }
        shelves[c.id]?.configsTask = task
        defer { shelves[c.id]?.configsTask = nil }
        try await task.value
    }

    private func fetchConfigs(_ c: ExoCollection) async throws {
        guard let meta = shelves[c.id]?.meta, let session = shelves[c.id]?.session,
              let archive = c.configArchive, let file = meta.file(atPath: archive) else { throw EngineError.notSetUp(c.id) }
        let local = paths.caches.appendingPathComponent("support/\((archive as NSString).lastPathComponent)")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await session.download(file: file, to: local, priority: 5)
        let zip = try await ZipArchive.open(LocalFileSource(url: local))
        let prefix = "\(c.folder)/\(c.launcherFolder)/".lowercased()
        try await zip.extract(to: paths.library) { $0.name.lowercased().hasPrefix(prefix) }
        try? FileManager.default.removeItem(at: local)
        shelves[c.id]?.state.configsFor = meta.infoHashHex
        saveState(c)
    }

    /// One game's launch files out of the config archive, read in place:
    /// its directory, then the few pieces that hold the files. The manuals
    /// in `Extras/` stay in the torrent.
    private func fetchGameConfigs(_ game: Game, _ c: ExoCollection) async throws {
        guard let meta = shelves[c.id]?.meta, let session = shelves[c.id]?.session,
              let archive = c.configArchive, let file = meta.file(atPath: archive) else { throw EngineError.notSetUp(c.id) }
        let zip = try await ZipArchive.open(TorrentFileSource(session: session, file: file, priority: 8))
        let prefix = game.configFolder.lowercased() + "/"
        let wanted = zip.entries.filter { e in
            let n = e.name.lowercased()
            return n.hasPrefix(prefix) && !n.dropFirst(prefix.count).hasPrefix("extras/")
        }
        guard !wanted.isEmpty else { throw EngineError.configMissing(game.configFolder) }
        let names = Set(wanted.map(\.name))
        try await zip.extract(to: paths.library) { names.contains($0.name) }
    }

    /// MT-32 ROMs and the SoundCanvas soundfont, which many configs point
    /// at. Every collection carries the same `mt32/` folder in its own
    /// support zip; whichever collection gets there first supplies
    /// `eXo/mt32` for all. eXoDOS stores it in `EXTDOS.zip` inside
    /// `util.zip` (only the `mt32/` entries, about 50 MB, are fetched).
    private func ensureSoundFiles(_ c: ExoCollection) async throws {
        if ConfPatcher.resolveIgnoringCase("SoundCanvas.sf2", in: paths.mt32) != nil { return }
        if let t = soundTask { return try await t.value }
        let task = Task { try await self.fetchSoundFiles(c) }
        soundTask = task
        defer { soundTask = nil }
        try await task.value
    }

    private func fetchSoundFiles(_ c: ExoCollection) async throws {
        guard let meta = shelves[c.id]?.meta, let session = shelves[c.id]?.session,
              let file = meta.file(atPath: c.soundFiles.archive) else { throw EngineError.notSetUp(c.id) }
        var zip = try await ZipArchive.open(TorrentFileSource(session: session, file: file, priority: 5))
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        if let inner = c.soundFiles.inner {
            guard let entry = zip.entry(named: inner) else { throw EngineError.notInCollection(inner) }
            if entry.method == 0 {
                zip = try await zip.nested(entry)
            } else {
                // eXoWin3x deflates its 42 MB mt32.zip, so it cannot be read in place.
                let local = paths.caches.appendingPathComponent("support/\(c.id)-\(inner)")
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await zip.data(of: entry).write(to: local, options: .atomic)
                scratch = local
                zip = try await ZipArchive.open(LocalFileSource(url: local))
            }
        }
        if zip.entries.contains(where: { $0.name.lowercased().hasPrefix("mt32/") }) {
            try await zip.extract(to: paths.workingDirectory) { $0.name.lowercased().hasPrefix("mt32/") }
        } else {
            try await zip.extract(to: paths.mt32)
        }
        shelves[c.id]?.state.soundFilesFor = meta.infoHashHex
        saveState(c)
    }

    // MARK: - ScummVM

    /// eXo's launch index, `scummvm.txt` in `utilSVM.zip`: which engine and
    /// ScummVM build each game runs with.
    private func ensureScummVMIndex(_ c: ExoCollection) async throws {
        guard let meta = shelves[c.id]?.meta, let session = shelves[c.id]?.session else { throw EngineError.notSetUp(c.id) }
        if shelves[c.id]?.state.configsFor == meta.infoHashHex, shelves[c.id]?.scummvmIndex != nil { return }
        guard let file = meta.file(atPath: c.soundFiles.archive) else { throw EngineError.notInCollection(c.soundFiles.archive) }
        let util = try await ZipArchive.open(TorrentFileSource(session: session, file: file, priority: 8))
        guard let entry = util.entry(named: Self.scummvmIndexEntry) else { throw EngineError.notInCollection(Self.scummvmIndexEntry) }
        let text = String(decoding: try await util.data(of: entry), as: UTF8.self)
        try text.write(to: scummvmIndexURL(c), atomically: true, encoding: .utf8)
        shelves[c.id]?.scummvmIndex = ScummVMIndex(text: text)
        shelves[c.id]?.state.configsFor = meta.infoHashHex
        saveState(c)
    }

    /// eXo's ini for a build (`emulators/scmvm/<build>/scummvm.ini` in
    /// `EXTsvm.zip`): its defaults, and the targets some games start by name.
    private func ensureScummVMINI(_ c: ExoCollection, build: String) async throws -> URL {
        let url = scummvmINI(c, build: build)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let meta = shelves[c.id]?.meta, let session = shelves[c.id]?.session,
              let file = meta.file(atPath: c.soundFiles.archive), let inner = c.soundFiles.inner else { throw EngineError.notSetUp(c.id) }
        let util = try await ZipArchive.open(TorrentFileSource(session: session, file: file, priority: 8))
        guard let ext = util.entry(named: inner) else { throw EngineError.notInCollection(inner) }
        let emulators = try await util.nested(ext)
        let name = build.isEmpty ? "emulators/scmvm/scummvm.ini" : "emulators/scmvm/\(build)/scummvm.ini"
        let text: String
        if let entry = emulators.entry(named: name) {
            text = String(decoding: try await emulators.data(of: entry), as: UTF8.self)
        } else {
            text = "[scummvm]\n"
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.replacingOccurrences(of: "\r\n", with: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The release eXo pins the game's chosen edition to; nil until the game
    /// and the launch index are on disk.
    public func scummvmRelease(for game: Game, configuration: String? = nil) -> String? {
        scummvmPlan(game, configuration: configuration, settings: .init()).map { ScummVM.release(forBuild: $0.build) }
    }

    private func scummvmPlan(_ game: Game, configuration: String?, settings: ScummVMGame.Settings) -> ScummVMGame.Plan? {
        guard let index = shelves[game.collection]?.scummvmIndex else { return nil }
        let folder = gameFolderURL(game)
        return try? ScummVMGame.plan(gameFolder: folder, choice: configuration.flatMap(ScummVMChoice.init(key:)), index: index,
                                     mt32: paths.mt32, savePath: folder.appendingPathComponent("!saves"), settings: settings)
    }

    /// Every build the game's editions are pinned to gets its ini, and,
    /// unless the user named a ScummVM of their own, its release.
    private func ensureScummVM(for game: Game, using own: URL?, progress: (@Sendable (InstallPhase) -> Void)?) async throws {
        let c = try collection(of: game)
        guard let index = shelves[c.id]?.scummvmIndex else { throw EngineError.notSetUp(c.id) }
        let folder = gameFolderURL(game)
        var builds: [String] = []
        for choice in ScummVMGame.choices(in: folder) {
            let names = [choice.version, choice.edition, folder.lastPathComponent].compactMap { $0 }
            if let b = index.lookup(names)?.build, !builds.contains(b) { builds.append(b) }
        }
        for build in builds {
            _ = try await ensureScummVMINI(c, build: build)
            guard own == nil else { continue }
            let release = ScummVM.release(forBuild: build)
            if ScummVM.locate(version: release, emulators: paths.emulators) != nil { continue }
            progress?(.preparing("Installing ScummVM \(release)"))
            _ = try await ScummVM.install(version: release, emulators: paths.emulators)
        }
    }

    // MARK: - Art

    /// The game's box art as a JPEG thumbnail, fetched from the metadata
    /// archive on first use. Other covers in the same pieces come along.
    public func cover(for game: Game, priority: Int = 5) async throws -> Data? {
        guard let c = ExoCollection.named(game.collection) else { return nil }
        let dir = paths.covers(c)
        let url = dir.appendingPathComponent("\(game.guid).jpg")
        if let d = try? Data(contentsOf: url) { return d }
        guard let entry = shelves[c.id]?.media?.covers[game.guid], let zip = metadataZip(c, priority: priority) else { return nil }
        await coverGate.wait()
        defer { Task { await coverGate.signal() } }
        try Task.checkCancellation()
        if let d = try? Data(contentsOf: url) { return d }
        let raw = try await zip.data(of: entry)
        let thumb = Self.thumbnail(raw, maxPixels: 600) ?? raw
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try thumb.write(to: url, options: .atomic)
        await harvestCovers(near: entry, in: zip, c)
        return thumb
    }

    public func hasCachedCover(_ game: Game) -> Bool {
        guard let c = ExoCollection.named(game.collection) else { return false }
        return FileManager.default.fileExists(atPath: paths.covers(c).appendingPathComponent("\(game.guid).jpg").path)
    }

    /// Saves every other cover whose bytes are already in the piece cache.
    private func harvestCovers(near entry: ZipEntry, in zip: ZipArchive, _ c: ExoCollection) async {
        guard let media = shelves[c.id]?.media, let session = shelves[c.id]?.session, let meta = shelves[c.id]?.meta,
              let file = meta.file(atPath: c.metadataArchive) else { return }
        let window = Int64(meta.pieceLength) * 2
        let near = media.covers.filter { abs($0.value.localHeaderOffset - entry.localHeaderOffset) < window }
        for (guid, e) in near {
            let url = paths.covers(c).appendingPathComponent("\(guid).jpg")
            if FileManager.default.fileExists(atPath: url.path) { continue }
            let span = e.approximateSpan
            let absolute = (file.offset + span.lowerBound)..<min(file.offset + span.upperBound, file.offset + file.length)
            guard await session.isCached(absolute), let raw = try? await zip.data(of: e) else { continue }
            let thumb = Self.thumbnail(raw, maxPixels: 600) ?? raw
            try? thumb.write(to: url, options: .atomic)
        }
    }

    /// Title and gameplay screenshots, original size.
    public func screenshots(for game: Game, limit: Int = 4) async throws -> [Data] {
        guard let c = ExoCollection.named(game.collection), let entries = shelves[c.id]?.media?.screenshots[game.guid],
              let zip = metadataZip(c, priority: 2) else { return [] }
        let dir = paths.screenshots(c)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [Data] = []
        for (i, entry) in entries.prefix(limit).enumerated() {
            let ext = (entry.name as NSString).pathExtension
            let url = dir.appendingPathComponent("\(game.guid)-\(i).\(ext)")
            if let d = try? Data(contentsOf: url) { out.append(d); continue }
            let d = try await zip.data(of: entry)
            try? d.write(to: url, options: .atomic)
            out.append(d)
        }
        return out
    }

    /// The metadata archive as a source for single entries; its directory is
    /// not needed because the media index already holds the entries.
    private func metadataZip(_ c: ExoCollection, priority: Int) -> ZipArchive? {
        guard let session = shelves[c.id]?.session, let file = shelves[c.id]?.meta?.file(atPath: c.metadataArchive) else { return nil }
        return ZipArchive(source: TorrentFileSource(session: session, file: file, priority: priority), entries: [])
    }

    static func thumbnail(_ data: Data, maxPixels: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Launch

    /// The ways to start the game. For DOSBox: eXo's default config first,
    /// then the alternatives named in its `exception.bat` menu. For ScummVM:
    /// each edition, version and music choice eXo's launcher would offer.
    public func configurations(for game: Game) -> [GameConfiguration] {
        if ExoCollection.named(game.collection)?.launcher == .scummvm {
            let folder = gameFolderURL(game)
            return ScummVMGame.choices(in: folder).map {
                GameConfiguration(file: $0.key, label: ScummVMGame.label($0, gameFolderName: folder.lastPathComponent))
            }
        }
        let folder = configFolderURL(game)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasPrefix("dosbox") && $0.lowercased().hasSuffix(".conf") }
            .sorted { a, b in a.lowercased() == "dosbox.conf" || (b.lowercased() != "dosbox.conf" && a < b) }
        let menu = (try? ConfPatcher.readLatin1(folder.appendingPathComponent("exception.bat"))).map(ExceptionMenu.parse) ?? [:]
        return files.map { f in
            GameConfiguration(file: f, label: menu[f.lowercased()] ?? (f.lowercased() == "dosbox.conf" ? "Default" : f))
        }
    }

    /// eXo's note about an installed ScummVM game, which its launcher shows
    /// before starting it.
    public func note(for game: Game) -> String? {
        guard ExoCollection.named(game.collection)?.launcher == .scummvm else { return nil }
        return ScummVMGame.note(in: gameFolderURL(game))
    }

    /// Starts the game under DOSBox Staging or ScummVM. The process is
    /// returned so the caller can watch for it to end. A ScummVM game is
    /// shown to `scummvm --detect` first, which takes a second or two.
    public func launch(_ game: Game, options: LaunchOptions) async throws -> Process {
        let c = try collection(of: game)
        guard shelves[c.id]?.state.installed[game.guid] != nil, FileManager.default.fileExists(atPath: gameFolderURL(game).path) else {
            throw EngineError.notInstalled(game.title)
        }
        let logDir = paths.support(c).appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let p: Process
        switch c.launcher {
        case .dosbox: p = try dosboxProcess(game, c, options)
        case .scummvm: p = try await scummvmProcess(game, c, options)
        }

        let log = logURL(for: game)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        p.standardOutput = logHandle
        p.standardError = logHandle
        let id = game.id
        p.terminationHandler = { [weak self] _ in
            try? logHandle.close()
            Task { await self?.ended(id) }
        }
        try p.run()
        running[game.id] = p
        shelves[c.id]?.state.installed[game.guid]?.lastPlayed = Date()
        shelves[c.id]?.state.installed[game.guid]?.playCount += 1
        saveState(c)
        return p
    }

    private func dosboxProcess(_ game: Game, _ c: ExoCollection, _ options: LaunchOptions) throws -> Process {
        guard let dosbox = options.dosbox else { throw EngineError.emulatorMissing("DOSBox Staging") }
        let confName = options.configuration ?? "dosbox.conf"
        let confURL = configFolderURL(game).appendingPathComponent(confName)
        guard FileManager.default.fileExists(atPath: confURL.path) else { throw EngineError.configMissing(confURL.path) }

        let launchDir = paths.support(c).appendingPathComponent("launch")
        try FileManager.default.createDirectory(at: launchDir, withIntermediateDirectories: true)
        let patched = ConfPatcher.patchConfig(try ConfPatcher.readLatin1(confURL), workingDirectory: paths.workingDirectory, generalMIDI: options.generalMIDI)
        let patchedURL = launchDir.appendingPathComponent("\(game.shortcode).conf")
        try ConfPatcher.writeLatin1(patched, to: patchedURL)
        ConfPatcher.patchGameBatches(gameFolder: gameFolderURL(game), workingDirectory: paths.workingDirectory)

        var overrides = "[sdl]\nfullscreen=\(options.fullscreen ? "true" : "false")\n"
        if let shader = options.shader.configText { overrides += shader }
        if !options.extraConfig.isEmpty { overrides += "\n" + options.extraConfig + "\n" }
        let overridesURL = launchDir.appendingPathComponent("\(game.shortcode)-overrides.conf")
        try overrides.write(to: overridesURL, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = dosbox
        p.currentDirectoryURL = paths.workingDirectory
        // The user's own Staging defaults load first; eXo's config, then
        // ours, override them. `--exit` closes DOSBox when the game ends.
        p.arguments = ["--nolocalconf", "--conf", patchedURL.path, "--conf", overridesURL.path, "--exit"]
        return p
    }

    private func scummvmProcess(_ game: Game, _ c: ExoCollection, _ options: LaunchOptions) async throws -> Process {
        guard let index = shelves[c.id]?.scummvmIndex else { throw EngineError.configMissing(Self.scummvmIndexEntry) }
        let folder = gameFolderURL(game)
        let saves = folder.appendingPathComponent("!saves")
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        let settings = ScummVMGame.Settings(fullscreen: options.fullscreen, pixelPerfect: options.shader != .unchanged)
        let plan = try ScummVMGame.plan(gameFolder: folder, choice: options.configuration.flatMap(ScummVMChoice.init(key:)),
                                        index: index, mt32: paths.mt32, savePath: saves, settings: settings)
        let release = ScummVM.release(forBuild: plan.build)
        guard let binary = options.scummvm ?? ScummVM.locate(version: release, emulators: paths.emulators) else {
            throw EngineError.emulatorMissing("ScummVM \(release)")
        }
        let ini = scummvmINI(c, build: plan.build)
        if !FileManager.default.fileExists(atPath: ini.path) {
            try FileManager.default.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "[scummvm]\n".write(to: ini, atomically: true, encoding: .utf8)
        }
        let start = try await scummvmStart(game, plan, binary: binary, ini: ini)
        let p = Process()
        p.executableURL = binary
        p.currentDirectoryURL = plan.runDirectory
        p.arguments = ["--config=\(ini.path)"] + plan.arguments(starting: start)
        return p
    }

    /// What ScummVM is to start: the index's id once `--detect` has found
    /// it in the run folder, or a target pinning the first part. Data it
    /// does not recognise would end in ScummVM's own launcher window, so
    /// that is an error here; the game's log gets what `--detect` said.
    private func scummvmStart(_ game: Game, _ plan: ScummVMGame.Plan, binary: URL, ini: URL) async throws -> String {
        let run = try await Self.runHeadless(binary, ScummVMGame.detectArguments(ini: ini, path: plan.runDirectory))
        let found = ScummVMGame.matching(ScummVMGame.detections(in: run.output), gameID: plan.gameID)
        guard !found.isEmpty else {
            let log = "scummvm --detect --path=\(plan.runDirectory.path) found no \(plan.gameID):\n\(run.output)\n\(run.errors)"
            try? log.write(to: logURL(for: game), atomically: true, encoding: .utf8)
            throw EngineError.gameNotRecognised(plan.runDirectory.path, plan.gameID)
        }
        guard let part = ScummVMGame.firstPart(found, gameID: plan.gameID) else { return plan.gameID }
        return await pinFirstPart(plan, part, binary: binary, ini: ini) ?? plan.gameID
    }

    /// Several detections of one id are several data files in one folder,
    /// and ScummVM starts whichever the folder lists first: part 1 on NTFS,
    /// where eXo's batch file runs, but any part on APFS, which lists in
    /// hash order. Each file is linked alone into a folder of its own, one
    /// recursive `--detect` over them says which file holds `part`, and a
    /// target of the build's ini starts the game from that file. Nil, and
    /// ScummVM's own pick, when that cannot be settled.
    private func pinFirstPart(_ plan: ScummVMGame.Plan, _ part: Int, binary: URL, ini: URL) async -> String? {
        let fm = FileManager.default
        let probe = fm.temporaryDirectory.appendingPathComponent("exoshelf-svm-probe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: probe) }
        let files = ScummVMGame.probeFiles(in: plan.runDirectory)
        for (i, name) in files.enumerated() {
            let dir = probe.appendingPathComponent(String(i))
            let source = plan.runDirectory.appendingPathComponent(name), copy = dir.appendingPathComponent(name)
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
            if (try? fm.linkItem(at: source, to: copy)) == nil { try? fm.copyItem(at: source, to: copy) }
        }
        let args = ScummVMGame.detectArguments(ini: ini, path: probe, recursive: true)
        guard let run = try? await Self.runHeadless(binary, args),
              let first = ScummVMGame.firstPartFile(ScummVMGame.detections(in: run.output), gameID: plan.gameID, files: files),
              first.part == part, let target = ScummVMGame.targetName(gameID: plan.gameID),
              let text = try? String(contentsOf: ini, encoding: .utf8),
              let pinned = ScummVMGame.pinning(text, gameID: plan.gameID, path: plan.runDirectory, filename: first.file),
              (try? pinned.write(to: ini, atomically: true, encoding: .utf8)) != nil else { return nil }
        return target
    }

    /// Runs ScummVM without a window (SDL's dummy drivers; otherwise every
    /// run flashes a Dock icon) and returns what it printed to standard
    /// output and error. One that has not finished after 30 seconds is
    /// stopped.
    static func runHeadless(_ binary: URL, _ arguments: [String]) async throws -> (output: String, errors: String) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("exoshelf-detect-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // Files, not pipes: nothing has to drain them while ScummVM runs.
        let outURL = dir.appendingPathComponent("out"), errURL = dir.appendingPathComponent("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }

        let p = Process()
        p.executableURL = binary
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["SDL_VIDEODRIVER"] = "dummy"
        env["SDL_AUDIODRIVER"] = "dummy"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err
        let watchdog = Task {
            try await Task.sleep(for: .seconds(30))
            if p.isRunning { p.terminate() }
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { _ in c.resume() }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
        let text = { (u: URL) in (try? Data(contentsOf: u)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        return (text(outURL), text(errURL))
    }

    private func ended(_ id: String) {
        running.removeValue(forKey: id)
    }

    public func isRunning(_ game: Game) -> Bool { running[game.id]?.isRunning == true }

    public func logURL(for game: Game) -> URL {
        paths.support.appendingPathComponent("\(game.collection)/logs/\(game.shortcode).log")
    }

    // MARK: - Maintenance

    public func pieceCacheBytes() async -> Int64 {
        var total: Int64 = 0
        for c in ExoCollection.all { total += await shelves[c.id]?.session?.cache.totalBytes ?? 0 }
        return total
    }

    public func clearPieceCache() async {
        for c in ExoCollection.all { await shelves[c.id]?.session?.cache.clear() }
    }

    public func shutdown() async {
        for c in ExoCollection.all { await shelves[c.id]?.session?.shutdown() }
    }
}

/// Reads eXo's `exception.bat` menus:
///
///     echo Press 2 to play 007 - Licence to Kill using DOSBox with CGA
///     if errorlevel = 2 goto dosboxC
///     :dosboxC
///     ".\emulators\dosbox\%dosbox%" -conf "%var%\dosboxC.conf" ...
///
/// and maps each config file to the text of its menu line.
enum ExceptionMenu {
    static func parse(_ text: String) -> [String: String] {
        var choiceText: [String: String] = [:]
        var choiceLabel: [String: String] = [:]
        var labelConf: [String: String] = [:]
        var currentLabel: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("echo press "), let m = line.firstMatch(of: /(?i)echo press (\w) to (.+)/) {
                choiceText[String(m.1).lowercased()] = cleanup(String(m.2))
            } else if lower.hasPrefix("if errorlevel"), let m = line.firstMatch(of: /(?i)errorlevel\s*=?\s*(\w+)\s+goto\s+(\S+)/) {
                choiceLabel[String(m.1).lowercased()] = String(m.2).lowercased()
            } else if line.hasPrefix(":") {
                currentLabel = String(line.dropFirst()).lowercased()
            } else if let label = currentLabel, labelConf[label] == nil,
                      let m = line.firstMatch(of: /(?i)-conf\s+"%var%\\([^"]+\.conf)"/) {
                labelConf[label] = String(m.1).lowercased()
            }
        }
        var out: [String: String] = [:]
        for (choice, text) in choiceText {
            if let label = choiceLabel[choice], let conf = labelConf[label], out[conf] == nil { out[conf] = text }
        }
        return out
    }

    /// "play 007 - Licence to Kill using DOSBox with CGA" → "Play using DOSBox with CGA".
    static func cleanup(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: " using ") { t = "Play using " + t[r.upperBound...] }
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

/// A counting semaphore for async code.
actor AsyncGate {
    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    /// Returns holding a slot; the caller must `signal()` exactly once.
    func wait() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            inUse -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
