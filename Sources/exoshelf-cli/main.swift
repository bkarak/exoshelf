import ExoShelfCore
import Foundation

// A command-line front end to the same engine the app uses: handy for
// scripting, and for watching the torrent side without a window.

let usage = """
usage: exoshelf-cli <command> [arguments]

  collections                 list eXo's collections and which are set up
  setup [collection] [torrent-file]
                              fetch a collection's catalogue (eXoDOS and eXo's official torrent by default)
  search <words...>           search every collection that is set up
  info <game>                 show a game: title, shortcode or id, optionally as <collection>/<game>
  install <game>              download and unpack a game, and the ScummVM release it needs
  play <game> [config]        run a game under DOSBox Staging or ScummVM
  uninstall <game>            remove an installed game
  installed                   list installed games
  stats                       catalogue and cache figures
  install-dosbox              put the latest DOSBox Staging into ~/Applications
  install-scummvm <version>   put an official ScummVM release into ExoShelf's own folder

  torrent-info <torrent>                      inspect a .torrent file
  zipls <torrent> <file[::inner.zip]> [text]  list a zip inside the torrent
  zipget <torrent> <file> <entry> <out>       extract one entry

environment: EXOSHELF_LIBRARY, EXOSHELF_SUPPORT, EXOSHELF_CACHES override the default folders,
EXOSHELF_DOSBOX and EXOSHELF_SCUMMVM the emulators (EXOSHELF_SCUMMVM replaces eXo's pinned releases).
"""

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func mb(_ bytes: Double) -> String { String(format: "%.1f MB", bytes / 1_048_576) }

func enginePaths() -> EnginePaths { .fromEnvironment() }

let env = ProcessInfo.processInfo.environment

func readyEngine() async -> ExoEngine {
    let engine = ExoEngine(paths: enginePaths())
    guard !(await engine.load()).isEmpty else { fail("Not set up yet: run `exoshelf-cli setup` first.") }
    return engine
}

/// A game by id, shortcode, title or launcher name, else the best search
/// hit; `eXoWin3x/maze` looks in one collection only.
func find(_ query: String, in engine: ExoEngine) async -> Game {
    var games = await engine.allGames
    var query = query
    if let slash = query.firstIndex(of: "/"), let c = ExoCollection.named(String(query[..<slash])) {
        games = games.filter { $0.collection == c.id }
        query = String(query[query.index(after: slash)...])
    }
    let q = query.lowercased()
    if let g = games.first(where: { $0.id.lowercased() == q || $0.guid.lowercased() == q || $0.shortcode.lowercased() == q || $0.title.lowercased() == q || $0.launcherName.lowercased() == q }) {
        return g
    }
    let hits = CatalogSearch(games).search(query)
    guard let first = hits.first else { fail("No game matches \"\(query)\".") }
    if hits.count > 1 {
        print("Taking \(first.title) (\(first.year.map(String.init) ?? "?"), \(first.collection)), the best of \(hits.count) matches.")
    }
    return first
}

func dosboxBinary() -> URL? { DOSBox.locate(preferred: env["EXOSHELF_DOSBOX"]) }
func scummvmOverride() -> URL? { ScummVM.locate(preferred: env["EXOSHELF_SCUMMVM"] ?? "") }

func printProgressLine(_ text: String) {
    FileHandle.standardOutput.write(Data(("\r\u{1B}[K" + text).utf8))
}

guard let command = args.first else { print(usage); exit(0) }

