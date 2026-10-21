import ExoShelfCore
import SwiftUI
import UniformTypeIdentifiers

/// First run: where the games go, which collections to fetch, and the
/// emulators.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var pickingTorrent = false
    @State private var chosen: Set<String> = [ExoCollection.exoDOS.id]
    @State private var working = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.down.right.fill")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ExoShelf")
                            .font(.largeTitle.weight(.semibold))
                        Text("Browse, download and play eXo's collections.")
                            .foregroundStyle(.secondary)
                    }
                }

                Text("ExoShelf reads each catalogue straight out of eXo's official torrent, then fetches a game only when you ask for it. Setting up a collection downloads its catalogue and art index, a few megabytes; you can add the others later from the sidebar.")
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        LabeledContent("Games folder") {
                            HStack {
                                Text(model.libraryPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Button("Change…") { chooseLibrary() }
                                    .disabled(working)
                            }
                        }
                        Divider()
                        LabeledContent("Collections") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(ExoCollection.all) { c in
                                    Toggle(isOn: binding(c)) {
                                        HStack(spacing: 6) {
                                            Text(c.id)
                                            Text(c.summary).foregroundStyle(.secondary)
                                        }
                                    }
                                    .disabled(working)
                                }
                            }
                        }
                        Divider()
                        DOSBoxStatusRow()
                        ScummVMStatusRow()
                    }
                    .padding(6)
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ExoCollection.all.filter { chosen.contains($0.id) && model.setups[$0.id] != nil }) { c in
                        CollectionSetupProgress(collection: c)
                    }
                }

                HStack {
                    Button("Use a .torrent File…") { pickingTorrent = true }
                        .disabled(working || chosen.count != 1)
                        .help("For one collection at a time")
                    Spacer()
                    Button {
                        start()
                    } label: {
                        Text(anyFailed ? "Try Again" : "Set Up")
                            .frame(minWidth: 90)
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(working || chosen.isEmpty)
                }
            }
            .frame(maxWidth: 560)
            .padding(32)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $pickingTorrent, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                start(torrentFile: url) {
                    if access { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }

    private var selection: [ExoCollection] { ExoCollection.all.filter { chosen.contains($0.id) } }

    private var anyFailed: Bool {
        selection.contains { if case .failed = model.setups[$0.id] { return true }; return false }
    }

    private func binding(_ c: ExoCollection) -> Binding<Bool> {
        Binding(get: { chosen.contains(c.id) }, set: { on in
            if on { chosen.insert(c.id) } else { chosen.remove(c.id) }
        })
    }

    private func start(torrentFile: URL? = nil, then done: @escaping () -> Void = {}) {
        working = true
        Task {
            await model.runFirstSetup(selection, torrentFile: torrentFile)
            working = false
            done()
        }
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Games are unpacked here, in eXo's own folder layout."
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.changeLibrary(to: url) }
        }
    }
}

/// A collection that is not set up yet, in place of its games.
struct CollectionSetupView: View {
    @Environment(AppModel.self) private var model
    let collection: ExoCollection
    @State private var pickingTorrent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(collection.id)
                    .font(.largeTitle.weight(.semibold))
                Text(collection.summary)
                    .foregroundStyle(.secondary)
            }
            // No fixedSize here: at the narrow widths the split view tries
            // while laying out, it reports a height in the thousands, and
            // the whole window, sidebar included, grows to match.
            Text(explanation)
            CollectionSetupProgress(collection: collection)
            HStack {
                Button("Use a .torrent File…") { pickingTorrent = true }
                    .disabled(isRunning)
                Spacer()
                Button {
                    Task { await model.runSetup(collection) }
                } label: {
                    Text(isFailed ? "Try Again" : "Set Up \(collection.id)")
                        .frame(minWidth: 90)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(isRunning)
            }
        }
        .frame(maxWidth: 520)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $pickingTorrent, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                Task {
                    await model.runSetup(collection, torrentFile: url)
                    if access { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }

    private var explanation: String {
        let start = "ExoShelf reads the catalogue and art index out of eXo's \(collection.torrentFileName), a few megabytes, and fetches each game only when you ask for it."
        switch collection.launcher {
        case .dosbox where collection == .exoWin3x:
            return start + " Games run under DOSBox Staging, each in the Windows 3.1 setup eXo prepared for it."
        case .dosbox:
            return start + " Games run under DOSBox Staging."
        case .scummvm:
            return start + " Games run under ScummVM, in the version eXo chose for each; ExoShelf installs the official release a game needs along with it."
        }
    }

    private var isRunning: Bool {
        if case .running = model.setups[collection.id] { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = model.setups[collection.id] { return true }
        return false
    }
}

/// The steps of one collection's setup, or why it failed.
struct CollectionSetupProgress: View {
    @Environment(AppModel.self) private var model
    let collection: ExoCollection

    var body: some View {
        switch model.setups[collection.id] {
        case .running(let step):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SetupStepRow.all, id: \.title) { row in
                    SetupStepRow(row: row, current: step)
                }
                if let s = model.stats, s.connectedPeers > 0 {
                    Text("\(s.connectedPeers) peers connected · \(s.bytesPerSecond.rateString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        case .failed(let message):
            Label("\(collection.id): \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }
}

struct SetupStepRow: View {
    struct Row {
        let step: SetupStep
        let title: String
    }

    static let all = [
        Row(step: .downloadingTorrent, title: "Fetching eXo's torrent file"),
        Row(step: .readingArchiveIndex, title: "Finding peers, reading the metadata archive"),
        Row(step: .downloadingCatalog, title: "Fetching the catalogue"),
        Row(step: .indexingArt, title: "Indexing box art"),
    ]

    let row: Row
    let current: SetupStep

    var body: some View {
        let order = Self.all.map(\.step)
        let mine = order.firstIndex(of: row.step) ?? 0
        let now = order.firstIndex(of: current) ?? order.count
        HStack(spacing: 8) {
            Group {
                if mine < now || current == .done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if mine == now {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18)
            Text(row.title)
                .foregroundStyle(mine <= now ? .primary : .secondary)
        }
    }
}

/// Whether DOSBox Staging is there, and a way to get it.
struct DOSBoxStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent("DOSBox Staging") {
            if let progress = model.installingDOSBox {
                HStack {
                    ProgressView(value: progress).frame(width: 120)
                    Text("Installing DOSBox Staging…").foregroundStyle(.secondary)
                }
            } else if model.dosbox != nil {
                Label(model.dosboxVersion ?? "DOSBox Staging", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                HStack {
                    Text("Not found").foregroundStyle(.secondary)
                    Button("Install") { Task { await model.installDOSBox() } }
                }
            }
        }
    }
}

/// Which ScummVM runs eXoScummVM games.
struct ScummVMStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LabeledContent("ScummVM") {
            if let own = model.scummvm {
                // The app's name, or the binary's when the user picked one outside an app.
                Label(own.pathComponents.last(where: { $0.hasSuffix(".app") }) ?? own.lastPathComponent,
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help(own.path)
            } else if model.scummvmReleases.isEmpty {
                Text("Installed with the first game that needs it")
                    .foregroundStyle(.secondary)
            } else {
                Label(model.scummvmReleases.joined(separator: ", "), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}
