import AppKit
import ExoShelfCore
import Observation
import SwiftUI

/// Settings the user can change, kept in UserDefaults.
struct Preferences: Equatable {
    var libraryPath: String
    var dosboxPath: String
    /// A ScummVM for every game; empty runs each with the release eXo pins.
    var scummvmPath: String
    var fullscreen: Bool
    var shader: DisplayShader
    var generalMIDI: ConfPatcher.GeneralMIDI
    var keepArchives: Bool

    static let defaultLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/ExoShelf").path

    static func load() -> Preferences {
        let d = UserDefaults.standard
        return Preferences(
            libraryPath: d.string(forKey: "libraryPath") ?? defaultLibrary,
            dosboxPath: d.string(forKey: "dosboxPath") ?? "",
            scummvmPath: d.string(forKey: "scummvmPath") ?? "",
            fullscreen: d.bool(forKey: "fullscreen"),
            shader: DisplayShader(rawValue: d.string(forKey: "shader") ?? "") ?? .sharp,
            generalMIDI: ConfPatcher.GeneralMIDI(rawValue: d.string(forKey: "generalMIDI") ?? "") ?? .soundfont,
            keepArchives: d.bool(forKey: "keepArchives")
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(libraryPath, forKey: "libraryPath")
        d.set(dosboxPath, forKey: "dosboxPath")
        d.set(scummvmPath, forKey: "scummvmPath")
        d.set(fullscreen, forKey: "fullscreen")
        d.set(shader.rawValue, forKey: "shader")
        d.set(generalMIDI.rawValue, forKey: "generalMIDI")
        d.set(keepArchives, forKey: "keepArchives")
    }
}

enum SidebarItem: Hashable {
    case all, installed, favorites, recent, downloading
    case feature(String)
    case genre(String)
    case decade(Int)
}

enum SortOrder: String, CaseIterable, Identifiable {
    case title = "Title"
    case yearNewest = "Newest first"
    case yearOldest = "Oldest first"
    case developer = "Developer"
    case rating = "Community rating"
    var id: String { rawValue }
}

enum ViewMode: String {
    case grid, list
}

/// Where a search looks.
enum SearchScope: Hashable {
    case collection, all
}

/// A download or install the user started.
struct ActiveInstall: Equatable {
    var phase: InstallPhase
    var startedAt = Date()
}

@MainActor
@Observable
final class AppModel {
    /// The app as a whole: the first run sets up at least one collection.
    enum Phase: Equatable {
        case loading
        case needsSetup
        case ready
    }

    /// One collection's setup, shown while it runs and when it failed.
    enum CollectionSetup: Equatable {
        case running(SetupStep)
        case failed(String)
    }

    var phase: Phase = .loading
    var preferences = Preferences.load() {
        didSet { preferences.save() }
    }

    private(set) var engine: ExoEngine
    /// The folder games install into (environment overrides included).
    var libraryPath: String { engine.paths.library.path }
    /// Collections whose catalogue is loaded.
    private(set) var readyCollections: [ExoCollection] = []
    private(set) var setups: [String: CollectionSetup] = [:]
    /// The collection the sidebar shows.
    var collection: ExoCollection = ExoCollection.named(UserDefaults.standard.string(forKey: "collection") ?? "") ?? .exoDOS {
        didSet {
            guard collection != oldValue else { return }
            UserDefaults.standard.set(collection.id, forKey: "collection")
            sidebar = .all
            refreshCategories()
        }
    }
    /// Every game of every ready collection, in shelf order.
    private(set) var allGames: [Game] = []
    /// The shown collection's games.
    private(set) var games: [Game] = []
    private var gamesByID: [String: Game] = [:]
    private var searches: [String: CatalogSearch] = [:]
    private var searchAll = CatalogSearch([])
    private(set) var genres: [(String, Int)] = []
    private(set) var features: [(String, Int)] = []
    private(set) var decades: [(Int, Int)] = []

