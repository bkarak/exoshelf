import ExoShelfCore
import SwiftUI

struct GameList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let games = model.visibleGames
        if games.isEmpty {
            EmptyResults()
        } else {
            Table(games, selection: $model.selection) {
                TableColumn("") { game in
                    StatusGlyph(game: game)
                }
                .width(22)
                TableColumn("Title") { game in
                    HStack(spacing: 6) {
                        Text(game.title).lineLimit(1)
                        if model.searchesAllCollections {
                            Text(game.collection).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 180, ideal: 300)
                TableColumn("Year") { game in
                    Text(game.year.map(String.init) ?? "—").monospacedDigit()
                }
                .width(48)
                TableColumn("Developer") { game in
                    Text(game.developer).lineLimit(1).foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 170)
                TableColumn("Genre") { game in
                    Text(game.genres.joined(separator: ", ")).lineLimit(1).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 150)
                TableColumn("Size") { game in
                    Text(model.archiveSizes[game.id]?.byteString ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(70)
            }
            .contextMenu(forSelectionType: Game.ID.self) { ids in
                if let id = ids.first, let game = model.game(id) {
                    GameContextMenu(game: game)
                }
            } primaryAction: { ids in
                guard let id = ids.first, let game = model.game(id) else { return }
                if model.state(of: game) == .installed {
                    Task { await model.play(game) }
                } else {
                    model.install(game)
                }
            }
        }
    }
}

private struct StatusGlyph: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        if let active = model.installs[game.id] {
            ProgressRing(fraction: active.phase.fraction).frame(width: 13, height: 13)
        } else {
            switch model.state(of: game) {
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .partial:
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            case .notInstalled:
                if model.favorites.contains(game.id) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
            }
        }
    }
}
