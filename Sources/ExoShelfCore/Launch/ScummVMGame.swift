import Foundation

/// eXo's ScummVM launch index, `scummvm.txt` from `utilSVM.zip`: one line
/// per game folder or edition,
///
///     Lure of the Temptress (Multi-Platform);lure:lure;2.9.0\scummvm.exe
///
/// naming the engine and game id (or a target in the build's ini) and the
/// build eXo pins it to.
public struct ScummVMIndex: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let gameID: String
        /// eXo's build folder under `emulators/scmvm/`; empty for the root build.
        public let build: String
    }

    public let entries: [Entry]

    public init(text: String) {
        entries = text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count == 3, !f[0].isEmpty, !f[1].isEmpty else { return nil }
            let exe = f[2].replacingOccurrences(of: "\\", with: "/")
            let build = exe.lastIndex(of: "/").map { String(exe[..<$0]) } ?? ""
            return Entry(name: f[0], gameID: f[1], build: build)
        }
    }

    /// The entry for the most specific of `names` (version, edition, game
    /// folder). eXo's batch file looks names up with `findstr /b`, a prefix
    /// match where the last hit wins; an exact name is preferred here, since
    /// a prefix can belong to another game ("5 Days A Stranger" and
    /// "5 Days A Stranger (Windows)").
    public func lookup(_ names: [String]) -> Entry? {
        for n in names {
            if let e = entries.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return e }
        }
        for n in names where !n.isEmpty {
            let l = n.lowercased()
            if let e = entries.last(where: { $0.name.lowercased().hasPrefix(l) }) { return e }
        }
        return nil
    }
}

/// A way to start a ScummVM game: one of eXo's edition folders in the game
/// folder (`Maniac Mansion (DOS v1)`), a version inside it when the edition
/// has a `menu.txt` sub-menu, and the music when it offers a choice
/// (`sound.txt`).
public struct ScummVMChoice: Sendable, Hashable {
    public var edition: String
    public var version: String?
    public var sound: String?

    public init(edition: String, version: String? = nil, sound: String? = nil) {
        self.edition = edition
        self.version = version
        self.sound = sound
    }

    /// The choice as one string, for `GameConfiguration.file`. Folder names
    /// come from Windows, where `|` cannot occur.
    public var key: String { [edition, version ?? "", sound ?? ""].joined(separator: "|") }

    public init?(key: String) {
        let p = key.components(separatedBy: "|")
        guard p.count == 3, !p[0].isEmpty else { return nil }
        self.init(edition: p[0], version: p[1].isEmpty ? nil : p[1], sound: p[2].isEmpty ? nil : p[2])
    }
}

/// Starts eXoScummVM games the way eXo's `launch_svm.bat` does, without its
/// console menus.
public enum ScummVMGame {
    /// The editions, versions and music choices the game folder offers, in
    /// eXo's menu order. "Other Languages" is left out: eXo hands it to
    /// DREAMM, not ScummVM.
    public static func choices(in gameFolder: URL) -> [ScummVMChoice] {
        var out: [ScummVMChoice] = []
        for edition in subfolders(gameFolder) where edition != "Other Languages" {
            let dir = gameFolder.appendingPathComponent(edition)
            let versions: [String?] = exists(dir, "menu.txt") ? subfolders(dir).map { Optional($0) } : [nil]
            for version in versions {
                let run = version.map { dir.appendingPathComponent($0) } ?? dir
                let sounds = soundMenu([run, dir])
                for sound in sounds.isEmpty ? [nil] : sounds.map({ Optional($0) }) {
                    out.append(ScummVMChoice(edition: edition, version: version, sound: sound))
                }
            }
        }
        return out
    }

