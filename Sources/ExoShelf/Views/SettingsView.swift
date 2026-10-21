import ExoShelfCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            EmulatorSettings()
                .tabItem { Label("Emulators", systemImage: "display") }
            StorageSettings()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Games folder") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(model.libraryPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: model.libraryPath))
                        }
                        Button("Change…") { choose() }
                    }
                }
            }
            Toggle("Keep downloaded archives after unpacking", isOn: $model.preferences.keepArchives)
            Text("Archives let you reinstall a game without downloading it again, at the cost of disk space.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.changeLibrary(to: url) }
        }
    }
}

private struct EmulatorSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                DOSBoxStatusRow()
                LabeledContent("Location") {
                    HStack {
                        Text(model.dosbox?.path ?? "—")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { choose() }
                    }
                }
                if model.dosbox != nil {
                    Button("Install Latest Version") { Task { await model.installDOSBox() } }
                        .disabled(model.installingDOSBox != nil)
                }
            } footer: {
                Text("Runs eXoDOS and eXoWin3x.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ScummVMStatusRow()
                LabeledContent("Location") {
                    HStack {
                        Text(model.scummvm?.path ?? "eXo's pinned releases")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseScummVM() }
                    }
                }
                if model.scummvm != nil {
                    Button("Use eXo's Pinned Releases") { model.useScummVM(at: "") }
                }
            } footer: {
                Text("Runs eXoScummVM. eXo pins every game to the ScummVM version it tested it with; ExoShelf installs those official releases from scummvm.org into its own folder as games need them. Choose a ScummVM of your own to run every game with it instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Start games in full screen", isOn: $model.preferences.fullscreen)
                Picker("Display", selection: $model.preferences.shader) {
                    Text("Sharp pixels").tag(DisplayShader.sharp)
                    Text("CRT emulation").tag(DisplayShader.crt)
                    Text("As configured").tag(DisplayShader.unchanged)
                }
                Picker("General MIDI music", selection: $model.preferences.generalMIDI) {
                    Text("SoundCanvas soundfont").tag(ConfPatcher.GeneralMIDI.soundfont)
                    Text("System MIDI port").tag(ConfPatcher.GeneralMIDI.systemPort)
                }
                Text("eXo leaves General MIDI to Windows' built-in synth. A Mac has none, so ExoShelf plays it through FluidSynth with eXo's SoundCanvas soundfont. Choose the MIDI port for an external synth. MT-32 games always use eXo's MT-32 ROMs. Under ScummVM, sharp pixels mean whole-number scaling and the music is the edition's own choice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application, .unixExecutable]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            model.preferences.dosboxPath = url.path
            Task { await model.detectDOSBox() }
        }
    }

    private func chooseScummVM() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application, .unixExecutable]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            model.useScummVM(at: url.path)
        }
    }
}

private struct StorageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cacheBytes: Int64?

    var body: some View {
        Form {
            LabeledContent("Piece cache") {
                HStack {
                    Text(cacheBytes?.byteString ?? "…").foregroundStyle(.secondary).monospacedDigit()
                    Button("Clear") {
                        Task {
                            await model.clearCache()
                            cacheBytes = await model.cacheSize()
                        }
                    }
                }
            }
            Text("Torrent pieces holding box art, screenshots and the edges of games, kept so they are fetched only once. Capped at 2 GB; clearing it is always safe.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .task { cacheBytes = await model.cacheSize() }
    }
}
