import Foundation
import Testing
@testable import ExoShelfCore

@Suite struct ConfPatcherTests {
    /// A throwaway `eXo` working directory with the folders eXo's configs name.
    private func workdir(_ name: String = "eXo") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exoshelf-conf-\(UUID().uuidString)").appendingPathComponent(name)
        for d in ["eXoDOS/DOOM", "eXoDOS/passport/floppy", "eXoDOS/comcon/cd", "mt32"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("mt32/SoundCanvas.sf2"))
        try Data().write(to: root.appendingPathComponent("eXoDOS/comcon/cd/CC1.iso"))
        return root
    }

    @Test func rewritesMountsToAbsolutePaths() throws {
        let wd = try workdir()
        let conf = "[autoexec]\r\nmount c .\\eXoDOS\\DOOM\r\nmount a .\\eXoDOS\\passport\\floppy\\ -t floppy\r\nc:\r\ncall run\r\n"
        let out = ConfPatcher.patchConfig(conf, workingDirectory: wd)
        #expect(out.contains("mount c \(wd.path)/eXoDOS/DOOM\n"))
        // Trailing separator dropped, options kept.
        #expect(out.contains("mount a \(wd.path)/eXoDOS/passport/floppy -t floppy"))
        #expect(!out.contains("\r"))
    }

    @Test func leavesGuestPathsAlone() throws {
        let wd = try workdir()
        let conf = "[autoexec]\ncopy .\\tandy\\*.* .\\\ncd .\\take2\\sc\noxyd.exe /9 .\\ .\\\n"
        let out = ConfPatcher.patchConfig(conf, workingDirectory: wd)
        #expect(out.contains("copy .\\tandy\\*.* .\\"))
        #expect(out.contains("cd .\\take2\\sc"))
        #expect(out.contains("oxyd.exe /9 .\\ .\\"))
    }

    @Test func quotesMountArgumentsWithSpacesButNotValues() throws {
        let wd = try workdir("eXo with space")
        let conf = "[fluidsynth]\nsoundfont=.\\mt32\\SoundCanvas.sf2\n[autoexec]\n@mount c .\\eXoDOS\\DOOM\nimgmount d \".\\eXoDOS\\comcon\\cd\\CC1.iso\" -t cdrom\n"
        let out = ConfPatcher.patchConfig(conf, workingDirectory: wd)
        #expect(out.contains("soundfont=\(wd.path)/mt32/SoundCanvas.sf2\n"))
        #expect(out.contains("@mount c \"\(wd.path)/eXoDOS/DOOM\""))
        // Already quoted by eXo: no second pair of quotes.
        #expect(out.contains("imgmount d \"\(wd.path)/eXoDOS/comcon/cd/CC1.iso\" -t cdrom"))
    }

    @Test func translatesECEMidiKeys() throws {
        let wd = try workdir()
        let conf = "[midi]\nmididevice=mt32\nfluid.soundfont=.\\mt32\\SoundCanvas.sf2\nmt32.romdir=.\\mt32\nmt32.reverse.stereo=false\n[sblaster]\n[autoexec]\nmount c .\\eXoDOS\\DOOM\nexit\n"
        let out = ConfPatcher.patchConfig(conf, workingDirectory: wd)
        #expect(out.contains("mididevice=mt32"))
        #expect(!out.contains("fluid.soundfont"))
        #expect(!out.contains("mt32.romdir"))
        #expect(!out.contains("mt32.reverse"))
        #expect(out.contains("[mt32]\nromdir=\(wd.path)/mt32"))
        #expect(out.contains("[fluidsynth]\nsoundfont=\(wd.path)/mt32/SoundCanvas.sf2"))
        // Everything after [autoexec] is autoexec: new sections go before it.
        let autoexec = try #require(out.range(of: "[autoexec]"))
        #expect(out.range(of: "[mt32]")!.lowerBound < autoexec.lowerBound)
        #expect(out.range(of: "[fluidsynth]")!.lowerBound < autoexec.lowerBound)
    }

    @Test func systemMidiGoesToTheSoundfont() throws {
        let wd = try workdir()
        let out = ConfPatcher.patchConfig("[midi]\nmididevice=default\n[autoexec]\nexit\n", workingDirectory: wd)
        #expect(out.contains("mididevice=fluidsynth"))
        #expect(out.contains("[fluidsynth]\nsoundfont=\(wd.path)/mt32/SoundCanvas.sf2"))

        // No MIDI settings at all: DOSBox would pick the system port.
        let bare = ConfPatcher.patchConfig("[sdl]\nfullscreen=false\n[autoexec]\nexit\n", workingDirectory: wd)
        #expect(bare.contains("[midi]\nmididevice=fluidsynth"))

        // With the system port chosen, eXo's "default" becomes Staging's "port".
        let port = ConfPatcher.patchConfig("[midi]\nmididevice=default\n", workingDirectory: wd, generalMIDI: .systemPort)
        #expect(port.contains("mididevice=port"))
        #expect(!port.contains("fluidsynth"))
    }

    @Test func leavesStagingMidiSectionsAsTheyAre() throws {
        let wd = try workdir()
        let conf = "[midi]\nmididevice=auto\n[fluidsynth]\nsoundfont=.\\mt32\\SoundCanvas.sf2\n[mt32]\nromdir=.\\mt32\n"
        let out = ConfPatcher.patchConfig(conf, workingDirectory: wd)
        #expect(out.components(separatedBy: "[mt32]").count == 2)
        #expect(out.contains("romdir=\(wd.path)/mt32"))
    }

    @Test func batchPathsBecomeRelative() throws {
        let wd = try workdir()
        let bat = "@echo off\r\nimgmount d \".\\eXoDOS\\comcon\\cd\\CC1.iso\" -t cdrom\r\nimgmount e .\\eXoDOS\\missing\\x.iso\r\n"
        let out = ConfPatcher.patchBatch(bat, workingDirectory: wd)
        #expect(out.contains("imgmount d \"./eXoDOS/comcon/cd/CC1.iso\" -t cdrom\r\n"))
        #expect(out.contains("imgmount e .\\eXoDOS\\missing\\x.iso"))
    }

    @Test func keepsCodePage437Bytes() throws {
        let wd = try workdir()
        let bytes: [UInt8] = Array("echo ".utf8) + [0xC9, 0xCD, 0xBB] + Array("\r\nmount c .\\eXoDOS\\DOOM\r\n".utf8)
        let url = wd.appendingPathComponent("eXoDOS/DOOM/run.bat")
        try Data(bytes).write(to: url)
        ConfPatcher.patchGameBatches(gameFolder: wd.appendingPathComponent("eXoDOS/DOOM"), workingDirectory: wd)
        let out = try Data(contentsOf: url)
        #expect(Array(out.prefix(8)) == Array("echo ".utf8) + [0xC9, 0xCD, 0xBB])
        #expect(String(decoding: out, as: UTF8.self).contains("mount c ./eXoDOS/DOOM"))
    }

    @Test func resolvesCaseInsensitively() throws {
        let wd = try workdir()
        #expect(ConfPatcher.resolveIgnoringCase("exodos/doom", in: wd) != nil)
        #expect(ConfPatcher.resolveIgnoringCase("eXoDOS/../etc", in: wd) == nil)
        #expect(ConfPatcher.resolveIgnoringCase("eXoDOS/nothing", in: wd) == nil)
    }

    @Test func parsesExceptionMenus() {
        let bat = """
        echo Press 1 to play 007 - Licence to Kill using DOSBox with EGA\r
        echo Press 2 to play 007 - Licence to Kill using DOSBox with CGA\r
        if errorlevel = 2 goto dosboxC\r
        if errorlevel = 1 goto dosboxE\r
        :dosboxE\r
        ".\\emulators\\dosbox\\%dosbox%" -conf "%var%\\dosbox.conf" -conf ".\\emulators\\dosbox\\options.conf"\r
        :dosboxC\r
        ".\\emulators\\dosbox\\%dosbox%" -conf "%var%\\dosboxC.conf" -conf ".\\emulators\\dosbox\\options.conf"\r
        """
        let menu = ExceptionMenu.parse(bat)
        #expect(menu["dosbox.conf"] == "Play using DOSBox with EGA")
        #expect(menu["dosboxc.conf"] == "Play using DOSBox with CGA")
    }
}