    var query = ""
    var searchScope: SearchScope = .collection
    var sidebar: SidebarItem = .all
    var sort: SortOrder = .title
    var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .grid {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    var selection: Game.ID?

    private(set) var installStates: [String: InstallState] = [:]
    private(set) var installs: [String: ActiveInstall] = [:]
    private var installTasks: [String: Task<Void, Never>] = [:]
    private(set) var running: Set<String> = []
    private(set) var favorites: Set<String> = []
    private(set) var lastPlayed: [String: Date] = [:]
    private(set) var archiveSizes: [String: Int64] = [:]
    private(set) var stats: SessionStats?
    var alert: AlertMessage?

    private(set) var dosbox: URL?
    private(set) var dosboxVersion: String?
    var installingDOSBox: Double?
    /// The user's own ScummVM, when they picked one.
    private(set) var scummvm: URL?
    /// ScummVM releases ExoShelf installed for the games eXo pins to them.
    private(set) var scummvmReleases: [String] = []

    private let covers = NSCache<NSString, NSImage>()
    private var statsTask: Task<Void, Never>?

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        let prefs = Preferences.load()
        let paths = EnginePaths.fromEnvironment(library: URL(fileURLWithPath: prefs.libraryPath))
        engine = ExoEngine(paths: paths)
        covers.countLimit = 600
    }

    // MARK: - Lifecycle

    func start() async {
        await detectDOSBox()
        detectScummVM()
        readyCollections = await engine.load()
        if readyCollections.isEmpty {
            phase = .needsSetup
        } else {
            if !readyCollections.contains(collection) { collection = readyCollections[0] }
            await loadCatalogs()
            phase = .ready
        }
        startStatsLoop()
    }

    /// Sets up the collections one after another; the shelf opens on the
    /// first one ready.
    func runFirstSetup(_ collections: [ExoCollection], torrentFile: URL? = nil) async {
        for c in collections {
            await runSetup(c, torrentFile: collections.count == 1 ? torrentFile : nil)
        }
        if let first = collections.first(where: readyCollections.contains) {
            collection = first
            phase = .ready
        }
    }

    func runSetup(_ c: ExoCollection, torrentFile: URL? = nil) async {
        let data = torrentFile.flatMap { try? Data(contentsOf: $0) }
        setups[c.id] = .running(.downloadingTorrent)
        do {
            try await engine.setUp(c, torrent: data) { step in
                Task { @MainActor in self.setups[c.id] = .running(step) }
            }
            setups[c.id] = nil
            readyCollections = await engine.readyCollections
            await loadCatalogs()
        } catch {
            setups[c.id] = .failed(String(describing: error))
        }
    }

    func isReady(_ c: ExoCollection) -> Bool { readyCollections.contains(c) }

    /// Points the shelf at another library folder.
    func changeLibrary(to url: URL) async {
        guard url.path != preferences.libraryPath else { return }
        for task in installTasks.values { task.cancel() }
        await engine.shutdown()
        preferences.libraryPath = url.path
        engine = ExoEngine(paths: .fromEnvironment(library: url))
        installs = [:]
        await start()
    }

    private func loadCatalogs() async {
        let list = await engine.allGames.sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
        allGames = list
        gamesByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        searchAll = CatalogSearch(list)
        searches = Dictionary(grouping: list, by: \.collection).mapValues(CatalogSearch.init)
        refreshCategories()
        archiveSizes = await engine.archiveSizes()
        await refreshStates()
    }

