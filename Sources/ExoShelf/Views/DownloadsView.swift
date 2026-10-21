import ExoShelfCore
import SwiftUI

struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                if let s = model.stats {
                    Text("\(s.connectedPeers) peers · \(s.bytesPerSecond.rateString)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            let active = model.allGames.filter { model.installs[$0.id] != nil }
            if active.isEmpty {
                Text("Nothing downloading.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(active) { game in
                    if let install = model.installs[game.id] {
                        DownloadRow(game: game, install: install)
                    }
                }
            }
            Divider()
            Text("Games come straight from eXo's torrents. ExoShelf downloads only; it does not seed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
    }
}

private struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let install: ActiveInstall

    var body: some View {
        HStack(spacing: 10) {
            CoverView(game: game, priority: 0)
                .aspectRatio(0.72, contentMode: .fit)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title).lineLimit(1)
                if let f = install.phase.fraction {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(install.phase.summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                model.cancelInstall(game)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Cancel")
        }
    }
}
