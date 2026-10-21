import Foundation

/// Makes eXo's Windows-flavoured DOSBox configs and batch files work under
/// DOSBox Staging on macOS.
///
/// eXo writes host paths relative to DOSBox's working directory (`eXo/`)
/// with backslashes: `mount c .\eXoDOS\DOOM`, `soundfont=.\mt32\SoundCanvas.sf2`.
/// On macOS a backslash is not a separator, so those paths must be rewritten,
/// but only those: the same `.\` prefix also appears in guest-side DOS text
/// (`copy .\tandy\*.* .\`), which must stay as it is. A `.\` token counts as
/// a host path only when the file or folder it names exists on the host.
///
/// Text is handled as ISO Latin-1 so every byte survives the round trip
/// (batch menus are in code page 437); inserted host paths are spliced in as
/// their UTF-8 bytes.
public enum ConfPatcher {
    /// How General MIDI music is played. eXo's Windows configs leave GM to
    /// the system synth; a Mac has none, so by default it goes to FluidSynth
    /// with the SoundCanvas soundfont eXo ships for the purpose.
    public enum GeneralMIDI: String, Sendable, CaseIterable, Codable {
        case soundfont
        case systemPort
    }

    /// Rewrites a game's `dosbox.conf` for Staging: absolute host paths and
    /// Staging's MIDI sections.
    public static func patchConfig(_ text: String, workingDirectory: URL, generalMIDI: GeneralMIDI = .soundfont) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rewritten = rewriteHostPaths(normalized) { body in
            guard !body.isEmpty else { return nil }
            let relative = body.replacingOccurrences(of: "\\", with: "/")
            guard let url = resolveIgnoringCase(relative, in: workingDirectory) else { return nil }
            return latin1Bytes(of: trimTrailingSlash(url.path))
        }
        var soundfont: String?
        if generalMIDI == .soundfont, let sf = resolveIgnoringCase("mt32/SoundCanvas.sf2", in: workingDirectory) {
            soundfont = latin1Bytes(of: sf.path)
        }
        return translateMIDI(rewritten, generalMIDISoundfont: soundfont)
    }

    /// Drops `key=value` lines of the given sections (lowercase names
    /// without brackets). `[autoexec]` is DOS commands and never touched.
    public static func removing(_ keys: [String: Set<String>], from conf: String) -> String {
        guard !keys.isEmpty else { return conf }
        var section = ""
        return conf.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                section = t.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
                return true
            }
            guard section != "autoexec", let eq = t.firstIndex(of: "="), let drop = keys[section] else { return true }
            let key = t[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            return !drop.contains(key)
        }.joined(separator: "\n")
    }

    /// Rewrites `.\` host paths in a game's batch file to `./`-relative ones
    /// with forward slashes. eXo's multi-disc `run.bat` mounts CD images that
    /// way, relative to the `eXo` folder DOSBox runs in.
    public static func patchBatch(_ text: String, workingDirectory: URL) -> String {
        rewriteHostPaths(text) { body in
            guard !body.isEmpty else { return nil }
            let relative = body.replacingOccurrences(of: "\\", with: "/")
            guard let url = resolveIgnoringCase(relative, in: workingDirectory) else { return nil }
            let rel = String(url.path.dropFirst(workingDirectory.standardizedFileURL.path.count + 1))
            return latin1Bytes(of: "./" + trimTrailingSlash(rel))
        }
    }

    /// Replaces each `.\token` for which `resolve` returns a path. A token
    /// runs to the next whitespace, or to the closing quote when quoted. A
    /// replacement with spaces is quoted, but only as a `mount`/`imgmount`
    /// argument: config values are read verbatim, quotes included.
    public static func rewriteHostPaths(_ text: String, resolve: (String) -> String?) -> String {
        var out = ""
        out.reserveCapacity(text.count + 128)
        var rest = Substring(text)
        while let r = rest.range(of: ".\\") {
            let before = rest[..<r.lowerBound]
            out += before
            let quoted = out.last == "\""
            let tail = rest[r.upperBound...]
            // `isWhitespace`, not a list of characters: in Swift "\r\n" is one
            // Character, and batch files keep their CRLF line ends.
            let end = tail.firstIndex(where: { quoted ? $0 == "\"" : $0.isWhitespace }) ?? tail.endIndex
            let body = String(tail[..<end])
            if let replacement = resolve(body) {
                if !quoted, replacement.contains(" "), isMountLine(out) {
                    out += "\"" + replacement + "\""
                } else {
                    out += replacement
                }
            } else {
                out += ".\\" + body
            }
            rest = tail[end...]
        }
        out += rest
        return out
    }

    /// Is the text after the last newline the start of a mount command?
    static func isMountLine(_ textSoFar: String) -> Bool {
        let start = textSoFar.lastIndex(where: \.isNewline).map { textSoFar.index(after: $0) } ?? textSoFar.startIndex
        let head = textSoFar[start...].drop { $0 == " " || $0 == "\t" || $0 == "@" }
        let cmd = head.split(separator: " ").first.map { $0.lowercased() } ?? ""
        return cmd == "mount" || cmd == "imgmount"
    }

    /// ECE's dotted `[midi]` keys (`mt32.romdir`, `fluid.soundfont`) become
    /// Staging's `[mt32]` and `[fluidsynth]` sections. With a GM soundfont
    /// given, a config that leaves MIDI to the system (`default`, `auto`,
    /// `port`, or no device at all) plays it through FluidSynth instead.
    /// New sections go in front of `[autoexec]`, whose lines run to the end
    /// of the file.
    public static func translateMIDI(_ conf: String, generalMIDISoundfont: String? = nil) -> String {
        var lines = conf.components(separatedBy: "\n")
        func sectionIndex(_ name: String) -> Int? {
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == name }
        }
        let hasMT32 = sectionIndex("[mt32]") != nil
        let hasFluid = sectionIndex("[fluidsynth]") != nil

        var out: [String] = []
        var section = ""
        var romdir: String?
        var soundfont: String?
        var device: String?
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                section = t.lowercased()
                out.append(line)
                continue
            }
            if section == "[midi]", !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") {
                let key = t[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if key == "mt32.romdir" { romdir = value; continue }
                if key == "fluid.soundfont" { soundfont = value; continue }
                if key.hasPrefix("mt32.") || key.hasPrefix("fluid.") { continue }
                if key == "mididevice" {
                    device = value.lowercased()
                    if Self.systemDevices.contains(device ?? ""), generalMIDISoundfont != nil {
                        out.append("mididevice=fluidsynth")
                        continue
                    }
                    if device == "default" {
                        out.append("mididevice=port")
                        continue
                    }
                }
            }
            out.append(line)
        }
        lines = out

        var additions: [String] = []
        if let gm = generalMIDISoundfont, device == nil {
            if let midi = sectionIndex("[midi]") {
                lines.insert("mididevice=fluidsynth", at: midi + 1)
            } else {
                additions += ["[midi]", "mididevice=fluidsynth", ""]
            }
            soundfont = soundfont ?? gm
        }
        if let d = device, Self.systemDevices.contains(d), let gm = generalMIDISoundfont {
            soundfont = soundfont ?? gm
        }
        if !hasMT32, let romdir {
            additions += ["[mt32]", "romdir=\(romdir)", ""]
        }
        if !hasFluid, let soundfont {
            additions += ["[fluidsynth]", "soundfont=\(soundfont)", ""]
        }
        guard !additions.isEmpty else { return lines.joined(separator: "\n") }
        let at = sectionIndex("[autoexec]") ?? lines.endIndex
        lines.insert(contentsOf: additions, at: at)
        return lines.joined(separator: "\n")
    }

    /// Device names that mean "whatever the system offers".
    static let systemDevices: Set<String> = ["default", "auto", "port", "win32", "coremidi", ""]

    /// Finds `relative` under `base`, matching each component without regard
    /// to case: eXo writes `cd odyssey` for a folder named `ODYSSEY`, which
    /// only matters on a case-sensitive volume.
    public static func resolveIgnoringCase(_ relative: String, in base: URL) -> URL? {
        let fm = FileManager.default
        var url = base.standardizedFileURL
        for part in relative.split(separator: "/") where !part.isEmpty && part != "." {
            guard part != ".." else { return nil }
            let candidate = url.appendingPathComponent(String(part))
            if fm.fileExists(atPath: candidate.path) {
                url = candidate
                continue
            }
            guard let names = try? fm.contentsOfDirectory(atPath: url.path),
                  let match = names.first(where: { $0.caseInsensitiveCompare(String(part)) == .orderedSame }) else { return nil }
            url = url.appendingPathComponent(match)
        }
        return url
    }

    static func trimTrailingSlash(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// The UTF-8 bytes of `s` as Latin-1 characters, so they come out as
    /// UTF-8 again when the patched text is written back as Latin-1.
    static func latin1Bytes(of s: String) -> String {
        String(s.utf8.map { Character(UnicodeScalar($0)) })
    }

    /// Reads a config or batch file byte for byte.
    public static func readLatin1(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    public static func writeLatin1(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .isoLatin1) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try data.write(to: url, options: .atomic)
    }

    /// Patches the game's own batch files (two levels deep) in place.
    /// Idempotent: a patched file has no `.\` host paths left to change.
    public static func patchGameBatches(gameFolder: URL, workingDirectory: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: gameFolder, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in walker {
            if walker.level > 2 { walker.skipDescendants(); continue }
            guard url.pathExtension.lowercased() == "bat", let text = try? readLatin1(url), text.contains(".\\") else { continue }
            let patched = patchBatch(text, workingDirectory: workingDirectory)
            if patched != text { try? writeLatin1(patched, to: url) }
        }
    }
}
