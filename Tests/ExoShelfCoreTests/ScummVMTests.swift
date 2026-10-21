import Foundation
import Testing
@testable import ExoShelfCore

@Suite struct ScummVMTests {
    static let index = ScummVMIndex(text: """
    5 Days A Stranger (Windows);ags:5daysastranger;scummvm.exe\r
    5 Days A Stranger;ags:5daysastranger2;scummvm.exe\r
    Lure of the Temptress (Multi-Platform);lure:lure;2.9.0\\scummvm.exe\r
    Maniac Mansion (Multi-Platform);scumm:maniac;2.9.0\\scummvm.exe\r
    Maniac Mansion Deluxe (Windows);ags:maniacdeluxe;scummvm.exe\r
    Above the Waves (Windows);atw;2026.1.0\\scummvm.exe\r
    Robin Hood (Multi-Platform);scumm:robin;svn2.8_9335\\scummvm.exe\r
    broken line\r

    """)

    /// A game folder laid out the way eXo's zips unpack.
    private func gameFolder(_ name: String, _ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exoshelf-svm-\(UUID().uuidString)").appendingPathComponent(name)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !path.hasSuffix("/") { try Data(text.utf8).write(to: url) }
        }
        return root
    }

    private let mt32 = URL(fileURLWithPath: "/lib/eXo/mt32")
    private let saves = URL(fileURLWithPath: "/saves")

    @Test func readsTheLaunchIndex() {
        let e = Self.index.entries
        #expect(e.count == 7)
        #expect(e[2] == ScummVMIndex.Entry(name: "Lure of the Temptress (Multi-Platform)", gameID: "lure:lure", build: "2.9.0"))
        #expect(e[0].build == "")
        #expect(e[5].gameID == "atw")
        #expect(e[6].build == "svn2.8_9335")
    }

    @Test func looksUpTheMostSpecificName() {
        let i = Self.index
        // An exact name beats a prefix that belongs to another game.
        #expect(i.lookup(["5 Days A Stranger"])?.gameID == "ags:5daysastranger2")
        // The edition is not listed, so the game folder answers.
        #expect(i.lookup(["Lure of the Temptress (DOS VGA)", "Lure of the Temptress (Multi-Platform)"])?.gameID == "lure:lure")
        #expect(i.lookup(["Maniac Mansion Deluxe (Windows)", "Maniac Mansion (Multi-Platform)"])?.gameID == "ags:maniacdeluxe")
        #expect(i.lookup(["lure of the temptress (multi-platform)"])?.build == "2.9.0")
        // findstr /b: a prefix match, the last line winning.
        #expect(i.lookup(["5 Days"])?.gameID == "ags:5daysastranger2")
        #expect(i.lookup(["Nothing"]) == nil)
    }

    @Test func listsEditionsVersionsAndMusic() throws {
        let folder = try gameFolder("Maniac Mansion (Multi-Platform)", [
            "Maniac Mansion (Amiga)/platform.txt": "amiga:\r\n",
            "Maniac Mansion (DOS v1)/menu.txt": "",
            "Maniac Mansion (DOS v1)/Maniac Mansion EGA/00.LFL": "",
            "Maniac Mansion (DOS v1)/Maniac Mansion CGA/video.txt": "--render-mode=cga:\r\n",
            "Maniac Mansion Deluxe (Windows)/sound.txt": "Sound Blaster:Roland MT32:\r\n",
            "Other Languages/German/x": "",
            "!saves/": "",
            "note.txt": "Press F5 for the menu.\r\n",
        ])
        let choices = ScummVMGame.choices(in: folder)
        #expect(choices == [
            ScummVMChoice(edition: "Maniac Mansion (Amiga)"),
            ScummVMChoice(edition: "Maniac Mansion (DOS v1)", version: "Maniac Mansion CGA"),
            ScummVMChoice(edition: "Maniac Mansion (DOS v1)", version: "Maniac Mansion EGA"),
            ScummVMChoice(edition: "Maniac Mansion Deluxe (Windows)", sound: "Sound Blaster"),
            ScummVMChoice(edition: "Maniac Mansion Deluxe (Windows)", sound: "Roland MT32"),
        ])
        let name = folder.lastPathComponent
        #expect(choices.map { ScummVMGame.label($0, gameFolderName: name) } == [
            "Amiga", "DOS v1 · CGA", "DOS v1 · EGA", "Deluxe (Windows) · Sound Blaster", "Deluxe (Windows) · Roland MT32",
        ])
        #expect(ScummVMGame.note(in: folder) == "Press F5 for the menu.")
        for c in choices { #expect(ScummVMChoice(key: c.key) == c) }
        #expect(ScummVMChoice(key: "nonsense") == nil)
    }

    @Test func buildsEXOsCommandLine() throws {
        let folder = try gameFolder("Lure of the Temptress (Multi-Platform)", [
            "Lure of the Temptress (DOS EGA)/disk1.ega": "",
            "Lure of the Temptress (DOS VGA)/Disk1.vga": "",
        ])
        let plan = try ScummVMGame.plan(gameFolder: folder, choice: nil, index: Self.index, mt32: mt32, savePath: saves, settings: .init())
        let run = folder.appendingPathComponent("Lure of the Temptress (DOS EGA)")
        #expect(plan.build == "2.9.0")
        #expect(plan.runDirectory == run)
        #expect(plan.arguments == [
            "-F", "--aspect-ratio", "--stretch-mode=pixel-perfect", "--opl-driver=nuked", "--output-rate=44100",
            "--savepath=/saves", "--path=\(run.path)", "lure:lure",
        ])

        let vga = ScummVMChoice(edition: "Lure of the Temptress (DOS VGA)")
        let full = try ScummVMGame.plan(gameFolder: folder, choice: vga, index: Self.index, mt32: mt32, savePath: saves,
                                        settings: .init(fullscreen: true, aspectRatio: false, pixelPerfect: false))
        #expect(full.arguments.first == "-f")
        #expect(!full.arguments.contains("--aspect-ratio") && !full.arguments.contains("--stretch-mode=pixel-perfect"))
        #expect(full.runDirectory.lastPathComponent == "Lure of the Temptress (DOS VGA)")
    }

    @Test func translatesPlatformsVideoAndSubtitles() throws {
        let folder = try gameFolder("Maniac Mansion (Multi-Platform)", [
            "Maniac Mansion (C64)/platform.txt": "c64:\r\n",
            "Maniac Mansion (Spectrum)/platform.txt": "sp48:\r\n",
            "Maniac Mansion (Odd)/platform.txt": "vic20:\r\n",
            "Maniac Mansion (DOS v1)/menu.txt": "",
            "Maniac Mansion (DOS v1)/platform.txt": "dos:\r\n",
            "Maniac Mansion (DOS v1)/Maniac Mansion CGA/video.txt": "--render-mode=cga:CGA\r\n",
            "Maniac Mansion (DOS v1)/Maniac Mansion CGA/subtitle.txt": "--subtitles:\r\n",
        ])
        func args(_ c: ScummVMChoice, subtitles: Bool = true) throws -> [String] {
            try ScummVMGame.plan(gameFolder: folder, choice: c, index: Self.index, mt32: mt32, savePath: saves,
                                 settings: .init(subtitles: subtitles)).arguments
        }
        #expect(try args(ScummVMChoice(edition: "Maniac Mansion (C64)")).contains("--platform=c64"))
        #expect(try args(ScummVMChoice(edition: "Maniac Mansion (Spectrum)")).contains("--platform=zx"))
        // ScummVM would reject the whole command line for an unknown code.
        #expect(try !args(ScummVMChoice(edition: "Maniac Mansion (Odd)")).contains { $0.hasPrefix("--platform") })
        let cga = ScummVMChoice(edition: "Maniac Mansion (DOS v1)", version: "Maniac Mansion CGA")
        let a = try args(cga)
        // platform.txt sits at the edition, video.txt in the version.
        #expect(a.contains("--platform=pc") && a.contains("--render-mode=cga") && a.contains("--subtitles"))
        #expect(try !args(cga, subtitles: false).contains("--subtitles"))
        #expect(a.last == "scumm:maniac")
    }

    @Test func picksTheMusicEXOsMenuOffers() throws {
        let folder = try gameFolder("Robin Hood (Multi-Platform)", [
            "Robin Hood (DOS)/sound.txt": "Sound Blaster:Roland MT32:Sound Canvas:Tandy\r\n",
            "Robin Hood (DOS)/mt32_rev0.txt": "",
            "Robin Hood (DOS)/mt32_audio.txt": "--music-volume=200:\r\n",
            "Robin Hood (DOS)/audio.txt": "--sfx-volume=150:\r\n",
        ])
        func args(_ sound: String) throws -> [String] {
            try ScummVMGame.plan(gameFolder: folder, choice: ScummVMChoice(edition: "Robin Hood (DOS)", sound: sound),
                                 index: Self.index, mt32: mt32, savePath: saves, settings: .init()).arguments
        }
        let mt = try args("Roland MT32")
        #expect(mt.contains("-emt32") && mt.contains("--multi-midi"))
        // mt32_rev0.txt asks for the first-generation ROMs.
        #expect(mt.contains("--extrapath=/lib/eXo/mt32/rev0"))
        // The choice's own audio file wins over the plain one.
        #expect(mt.contains("--music-volume=200") && !mt.contains("--sfx-volume=150"))
        let sc = try args("Sound Canvas")
        #expect(sc.contains("-efluidsynth") && sc.contains("--soundfont=/lib/eXo/mt32/SoundCanvas.sf2"))
        #expect(sc.contains("--sfx-volume=150"))
        #expect(try args("Tandy").contains("-epcjr"))
        let sb = try args("Sound Blaster")
        #expect(!sb.contains { $0.hasPrefix("-e") })
        let plan = try ScummVMGame.plan(gameFolder: folder, choice: nil, index: Self.index, mt32: mt32, savePath: saves, settings: .init())
        // No choice: the first entry of eXo's menu.
        #expect(!plan.arguments.contains("-emt32"))
        #expect(plan.build == "svn2.8_9335")
        #expect(ScummVM.release(forBuild: plan.build) == "2.8.0")
    }

    /// A row as ScummVM prints it: `%-30s %-58s %s`.
    private func row(_ id: String, _ description: String, _ path: String) -> String {
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        return "\(pad(id, 30)) \(pad(description, 58)) \(path)"
    }

    private func detectOutput(_ rows: [String]) -> String {
        """
        Using configuration file: /lib/ini/default.ini
        GameID                         Description                                                Full Path
        ------------------------------ ---------------------------------------------------------- ---------------------------------------------------------
        \(rows.joined(separator: "\n"))

        """
    }

    @Test func readsWhatDetectFound() {
        let amiga = "/lib/eXo/eXoScummVM/Gnome Ranger (Multi-Platform)/Gnome Ranger Amiga"
        let long = "Some Very Long Interactive Fiction Title, Being a Story (pt. 3/Amiga/ST)"
        let found = ScummVMGame.detections(in: detectOutput([
            row("glk:gnomeranger", "Gnome Ranger (pt. 2/Amiga/ST)", amiga),
            row("glk:gnomeranger", "Gnome Ranger (pt. 1/Amiga/ST)", amiga),
            // A description wider than its column leaves one space before the path.
            row("glk:somelongtitle", long, "/lib/x y/z"),
            "   ",
        ]))
        #expect(found == [
            .init(gameID: "glk:gnomeranger", description: "Gnome Ranger (pt. 2/Amiga/ST)", path: amiga),
            .init(gameID: "glk:gnomeranger", description: "Gnome Ranger (pt. 1/Amiga/ST)", path: amiga),
            .init(gameID: "glk:somelongtitle", description: long, path: "/lib/x y/z"),
        ])
        // An empty folder: warnings and no table.
        #expect(ScummVMGame.detections(in: "Using configuration file: /x.ini\nWARNING: ScummVM could not find any game in /x\n").isEmpty)
        #expect(ScummVMGame.detections(in: detectOutput([])).isEmpty)
        #expect(ScummVMGame.detections(in: "").isEmpty)
    }

    @Test func matchesTheIndexsID() {
        let found: [ScummVMGame.Detection] = [
            .init(gameID: "scumm:maniac", description: "Maniac Mansion (V1/DOS)", path: "/a"),
            .init(gameID: "scumm:zak", description: "Zak McKracken (V1/DOS)", path: "/a"),
        ]
        #expect(ScummVMGame.matching(found, gameID: "scumm:maniac").map(\.description) == ["Maniac Mansion (V1/DOS)"])
        #expect(ScummVMGame.matching(found, gameID: "SCUMM:Zak").count == 1)
        #expect(ScummVMGame.matching(found, gameID: "scumm:tentacle").isEmpty)
        // A bare id may be a target of eXo's ini: anything ScummVM sees counts.
        #expect(ScummVMGame.matching(found, gameID: "wage").count == 2)
        #expect(ScummVMGame.matching([], gameID: "wage").isEmpty)
    }

    @Test func findsTheFirstPart() {
        #expect(ScummVMGame.partNumber("Gnome Ranger (pt. 2/Amiga/ST)") == 2)
        #expect(ScummVMGame.partNumber("Knight Orc (pt.1/Spectrum 48)") == 1)
        #expect(ScummVMGame.partNumber("Gnome Ranger (pt. 12/PC)") == 12)
        #expect(ScummVMGame.partNumber("Maniac Mansion (DOS/English)") == nil)
        #expect(ScummVMGame.partNumber("Manuscript. 3") == nil)

        func d(_ desc: String) -> ScummVMGame.Detection { .init(gameID: "glk:gnomeranger", description: desc, path: "/a") }
        let parts = [d("Gnome Ranger (pt. 3/C64)"), d("Gnome Ranger (pt. 2/C64)"), d("Gnome Ranger (pt. 1/C64)")]
        #expect(ScummVMGame.firstPart(parts, gameID: "glk:gnomeranger") == 1)
        #expect(ScummVMGame.firstPart(Array(parts.prefix(2)), gameID: "glk:gnomeranger") == 2)
        // One detection, no part numbers, or no engine to pin: ScummVM's own pick stands.
        #expect(ScummVMGame.firstPart([parts[0]], gameID: "glk:gnomeranger") == nil)
        #expect(ScummVMGame.firstPart([d("Gnome Ranger (C64)"), d("Gnome Ranger (PC)")], gameID: "glk:gnomeranger") == nil)
        #expect(ScummVMGame.firstPart(parts, gameID: "gnomeranger") == nil)
    }

    @Test func probesEachDataFileAlone() throws {
        let dir = try gameFolder("Gnome Ranger Amiga", [
            "GAMEDAT2.DAT": "part two",
            "GAMEDAT1.DAT": "part one",
            "10": "picture",
            "platform.txt": "amiga",
            "Audio.TXT": "",
            ".DS_Store": "",
            "big.ogg": String(repeating: "x", count: 64),
            "Extras/manual.pdf": "",
        ])
        let files = ScummVMGame.probeFiles(in: dir, maxBytes: 32)
        #expect(files == ["10", "GAMEDAT1.DAT", "GAMEDAT2.DAT"])

        // One recursive --detect over probe/0, probe/1, probe/2.
        let found = ScummVMGame.detections(in: detectOutput([
            row("glk:gnomeranger", "Gnome Ranger (pt. 2/Amiga/ST)", "/tmp/probe/2"),
            row("glk:gnomeranger", "Gnome Ranger (pt. 1/Amiga/ST)", "/tmp/probe/1/"),
            row("glk:other", "Other (pt. 0)", "/tmp/probe/0"),
        ]))
        let first = ScummVMGame.firstPartFile(found, gameID: "glk:gnomeranger", files: files)
        #expect(first?.part == 1 && first?.file == "GAMEDAT1.DAT")
        #expect(ScummVMGame.firstPartFile(found, gameID: "glk:knightorc", files: files) == nil)
        #expect(ScummVMGame.firstPartFile(found, gameID: "glk:gnomeranger", files: ["only"]) == nil)
    }

    @Test func pinsTheFirstPartAsATarget() {
        let path = URL(fileURLWithPath: "/lib/eXo/eXoScummVM/Gnome Ranger (Multi-Platform)/Gnome Ranger Amiga")
        #expect(ScummVMGame.targetName(gameID: "glk:gnomeranger") == "exoshelf-gnomeranger")
        #expect(ScummVMGame.targetName(gameID: "wage") == nil)
        #expect(ScummVMGame.pinning("[scummvm]\n", gameID: "wage", path: path, filename: "x") == nil)

        let section = """
        [exoshelf-gnomeranger]
        gameid=gnomeranger
        engineid=glk
        path=\(path.path)
        filename=GAMEDAT1.DAT

        """
        let eXo = "[scummvm]\nfullscreen=false\n\n[atw]\ngameid=atw\n"
        let added = ScummVMGame.pinning(eXo, gameID: "glk:gnomeranger", path: path, filename: "GAMEDAT1.DAT")
        #expect(added == eXo + "\n" + section)
        // eXo's ini as Windows left it, without a final newline.
        #expect(ScummVMGame.pinning("[scummvm]\nmute=false", gameID: "glk:gnomeranger", path: path, filename: "GAMEDAT1.DAT")
                == "[scummvm]\nmute=false\n\n" + section)

        // A later pin replaces the section, wherever ScummVM moved it.
        let c64 = URL(fileURLWithPath: "/lib/C64")
        let moved = "[exoshelf-gnomeranger]\ngameid=gnomeranger\nengineid=glk\npath=/old\nfilename=GAMEDAT2.DAT\n\n[scummvm]\nmute=false\n"
        #expect(ScummVMGame.pinning(moved, gameID: "glk:gnomeranger", path: c64, filename: "GAME1.DAT") == """
        [exoshelf-gnomeranger]
        gameid=gnomeranger
        engineid=glk
        path=/lib/C64
        filename=GAME1.DAT

        [scummvm]
        mute=false

        """)
        let again = ScummVMGame.pinning(added!, gameID: "glk:gnomeranger", path: path, filename: "GAMEDAT1.DAT")
        #expect(again == added)
        // Another game's pin is a section of its own.
        let both = ScummVMGame.pinning(added!, gameID: "glk:knightorc", path: c64, filename: "GAMEDAT1.DAT")!
        #expect(both.hasPrefix(added!) && both.contains("[exoshelf-knightorc]\ngameid=knightorc\n"))
    }

    @Test func startsATargetInsteadOfTheID() throws {
        let folder = try gameFolder("Lure of the Temptress (Multi-Platform)", ["Lure of the Temptress (DOS EGA)/disk1.ega": ""])
        let plan = try ScummVMGame.plan(gameFolder: folder, choice: nil, index: Self.index, mt32: mt32, savePath: saves, settings: .init())
        let pinned = plan.arguments(starting: "exoshelf-lure")
        #expect(pinned.last == "exoshelf-lure")
        #expect(Array(pinned.dropLast()) == Array(plan.arguments.dropLast()))
        let ini = URL(fileURLWithPath: "/lib/ini/2.9.0.ini")
        #expect(ScummVMGame.detectArguments(ini: ini, path: plan.runDirectory)
                == ["--config=/lib/ini/2.9.0.ini", "--detect", "--path=\(plan.runDirectory.path)"])
        #expect(ScummVMGame.detectArguments(ini: ini, path: URL(fileURLWithPath: "/tmp/probe"), recursive: true)
                == ["--config=/lib/ini/2.9.0.ini", "--detect", "--recursive", "--path=/tmp/probe"])
    }

    @Test func refusesWhatItCannotStart() throws {
        let empty = try gameFolder("Nothing (DOS)", ["note.txt": "hi"])
        #expect(throws: ScummVMGame.PlanError.self) {
            try ScummVMGame.plan(gameFolder: empty, choice: nil, index: Self.index, mt32: mt32, savePath: saves, settings: .init())
        }
        let unknown = try gameFolder("Unknown Game (DOS)", ["Unknown Game (DOS)/a.dat": ""])
        #expect(throws: ScummVMGame.PlanError.self) {
            try ScummVMGame.plan(gameFolder: unknown, choice: nil, index: Self.index, mt32: mt32, savePath: saves, settings: .init())
        }
    }
}
