import ExoShelfCore
import SwiftUI

struct GameDetail: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var configurations: [GameConfiguration] = []
    @State private var configuration: String = ""
    @State private var screenshots: [NSImage] = []
    @State private var confirmRemove = false
    @State private var note: String?
    @State private var scummvmRelease: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let note {
                    Label {
                        Text(note)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                }
                if !game.notes.isEmpty {
                    Text(game.notes)
                        .font(.body)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !screenshots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(screenshots.enumerated()), id: \.offset) { _, img in
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.none)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 150)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                }
                facts
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: game.id) {
            screenshots = await model.screenshots(for: game)
        }
        .task(id: model.state(of: game)) {
            configurations = await model.configurations(for: game)
            if !configurations.contains(where: { $0.file == configuration }) {
                let saved = model.chosenConfiguration(for: game)
                configuration = configurations.first(where: { $0.file == saved })?.file ?? configurations.first?.file ?? ""
            }
            note = await model.note(for: game)
        }
        .task(id: "\(model.state(of: game))|\(configuration)|\(model.scummvmReleases)") {
            scummvmRelease = await model.scummvmRelease(for: game, configuration: configuration.isEmpty ? nil : configuration)
        }

        .sheet(isPresented: Binding(get: { model.graphicsSheetGame == game.id }, set: { if !$0 { model.graphicsSheetGame = nil } })) {
            GameGraphicsSheet(game: game)
                .environment(model)
        }
        .confirmationDialog("Remove \(game.title)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.uninstall(game) } }
        } message: {
            Text("The game's folder is deleted, saved games included.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            CoverView(game: game, priority: 0)
                .aspectRatio(0.72, contentMode: .fit)
                .frame(width: 170)
            VStack(alignment: .leading, spacing: 10) {
                Text(game.title)
                    .font(.title.weight(.semibold))
                    .textSelection(.enabled)
                Text(byline)
                    .foregroundStyle(.secondary)
                if !game.playlists.isEmpty {
                    FlowChips(items: game.playlists)
                }
                Spacer(minLength: 4)
                actions
            }
        }
    }

    private var byline: String {
        var parts: [String] = []
        if let y = game.year { parts.append(String(y)) }
        if !game.developer.isEmpty { parts.append(game.developer) }
        if !game.genres.isEmpty { parts.append(game.genres.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        let state = model.state(of: game)
        let size = model.archiveSizes[game.id]
        VStack(alignment: .leading, spacing: 10) {
            if let active = model.installs[game.id] {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if let f = active.phase.fraction {
                            ProgressView(value: f).frame(maxWidth: 260)
                        } else {
                            ProgressView().progressViewStyle(.linear).frame(maxWidth: 260)
                        }
                        Button("Cancel") { model.cancelInstall(game) }
                    }
                    Text(active.phase.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                HStack(spacing: 10) {
                    switch state {
                    case .installed:
                        Button {
                            Task { await model.play(game, configuration: configuration.isEmpty ? nil : configuration) }
                        } label: {
                            Label(model.running.contains(game.id) ? "Running" : "Play", systemImage: "play.fill")
                                .frame(minWidth: 70)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.running.contains(game.id))
                        if configurations.count > 1 {
                            // Remembered only when the user picks one.
                            Picker("Configuration", selection: Binding(get: { configuration }, set: { new in
                                configuration = new
                                model.choose(configuration: new, for: game)
                            })) {
                                ForEach(configurations) { Text($0.label).tag($0.file) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                        }
                    case .partial(let have):
                        Button {
                            model.install(game)
                        } label: {
                            Label("Resume", systemImage: "arrow.down.circle.fill").frame(minWidth: 70)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        if let size { Text("\(have.byteString) of \(size.byteString)").foregroundStyle(.secondary) }
                    case .notInstalled:
                        Button {
                            model.install(game)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle.fill").frame(minWidth: 70)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        if let size { Text(size.byteString).foregroundStyle(.secondary) }
                    }
                    Button {
                        Task { await model.toggleFavorite(game) }
                    } label: {
                        Image(systemName: model.favorites.contains(game.id) ? "star.fill" : "star")
                            .foregroundStyle(model.favorites.contains(game.id) ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(model.favorites.contains(game.id) ? "Remove from Favourites" : "Add to Favourites")
                    Button {
                        model.graphicsSheetGame = game.id
                    } label: {
                        Image(systemName: model.customGraphics.contains(game.id) ? "sparkles.tv.fill" : "sparkles.tv")
                            .foregroundStyle(model.customGraphics.contains(game.id) ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(model.customGraphics.contains(game.id) ? "Graphics: this game has its own settings" : "Graphics for this game")
                    if state != .notInstalled {
                        Menu {
                            if state == .installed {
                                Button("Show in Finder") { model.revealInFinder(game) }
                                Button(isScummVM ? "Open ScummVM Log" : "Open DOSBox Log") { Task { await model.openLog(game) } }
                                Divider()
                            }
                            Button("Remove…", role: .destructive) { confirmRemove = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
            }
        }
    }

    private var isScummVM: Bool { ExoCollection.named(game.collection)?.launcher == .scummvm }

    private var emulator: String {
        guard isScummVM else { return "DOSBox Staging" }
        if model.scummvm != nil { return "Your ScummVM" + (scummvmRelease.map { " (eXo pins \($0))" } ?? "") }
        return scummvmRelease.map { "ScummVM \($0), as eXo pins it" } ?? "ScummVM"
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            fact("Collection", game.collection)
            fact("Runs under", emulator)
            fact("Developer", game.developer)
            fact("Publisher", game.publisher)
            fact("Released", game.year.map(String.init) ?? "")
            fact("Players", game.maxPlayers > 1 ? "Up to \(game.maxPlayers)" + (game.playMode.isEmpty ? "" : " · \(game.playMode)") : game.playMode)
            fact("Series", game.series.joined(separator: ", "))
            fact("Licence", game.source)
            fact("Rating", game.rating == "Not Rated" ? "" : game.rating)
            fact("Download", model.archiveSizes[game.id]?.byteString ?? "")
            fact("eXo folder", game.shortcode)
        }
        .font(.callout)
    }

    @ViewBuilder private func fact(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

/// eXo's feature tags as small capsules.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(items, id: \.self) { item in
            Text(item)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
    }
}