    /// "DOS v1 · EGA · Roland MT32" for the choice, without the game's
    /// title that every folder repeats.
    public static func label(_ choice: ScummVMChoice, gameFolderName: String) -> String {
        var base = gameFolderName
        if let r = base.range(of: #" \([^()]*\)$"#, options: .regularExpression) { base = String(base[..<r.lowerBound]) }
        var parts = [shorten(choice.edition, base)]
        if let v = choice.version { parts.append(shorten(v, base)) }
        if let s = choice.sound { parts.append(s) }
        return parts.joined(separator: " · ")
    }

    static func shorten(_ name: String, _ base: String) -> String {
        var t = name
        if t.lowercased().hasPrefix(base.lowercased()), t.count > base.count {
            t = String(t.dropFirst(base.count)).trimmingCharacters(in: .whitespaces)
        }
        if t.hasPrefix("("), t.hasSuffix(")"), !t.dropFirst().dropLast().contains("(") { t = String(t.dropFirst().dropLast()) }
        return t.isEmpty ? name : t
    }

    /// eXo's note about the game (`note.txt`), shown before it starts.
    public static func note(in gameFolder: URL) -> String? {
        guard let t = try? ConfPatcher.readLatin1(gameFolder.appendingPathComponent("note.txt")) else { return nil }
        let s = t.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// What `launch` needs besides the game.
    public struct Settings: Sendable {
        public var fullscreen = false
        /// 4:3 aspect correction, as eXo's setup offers.
        public var aspectRatio = true
        /// Whole-number scaling, eXo's default; off leaves ScummVM's own.
        public var pixelPerfect = true
        /// Turn subtitles on where the edition offers them (`subtitle.txt`).
        public var subtitles = true

        public init(fullscreen: Bool = false, aspectRatio: Bool = true, pixelPerfect: Bool = true, subtitles: Bool = true) {
            self.fullscreen = fullscreen
            self.aspectRatio = aspectRatio
            self.pixelPerfect = pixelPerfect
            self.subtitles = subtitles
        }
    }

    public struct Plan: Sendable, Equatable {
        /// eXo's build folder, which picks the ScummVM release and its ini.
        public let build: String
        public let gameID: String
        /// The folder with the game data, ScummVM's `--path`.
        public let runDirectory: URL
        /// Everything after the binary, except `--config`, which depends on
        /// the build.
        public let arguments: [String]

        /// `arguments` starting a target of the build's ini instead of the
        /// game id.
        public func arguments(starting target: String) -> [String] { arguments.dropLast() + [target] }
    }

    public enum PlanError: Error, CustomStringConvertible {
        case noEdition(String)
        case notInIndex(String)

        public var description: String {
            switch self {
            case .noEdition(let p): return "\(p) holds no game; the download may be incomplete."
            case .notInIndex(let n): return "\(n) is not in eXo's ScummVM launch index."
            }
        }
    }

    /// The command line for `choice` (eXo's first edition when nil). `mt32`
    /// is the folder with the MT-32 ROMs and `SoundCanvas.sf2`; saves go to
    /// `savePath`.
    public static func plan(gameFolder: URL, choice: ScummVMChoice?, index: ScummVMIndex, mt32: URL,
                            savePath: URL, settings: Settings) throws -> Plan {
        let all = choices(in: gameFolder)
        guard let pick = choice.flatMap({ c in all.first { $0 == c } }) ?? all.first else {
            throw PlanError.noEdition(gameFolder.path)
        }
        let editionDir = gameFolder.appendingPathComponent(pick.edition)
        let runDir = pick.version.map { editionDir.appendingPathComponent($0) } ?? editionDir
        let dirs = [runDir, editionDir]
        let names = [pick.version, pick.edition, gameFolder.lastPathComponent].compactMap { $0 }
        guard let entry = index.lookup(names) else { throw PlanError.notInIndex(gameFolder.lastPathComponent) }

        var args = [settings.fullscreen ? "-f" : "-F"]
        if settings.aspectRatio { args.append("--aspect-ratio") }
        args += firstField(dirs, "video.txt")
        if settings.subtitles { args += firstField(dirs, "subtitle.txt") }
        if settings.pixelPerfect { args.append("--stretch-mode=pixel-perfect") }
        if let p = firstField(dirs, "platform.txt").first, let code = platformCode(p) { args.append("--platform=\(code)") }
        args += soundArguments(pick.sound, dirs: dirs, mt32: mt32)
        args += ["--savepath=\(savePath.path)", "--path=\(runDir.path)", entry.gameID]
        return Plan(build: entry.build, gameID: entry.gameID, runDirectory: runDir, arguments: args)
    }

    // MARK: - Detection

    /// One game `scummvm --detect` recognised.
    public struct Detection: Sendable, Equatable {
        /// `engine:gameid`.
        public let gameID: String
        /// "Gnome Ranger (pt. 2/Amiga/ST)".
        public let description: String
        /// The folder the game was found in.
        public let path: String

        public init(gameID: String, description: String, path: String) {
            self.gameID = gameID
            self.description = description
            self.path = path
        }
    }

    /// ScummVM opens its own launcher window, not an error, when it does
    /// not recognise the data a start points at; so every start asks
    /// `--detect` first, with the build's ini and without a window.
    /// `recursive` also looks in the folders below `path`.
    public static func detectArguments(ini: URL, path: URL, recursive: Bool = false) -> [String] {
        ["--config=\(ini.path)", "--detect"] + (recursive ? ["--recursive"] : []) + ["--path=\(path.path)"]
    }

    /// The table `--detect` prints after its `---` line:
    ///
    ///     GameID                         Description                         Full Path
    ///     ------------------------------ ----------------------------------- ---------
    ///     glk:gnomeranger                Gnome Ranger (pt. 2/Amiga/ST)       /…/Gnome Ranger Amiga
    ///
    /// Warnings come before it; a folder with no game prints no table.
    static func detections(in output: String) -> [Detection] {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let rule = lines.firstIndex(where: { $0.hasPrefix("---") }) else { return [] }
        return lines[(rule + 1)...].compactMap { row in
            guard let first = row.first, !first.isWhitespace else { return nil }
            let fields = row.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let (description, path) = fields.count > 1 ? columns(fields[1]) : ("", "")
            return Detection(gameID: String(fields[0]), description: description, path: path)
        }
    }

    /// The description and path out of the rest of a row. The description
    /// is padded with spaces up to the path; one that fills its column is
    /// followed by a single space and the path, which is absolute.
    static func columns(_ rest: Substring) -> (String, String) {
        let t = rest.trimmingCharacters(in: .whitespaces)
        if let gap = t.range(of: "  ") {
            return (String(t[..<gap.lowerBound]), t[gap.upperBound...].trimmingCharacters(in: .whitespaces))
        }
        if let space = t.range(of: " /", options: .backwards) {
            return (String(t[..<space.lowerBound]), String(t[t.index(after: space.lowerBound)...]))
        }
        return (t, "")
    }

    /// The detections that are the game the index names. A bare id (`atw`,
    /// `wage`) may be a target of eXo's ini, whose game id only the ini
    /// knows, so any detection counts for it.
    static func matching(_ found: [Detection], gameID: String) -> [Detection] {
        guard gameID.contains(":") else { return found }
        return found.filter { $0.gameID.caseInsensitiveCompare(gameID) == .orderedSame }
    }

    /// "Gnome Ranger (pt. 2/Spectrum 48)" → 2. Level 9's trilogies keep
    /// their parts as sibling files, and only the description says which
    /// part a file is.
    static func partNumber(_ description: String) -> Int? {
        description.firstMatch(of: /\bpt\.\s*(\d+)/).flatMap { Int($0.1) }
    }

    /// The part to start at when one id was detected several times in the
    /// folder: ScummVM takes whichever file the folder lists first, which
    /// on APFS is not the first part. Nil when there is nothing to choose,
    /// or no part number to choose by.
    static func firstPart(_ matches: [Detection], gameID: String) -> Int? {
        guard matches.count > 1, gameID.contains(":") else { return nil }
        return matches.compactMap { partNumber($0.description) }.min()
    }

    /// Files to show `--detect` one by one to learn which is which part, in
    /// name order. A text adventure's parts are kilobytes: anything over
    /// 32 MB is art or audio, and eXo's own `.txt` files are not data.
    static func probeFiles(in dir: URL, maxBytes: Int = 32 << 20) -> [String] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        return items.compactMap { url -> String? in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), url.pathExtension.lowercased() != "txt",
                  let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true, (v.fileSize ?? 0) <= maxBytes else { return nil }
            return name
        }.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// The file holding the lowest part, out of a recursive `--detect` over
    /// a folder where each of `files` sits alone in a subfolder named by
    /// its position (`0`, `1`, ...).
    static func firstPartFile(_ found: [Detection], gameID: String, files: [String]) -> (part: Int, file: String)? {
        var best: (part: Int, file: String)?
        for d in matching(found, gameID: gameID) {
            guard let part = partNumber(d.description), let i = Int(URL(fileURLWithPath: d.path).lastPathComponent),
                  files.indices.contains(i) else { continue }
            if best.map({ part < $0.part }) ?? true { best = (part, files[i]) }
        }
        return best
    }

    /// The ini target that starts a game from one file of its folder.
    static func targetName(gameID: String) -> String? {
        let p = gameID.split(separator: ":", maxSplits: 1)
        return p.count == 2 ? "exoshelf-\(p[1])" : nil
    }

    /// `ini` with a target `[exoshelf-<id>]` that starts `gameID` from
    /// `filename` in `path`, replacing an earlier section of that name.
    static func pinning(_ ini: String, gameID: String, path: URL, filename: String) -> String? {
        let p = gameID.split(separator: ":", maxSplits: 1)
        guard p.count == 2, let target = targetName(gameID: gameID) else { return nil }
        let section = ["[\(target)]", "gameid=\(p[1])", "engineid=\(p[0])", "path=\(path.path)", "filename=\(filename)"]
        var lines = ini.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[\(target)]" }) {
            let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("[") } ?? lines.endIndex
            let blank = end < lines.endIndex ? [""] : []
            lines.replaceSubrange(start..<end, with: section + blank)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines += section
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// eXo's music menu entries and what each sets, from `launch_svm.bat`.
    static func soundArguments(_ choice: String?, dirs: [URL], mt32: URL) -> [String] {
        let base = ["--opl-driver=nuked", "--output-rate=44100"]
        guard let choice else { return base + firstField(dirs, "audio.txt") }
        var prefix = "sb_"
        var args = base
        switch choice {
        case "Tandy":
            prefix = "T_"
            args = ["--opl-driver=nuked", "-epcjr", "--output-rate=44100"]
        case "Creative Music System (CMS)":
            prefix = "CMS_"
            args = ["--opl-driver=nuked", "-ecms", "--output-rate=44100"]
        case "Roland MT32":
            prefix = "mt32_"
            let roms = dirs.contains { exists($0, "mt32_rev0.txt") } ? mt32.appendingPathComponent("rev0") : mt32
            args = ["--opl-driver=nuked", "-emt32", "--multi-midi", "--extrapath=\(roms.path)", "--output-rate=44100"]
        case "Sound Canvas":
            prefix = "sc_"
            let sf2 = ConfPatcher.resolveIgnoringCase("SoundCanvas.sf2", in: mt32) ?? mt32.appendingPathComponent("SoundCanvas.sf2")
            args = ["--opl-driver=nuked", "-efluidsynth", "--multi-midi", "--soundfont=\(sf2.path)", "--output-rate=44100"]
        case "James Woodcock's Enhanced Music":
            prefix = "eh_"
        default:
            break
        }
        let audio = firstField(dirs, prefix + "audio.txt")
        return args + (audio.isEmpty ? firstField(dirs, "audio.txt") : audio)
    }

    /// eXo's `platform.txt` abbreviations as ScummVM's platform codes. An
    /// unknown code is left out: ScummVM rejects the whole command line.
    static func platformCode(_ exo: String) -> String? {
        switch exo.trimmingCharacters(in: .whitespaces).lowercased() {
        case "dos", "pc": return "pc"
        case "amiga": return "amiga"
        case "atari", "st", "atari-st", "atarist": return "atari"
        case "c64": return "c64"
        case "nes": return "nes"
        case "sp48", "spectrum", "zx", "zxspectrum": return "zx"
        case "mac", "macintosh": return "macintosh"
        case "win", "windows": return "windows"
        case "fmtowns", "towns": return "fmtowns"
        case "pc98": return "pc98"
        case "pce", "pcengine": return "pce"
        case "segacd", "sega": return "segacd"
        case "3do": return "3do"
        case "cdi": return "cdi"
        case "apple2": return "apple2"
        case "apple2gs", "2gs": return "2gs"
        case "psx", "playstation": return "playstation"
        case "linux": return "linux"
        case "os2": return "os2"
        default: return nil
        }
    }

    /// The music choices of `sound.txt`: one line, entries split by `:`.
    static func soundMenu(_ dirs: [URL]) -> [String] {
        guard let line = firstLine(dirs, "sound.txt") else { return [] }
        return line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The first `:`-separated field of the file's first line, split into
    /// arguments, as eXo's `for /f "tokens=1 delims=:"` reads it.
    static func firstField(_ dirs: [URL], _ name: String) -> [String] {
        guard let line = firstLine(dirs, name) else { return [] }
        let field = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return field.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func firstLine(_ dirs: [URL], _ name: String) -> String? {
        for d in dirs {
            guard let url = ConfPatcher.resolveIgnoringCase(name, in: d),
                  let text = try? ConfPatcher.readLatin1(url) else { continue }
            return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
        return nil
    }

    static func exists(_ dir: URL, _ name: String) -> Bool {
        ConfPatcher.resolveIgnoringCase(name, in: dir) != nil
    }

    /// Subfolders in the order Windows' `dir` lists them; ExoShelf's own
    /// `!saves` and hidden folders are skipped.
    static func subfolders(_ dir: URL) -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { n in
            var isDir: ObjCBool = false
            return !n.hasPrefix(".") && !n.hasPrefix("!") && fm.fileExists(atPath: dir.appendingPathComponent(n).path, isDirectory: &isDir) && isDir.boolValue
        }.sorted { $0.lowercased() < $1.lowercased() }
    }
}
