import ExoShelfCore
import SwiftUI

struct GameGrid: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 138, maximum: 180), spacing: 18, alignment: .top)]

    var body: some View {
        let games = model.visibleGames
        if games.isEmpty {
            EmptyResults()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(games) { game in
                        GameCard(game: game, selected: model.selection == game.id)
                            .onTapGesture(count: 2) { primaryAction(game) }
                            .simultaneousGesture(TapGesture().onEnded { model.selection = game.id })
                            .contextMenu { GameContextMenu(game: game) }
                    }
                }
                .padding(20)
            }
            .background(.background)
        }
    }

    private func primaryAction(_ game: Game) {
        switch model.state(of: game) {
        case .installed: Task { await model.play(game) }
        default: model.install(game)
        }
    }
}

struct EmptyResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.query.isEmpty {
            ContentUnavailableView("Nothing Here Yet", systemImage: "tray", description: Text(emptyHint))
        } else {
            ContentUnavailableView.search(text: model.query)
        }
    }

    private var emptyHint: String {
        switch model.sidebar {
        case .installed: return "Games you download show up here."
        case .favorites: return "Star a game to keep it here."
        case .recent: return "Games you have played show up here."
        default: return "No games in this category."
        }
    }
}

struct GameCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(game: game)
                .aspectRatio(0.72, contentMode: .fit)
                .overlay(alignment: .topTrailing) { StatusBadge(game: game).padding(6) }
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                }
            Text(game.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text([model.searchesAllCollections ? game.collection : nil, game.year.map(String.init), game.genres.first]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// Box art, fetched out of the torrent the first time it is shown.
struct CoverView: View {
    @Environment(AppModel.self) private var model
    let game: Game
    var priority = 5
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image = image ?? model.cachedCover(game) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Placeholder(title: game.title, loading: !failed)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .task(id: game.id) {
            guard image == nil, model.cachedCover(game) == nil else { return }
            // Give a fast scroll a moment to pass before asking the swarm.
            try? await Task.sleep(for: .milliseconds(priority == 0 ? 0 : 250))
            guard !Task.isCancelled else { return }
            image = await model.cover(for: game, priority: priority)
            failed = image == nil && !Task.isCancelled
        }
    }

    private struct Placeholder: View {
        let title: String
        let loading: Bool

        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(white: 0.30), Color(white: 0.18)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(.footnote, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 10)
                    if loading {
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                }
            }
        }
    }
}

/// Installed tick or download progress over the cover.
struct StatusBadge: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        if let active = model.installs[game.id] {
            ProgressRing(fraction: active.phase.fraction)
                .frame(width: 22, height: 22)
                .padding(3)
                .background(.thinMaterial, in: Circle())
        } else {
            switch model.state(of: game) {
            case .installed:
                Image(systemName: model.running.contains(game.id) ? "play.circle.fill" : "checkmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .shadow(radius: 2)
            case .partial:
                Image(systemName: "pause.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .orange)
                    .shadow(radius: 2)
            case .notInstalled:
                EmptyView()
            }
        }
    }
}

struct ProgressRing: View {
    let fraction: Double?

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 3)
            if let f = fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, f))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

extension InstallPhase {
    /// Overall progress, or nil while it cannot be told.
    var fraction: Double? {
        switch self {
        case .preparing: return nil
        case .downloading(let p): return p.fraction * 0.95
        case .extracting(let f): return 0.95 + f * 0.05
        }
    }

    var summary: String {
        switch self {
        case .preparing(let what): return what
        case .downloading(let p):
            if p.unchokedPeers == 0 && p.completedBytes == 0 {
                return p.connectedPeers == 0 ? "Looking for peers…" : "Waiting for peers (\(p.connectedPeers) connected)…"
            }
            return "\(p.completedBytes.byteString) of \(p.totalBytes.byteString) · \(p.bytesPerSecond.rateString) · \(p.unchokedPeers) peers"
        case .extracting: return "Unpacking…"
        }
    }
}

struct GameContextMenu: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let state = model.state(of: game)
        if state == .installed {
            Button("Play") { Task { await model.play(game) } }
        } else if model.installs[game.id] != nil {
            Button("Cancel Download") { model.cancelInstall(game) }
        } else {
            Button(state == .notInstalled ? "Download" : "Resume Download") { model.install(game) }
        }
        Divider()
        Button(model.favorites.contains(game.id) ? "Remove from Favourites" : "Add to Favourites") {
            Task { await model.toggleFavorite(game) }
        }
        if state == .installed {
            Button("Show in Finder") { model.revealInFinder(game) }
            Divider()
            Button("Remove…", role: .destructive) {
                Task { await model.uninstall(game) }
            }
        }
    }
}