    /// The shown collection's games, and the sidebar's features, decades
    /// and genres for them.
    private func refreshCategories() {
        games = allGames.filter { $0.collection == collection.id }
        var g: [String: Int] = [:], f: [String: Int] = [:], d: [Int: Int] = [:]
        for game in games {
            for x in game.genres { g[x, default: 0] += 1 }
            for x in game.playlists { f[x, default: 0] += 1 }
            if let dec = game.decade { d[dec, default: 0] += 1 }
        }
        genres = g.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        features = f.filter { $0.value >= 10 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        decades = d.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }


    func refreshStates() async {
        let shelf = await engine.shelfState()
        favorites = shelf.favorites
        lastPlayed = shelf.lastPlayed
        var states: [String: InstallState] = [:]
        // Only games with something on disk need a look at the file system.
        let fm = FileManager.default
        let lib = engine.paths.library
        for game in allGames {
            let hasRecord = shelf.installed.contains(game.id)
            let hasPart = fm.fileExists(atPath: lib.appendingPathComponent(game.archivePath + ".part").path)
            if hasRecord || hasPart {
                states[game.id] = await engine.installState(of: game)
            }
        }
        installStates = states
    }

    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let s = await self.engine.sessionStats()
                if s != self.stats { self.stats = s }
            }
        }
    }

    // MARK: - Browsing

    /// True while a search reaches past the shown collection, so results
    /// say where they come from.
    var searchesAllCollections: Bool {
        searchScope == .all && !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var visibleGames: [Game] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, searchScope == .all { return searchAll.search(q, in: subset(spanning: true)) }
        let subset = subset(spanning: false)
        if !q.isEmpty { return (searches[collection.id] ?? CatalogSearch([])).search(q, in: subset) }
        let shown = games
        var list = subset.map { s in shown.filter { s.contains($0.id) } } ?? shown
        switch sort {
        case .title: break
        case .yearNewest: list.sort { ($0.year ?? 0, $1.sortTitle) > ($1.year ?? 0, $0.sortTitle) }
        case .yearOldest: list.sort { ($0.year ?? 9999, $0.sortTitle) < ($1.year ?? 9999, $1.sortTitle) }
        case .developer: list.sort { ($0.developer.lowercased(), $0.sortTitle) < ($1.developer.lowercased(), $1.sortTitle) }
        case .rating: list.sort { ($0.communityRating, $1.sortTitle) > ($1.communityRating, $0.sortTitle) }
        }
        if sidebar == .recent { list.sort { (lastPlayed[$0.id] ?? .distantPast) > (lastPlayed[$1.id] ?? .distantPast) } }
        return list
    }

    /// The games the sidebar item picks; nil for all. Shelves of the user's
    /// own (installed, favourites, recent, downloads) span every collection
    /// when the search does; categories always belong to the shown one.
    private func subset(spanning: Bool) -> Set<String>? {
        let mine: (Set<String>) -> Set<String> = { ids in
            spanning ? ids : ids.filter { $0.hasPrefix(self.collection.id + ":") }
        }
        switch sidebar {
        case .all: return nil
        case .installed: return mine(Set(installStates.filter { $0.value == .installed }.keys))
        case .favorites: return mine(favorites)
        case .recent: return mine(Set(lastPlayed.keys))
        case .downloading:
            return mine(Set(installs.keys).union(installStates.filter { if case .partial = $0.value { return true }; return false }.keys))
        case .feature(let f): return Set(games.filter { $0.playlists.contains(f) }.map(\.id))
        case .genre(let g): return Set(games.filter { $0.genres.contains(g) }.map(\.id))
        case .decade(let d): return Set(games.filter { $0.decade == d }.map(\.id))
        }
    }

    func game(_ id: Game.ID?) -> Game? {
        guard let id else { return nil }
        return gamesByID[id]
    }

    /// Installed games of the shown collection.
    var installedCount: Int {
        installStates.filter { $0.value == .installed && $0.key.hasPrefix(collection.id + ":") }.count
    }

    func count(_ ids: some Collection<String>) -> Int {
        ids.filter { $0.hasPrefix(collection.id + ":") }.count
    }

    func state(of game: Game) -> InstallState { installStates[game.id] ?? .notInstalled }

    // MARK: - Covers

    func cachedCover(_ game: Game) -> NSImage? { covers.object(forKey: game.id as NSString) }

    func cover(for game: Game, priority: Int = 5) async -> NSImage? {
        if let img = covers.object(forKey: game.id as NSString) { return img }
        guard let data = try? await engine.cover(for: game, priority: priority), let img = NSImage(data: data) else { return nil }
        covers.setObject(img, forKey: game.id as NSString)
        return img
    }

    func screenshots(for game: Game) async -> [NSImage] {
        let data = (try? await engine.screenshots(for: game)) ?? []
        return data.compactMap(NSImage.init(data:))
    }

    // MARK: - Install, play, remove

    func install(_ game: Game) {
        guard installTasks[game.id] == nil else { return }
        installs[game.id] = ActiveInstall(phase: .preparing("Queued"))
        let keep = preferences.keepArchives
        let own = scummvm
        let id = game.id
        installTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.install(game, keepArchive: keep, scummvm: own) { phase in
                    Task { @MainActor in
                        guard self.installs[id] != nil else { return }
                        self.installs[id]?.phase = phase
                    }
                }
                self.installs[id] = nil
                self.installTasks[id] = nil
                await self.refreshStates()
                self.detectScummVM()
                self.notifyInstalled(game)
            } catch {
                self.installs[id] = nil
                self.installTasks[id] = nil
                await self.refreshStates()
                if !(error is CancellationError) {
                    self.alert = AlertMessage(title: "Could not install \(game.title)", message: String(describing: error))
                }
            }
        }
    }

    func cancelInstall(_ game: Game) {
        installTasks[game.id]?.cancel()
    }

    func uninstall(_ game: Game) async {
        cancelInstall(game)
        do {
            try await engine.uninstall(game)
        } catch {
            alert = AlertMessage(title: "Could not remove \(game.title)", message: String(describing: error))
        }
        await refreshStates()
    }

    func configurations(for game: Game) async -> [GameConfiguration] {
        await engine.configurations(for: game)
    }

    /// The configuration the user last picked for the game, if any.
    func chosenConfiguration(for game: Game) -> String? {
        UserDefaults.standard.string(forKey: "configuration.\(game.id)")
    }

    func choose(configuration: String, for game: Game) {
        UserDefaults.standard.set(configuration, forKey: "configuration.\(game.id)")
    }

    func note(for game: Game) async -> String? { await engine.note(for: game) }

    /// The ScummVM release eXo pins the game to, once it is installed.
    func scummvmRelease(for game: Game, configuration: String? = nil) async -> String? {
        await engine.scummvmRelease(for: game, configuration: configuration)
    }

    func play(_ game: Game, configuration: String? = nil) async {
        let launcher = ExoCollection.named(game.collection)?.launcher ?? .dosbox
        if launcher == .dosbox, dosbox == nil {
            alert = AlertMessage(title: "DOSBox Staging is needed", message: "ExoShelf runs DOS and Windows 3.x games under DOSBox Staging. Install it from Settings → Emulators.")
            return
        }
        let p = preferences
        let options = LaunchOptions(dosbox: dosbox, scummvm: scummvm, configuration: configuration ?? chosenConfiguration(for: game),
                                    fullscreen: p.fullscreen, shader: p.shader, generalMIDI: p.generalMIDI)
        // Already while ScummVM's --detect runs, a second or two.
        running.insert(game.id)
        do {
            let process: Process
            do {
                process = try await engine.launch(game, options: options)
            } catch EngineError.emulatorMissing(let name) where launcher == .scummvm {
                // A release went missing since the install, or this edition
                // is pinned to another one: fetch it and try once more.
                running.remove(game.id)
                guard await installScummVM(for: game, configuration: options.configuration, missing: name) else { return }
                running.insert(game.id)
                process = try await engine.launch(game, options: options)
            }
            lastPlayed[game.id] = Date()
            let id = game.id
            Task.detached {
                process.waitUntilExit()
                await MainActor.run { [weak self] in _ = self?.running.remove(id) }
            }
        } catch {
            running.remove(game.id)
            alert = AlertMessage(title: "Could not start \(game.title)", message: String(describing: error))
        }
    }

    /// Installs the ScummVM release the game needs, showing it as the
    /// game's download. False if it failed (the alert says why).
    private func installScummVM(for game: Game, configuration: String?, missing name: String) async -> Bool {
        guard let release = await engine.scummvmRelease(for: game, configuration: configuration) else { return false }
        installs[game.id] = ActiveInstall(phase: .preparing("Installing ScummVM \(release)"))
        defer { installs[game.id] = nil }
        do {
            _ = try await ScummVM.install(version: release, emulators: engine.paths.emulators)
            detectScummVM()
            return true
        } catch {
            alert = AlertMessage(title: "Could not install \(name)", message: String(describing: error))
            return false
        }
    }

    func toggleFavorite(_ game: Game) async {
        let on = !favorites.contains(game.id)
        await engine.setFavorite(game, on)
        if on { favorites.insert(game.id) } else { favorites.remove(game.id) }
    }

    func revealInFinder(_ game: Game) {
        let url = engine.paths.library.appendingPathComponent(game.gameFolder)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openLog(_ game: Game) async {
        let url = await engine.logURL(for: game)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }

    private func notifyInstalled(_ game: Game) {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: - DOSBox

    func detectScummVM() {
        scummvm = ScummVM.locate(preferred: preferences.scummvmPath)
        scummvmReleases = ScummVM.installedReleases(emulators: engine.paths.emulators)
    }

    func useScummVM(at path: String) {
        preferences.scummvmPath = path
        detectScummVM()
    }

    func detectDOSBox() async {
        dosbox = DOSBox.locate(preferred: preferences.dosboxPath)
        dosboxVersion = nil
        if let d = dosbox { dosboxVersion = await DOSBox.version(of: d) }
    }

    func installDOSBox() async {
        installingDOSBox = 0
        do {
            let binary = try await DOSBox.installLatest { f in
                Task { @MainActor in self.installingDOSBox = f }
            }
            preferences.dosboxPath = ""
            dosbox = binary
            dosboxVersion = await DOSBox.version(of: binary)
        } catch {
            alert = AlertMessage(title: "Could not install DOSBox Staging", message: String(describing: error))
        }
        installingDOSBox = nil
    }

    // MARK: - Storage

    func cacheSize() async -> Int64 { await engine.pieceCacheBytes() }

    func clearCache() async { await engine.clearPieceCache() }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Double {
    var rateString: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) + "/s" }
}
