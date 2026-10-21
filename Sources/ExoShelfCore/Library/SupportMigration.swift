import Foundation

/// Before eXoWin3x and eXoScummVM, ExoShelf kept one collection's files at
/// the top of its folders. They move into the eXoDOS folders, once; the
/// games themselves never move, since `eXo/eXoDOS` was always their place.
///
///     support/eXoDOS.torrent, catalog.json, media.json,
///             library.json, launch/, logs/       → support/eXoDOS/
///     caches/covers/*.jpg, caches/screenshots/*  → caches/.../eXoDOS/
///
/// The piece cache stays: it was always one folder per info hash.
enum SupportMigration {
    static let supportItems = ["eXoDOS.torrent", "catalog.json", "media.json", "library.json", "launch", "logs"]

    static func migrate(_ paths: EnginePaths) {
        let fm = FileManager.default
        let dos = ExoCollection.exoDOS
        let oldTorrent = paths.support.appendingPathComponent("eXoDOS.torrent")
        let oldState = paths.support.appendingPathComponent("library.json")
        guard fm.fileExists(atPath: oldTorrent.path) || fm.fileExists(atPath: oldState.path) else { return }

        let target = paths.support(dos)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for item in supportItems {
            move(paths.support.appendingPathComponent(item), to: target.appendingPathComponent(item))
        }
        for folder in ["covers", "screenshots"] {
            let old = paths.caches.appendingPathComponent(folder)
            let new = old.appendingPathComponent(dos.id)
            // Files only: the per-collection folders are directories.
            let names = ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).filter { $0.contains(".") }
            guard !names.isEmpty else { continue }
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
            for n in names { move(old.appendingPathComponent(n), to: new.appendingPathComponent(n)) }
        }
    }

    /// Moves unless something is already at the destination, in which case
    /// the newer layout wins and the old item stays where it was.
    private static func move(_ from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        try? fm.moveItem(at: from, to: to)
    }
}