switch command {
case "collections":
    let engine = ExoEngine(paths: enginePaths())
    let ready = Set(await engine.load().map(\.id))
    for c in ExoCollection.all {
        let count = await engine.catalog(of: c)?.games.count
        let status = ready.contains(c.id) ? "\(count ?? 0) games" : "not set up"
        print("\(c.id.padding(toLength: 12, withPad: " ", startingAt: 0)) \(c.summary.padding(toLength: 20, withPad: " ", startingAt: 0)) \(status)")
    }

case "setup":
    let engine = ExoEngine(paths: enginePaths())
    await engine.load()
    var rest = Array(args.dropFirst())
    let named = rest.first.flatMap(ExoCollection.named)
    if named != nil { rest.removeFirst() }
    let collection = named ?? .exoDOS
    let torrent = rest.first.map { try? Data(contentsOf: URL(fileURLWithPath: $0)) } ?? nil
    if !rest.isEmpty, torrent == nil { fail("Cannot read \(rest[0]).") }
    let t0 = Date()
    try await engine.setUp(collection, torrent: torrent) { step in
        switch step {
        case .downloadingTorrent: print("Downloading eXo's \(collection.torrentFileName)...")
        case .readingArchiveIndex: print("Finding peers and reading the metadata archive's directory...")
        case .downloadingCatalog: print("Fetching the catalogue...")
        case .indexingArt: print("Indexing box art...")
        case .done: break
        }
    }
    let count = await engine.catalog(of: collection)?.games.count ?? 0
    let covers = await engine.media(of: collection)?.covers.count ?? 0
    print("\(collection.id) ready: \(count) games, \(covers) with box art, in \(Int(Date().timeIntervalSince(t0)))s.")

case "search":
    let engine = await readyEngine()
    let games = await engine.allGames
    let hits = CatalogSearch(games).search(args.dropFirst().joined(separator: " "))
    for g in hits.prefix(40) {
        let size = await engine.archiveFile(for: g).map { mb(Double($0.length)) } ?? "?"
        print("\(g.title) (\(g.year.map(String.init) ?? "?"))  \(g.collection)/\(g.shortcode)  \(g.genres.joined(separator: ", "))  \(size)")
    }
    if hits.count > 40 { print("... and \(hits.count - 40) more") }

case "info":
    guard args.count > 1 else { fail("usage: info <game>") }
    let engine = await readyEngine()
    let g = await find(args.dropFirst().joined(separator: " "), in: engine)
    let file = await engine.archiveFile(for: g)
    print(g.title, g.year.map { "(\($0))" } ?? "")
    print("Developer: \(g.developer)   Publisher: \(g.publisher)")
    print("Genres: \(g.genres.joined(separator: ", "))   Players: \(g.maxPlayers)")
    if !g.playlists.isEmpty { print("Features: \(g.playlists.joined(separator: ", "))") }
    print("Collection: \(g.collection)   Shortcode: \(g.shortcode)   Archive: \(g.archivePath) (\(file.map { mb(Double($0.length)) } ?? "missing"))")
    print("State: \(await engine.installState(of: g))")
    if let release = await engine.scummvmRelease(for: g) { print("ScummVM: \(release), as eXo pins it") }
    for c in await engine.configurations(for: g) { print("Config: \(c.file) — \(c.label)") }
    if let note = await engine.note(for: g) { print("eXo's note: \(note)") }
    print("")
    print(g.notes)

case "install":
    guard args.count > 1 else { fail("usage: install <game>") }
    let engine = await readyEngine()
    let g = await find(args.dropFirst().joined(separator: " "), in: engine)
    let t0 = Date()
    try await engine.install(g, scummvm: scummvmOverride()) { phase in
        switch phase {
        case .preparing(let what): printProgressLine(what + "...\n")
        case .downloading(let p):
            printProgressLine(String(format: "Downloading %@: %.0f%% of %@, %@/s, %d peers (%d unchoked)",
                                     g.title, p.fraction * 100, mb(Double(p.totalBytes)), mb(p.bytesPerSecond), p.connectedPeers, p.unchokedPeers))
        case .extracting(let f): printProgressLine(String(format: "Unpacking: %.0f%%", f * 100))
        }
    }
    print("\nInstalled \(g.title) in \(Int(Date().timeIntervalSince(t0)))s.")

case "play":
    guard args.count > 1 else { fail("usage: play <game> [config]") }
    let engine = await readyEngine()
    let g = await find(args[1], in: engine)
    let dosbox = dosboxBinary()
    if ExoCollection.named(g.collection)?.launcher == .dosbox, dosbox == nil {
        fail("DOSBox Staging not found. Install it from https://www.dosbox-staging.org or `brew install --cask dosbox-staging-app`.")
    }
    let options = LaunchOptions(dosbox: dosbox, scummvm: scummvmOverride(), configuration: args.count > 2 ? args[2] : nil)
    let p: Process
    do { p = try await engine.launch(g, options: options) } catch { fail(String(describing: error)) }
    print("Running \(g.title) (pid \(p.processIdentifier)); log: \(await engine.logURL(for: g).path)")
    p.waitUntilExit()
    print("The emulator exited with status \(p.terminationStatus).")

case "uninstall":
    guard args.count > 1 else { fail("usage: uninstall <game>") }
    let engine = await readyEngine()
    let g = await find(args.dropFirst().joined(separator: " "), in: engine)
    try await engine.uninstall(g)
    print("Removed \(g.title).")

case "installed":
    let engine = await readyEngine()
    let installed = await engine.shelfState().installed
    for g in await engine.allGames where installed.contains(g.id) {
        print("\(g.title) (\(g.year.map(String.init) ?? "?"))  \(g.collection)/\(g.shortcode)")
    }

case "stats":
    let engine = await readyEngine()
    let installed = await engine.shelfState().installed
    for c in await engine.readyCollections {
        let games = await engine.catalog(of: c)?.games ?? []
        print("\(c.id): \(games.count) games, \(games.filter { installed.contains($0.id) }.count) installed")
    }
    print("piece cache: \(mb(Double(await engine.pieceCacheBytes())))")
    print("library: \(enginePaths().library.path)")
    let releases = ScummVM.installedReleases(emulators: enginePaths().emulators)
    if !releases.isEmpty { print("ScummVM releases: \(releases.joined(separator: ", "))") }

case "torrent-info":
    guard args.count >= 2 else { fail("usage: torrent-info <torrent>") }
    let meta = try TorrentMeta(data: Data(contentsOf: URL(fileURLWithPath: args[1])))
    print("name:", meta.name, "infohash:", meta.infoHashHex, ExoCollection.named(meta.name).map { "collection: \($0.id)" } ?? "")
    print("pieces:", meta.pieceCount, "x", meta.pieceLength, "total:", mb(Double(meta.totalLength)))
    print("files:", meta.files.count, "trackers:", meta.trackers.flatMap { $0 }.count)
    if let c = meta.comment { print("comment:", c) }

case "zipls", "zipget":
    guard args.count >= 3 else { fail("usage: zipls <torrent> <file> [filter]") }
    let meta = try TorrentMeta(data: Data(contentsOf: URL(fileURLWithPath: args[1])))
    // `outer.zip::inner.zip` opens a zip stored inside another.
    let path = args[2].components(separatedBy: "::")
    guard let file = meta.file(endingWith: path[0]) else { fail("no such file") }
    let session = TorrentSession(meta: meta, cacheDirectory: enginePaths().pieces)
    let t0 = Date()
    var zip = try await ZipArchive.open(TorrentFileSource(session: session, file: file))
    for inner in path.dropFirst() {
        guard let e = zip.entry(named: inner) else { fail("no entry \(inner)") }
        zip = try await zip.nested(e)
    }
    print("\(zip.entries.count) entries, directory read in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    if command == "zipls" {
        let filter = args.count > 3 ? args[3].lowercased() : ""
        for e in zip.entries where filter.isEmpty || e.name.lowercased().contains(filter) {
            print(e.method, e.compressedSize, e.uncompressedSize, e.localHeaderOffset, e.name)
        }
    } else {
        guard args.count >= 5, let entry = zip.entry(named: args[3]) else { fail("no such entry") }
        let data = try await zip.data(of: entry)
        try data.write(to: URL(fileURLWithPath: args[4]))
        print("wrote \(data.count) bytes in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    }

case "install-dosbox":
    print("Downloading the latest DOSBox Staging release from GitHub...")
    let binary = try await DOSBox.installLatest { f in printProgressLine(String(format: "  %.0f%%", f * 100)) }
    print("\nInstalled: \(binary.path)")
    print(await DOSBox.version(of: binary) ?? "")

case "install-scummvm":
    guard args.count > 1 else { fail("usage: install-scummvm <version>, e.g. \(ScummVM.releases[""] ?? "2.8.0")") }
    print("Downloading ScummVM \(args[1]) from scummvm.org...")
    let binary = try await ScummVM.install(version: args[1], emulators: enginePaths().emulators) { f in
        printProgressLine(String(format: "  %.0f%%", f * 100))
    }
    print("\nInstalled: \(binary.path)")

case "help", "-h", "--help":
    print(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
