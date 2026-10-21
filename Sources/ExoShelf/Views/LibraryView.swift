import ExoShelfCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var showDownloads = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            Group {
                if !model.isReady(model.collection) && !model.searchesAllCollections {
                    CollectionSetupView(collection: model.collection)
                        .id(model.collection.id)
                } else {
                    switch model.viewMode {
                    case .grid: GameGrid()
                    case .list: GameList()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 680)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        } detail: {
            if let game = model.game(model.selection) {
                GameDetail(game: game)
                    .id(game.id)
            } else {
                ContentUnavailableView("No Game Selected", systemImage: "square.stack.3d.down.right", description: Text("Pick a game to see its details."))
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Title, developer, genre, year")
        .searchScopes($model.searchScope) {
            Text(model.collection.id).tag(SearchScope.collection)
            Text("All Collections").tag(SearchScope.all)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View", selection: $model.viewMode) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                    Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
                .help("Show games as a grid or a list")

                Menu {
                    Picker("Sort By", selection: $model.sort) {
                        ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort order")
                .disabled(!model.query.isEmpty)

                Button {
                    showDownloads.toggle()
                } label: {
                    DownloadsToolbarLabel()
                }
                .help("Downloads")
                .popover(isPresented: $showDownloads, arrowEdge: .bottom) {
                    DownloadsView()
                        .environment(model)
                }
            }
        }
    }

    private var title: String {
        if model.searchesAllCollections { return "Search All Collections" }
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { return "Search \(model.collection.id)" }
        guard model.isReady(model.collection) else { return model.collection.id }
        switch model.sidebar {
        case .all: return "All Games"
        case .installed: return "Installed"
        case .favorites: return "Favourites"
        case .recent: return "Recently Played"
        case .downloading: return "Downloads"
        case .feature(let f): return f
        case .genre(let g): return g
        case .decade(let d): return "The \(d)s"
        }
    }

    private var subtitle: String {
        guard model.isReady(model.collection) || model.searchesAllCollections else { return "Not set up" }
        let n = model.visibleGames.count
        return n == 1 ? "1 game" : "\(n.formatted()) games"
    }
}

struct DownloadsToolbarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = model.installs.count
        HStack(spacing: 4) {
            Image(systemName: active > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
            if active > 0, let s = model.stats {
                Text(s.bytesPerSecond.rateString)
                    .font(.caption.monospacedDigit())
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.sidebar }, set: { model.sidebar = $0 ?? .all })) {
            Section("Library") {
                row("All Games", "square.stack.3d.down.right", .all, model.games.count)
                row("Installed", "internaldrive", .installed, model.installedCount)
                row("Favourites", "star", .favorites, model.count(model.favorites))
                row("Recently Played", "clock", .recent, model.count(model.lastPlayed.keys))
                if !model.installs.isEmpty {
                    row("Downloads", "arrow.down.circle", .downloading, model.installs.count)
                }
            }
            if !model.features.isEmpty {
                Section("Sound & Graphics") {
                    ForEach(model.features, id: \.0) { f in
                        row(f.0, icon(forFeature: f.0), .feature(f.0), f.1)
                    }
                }
            }
            if !model.decades.isEmpty {
                Section("Decades") {
                    ForEach(model.decades, id: \.0) { d in
                        row("\(d.0)s", "calendar", .decade(d.0), d.1)
                    }
                }
            }
            if !model.genres.isEmpty {
                Section("Genres") {
                    ForEach(model.genres, id: \.0) { g in
                        row(g.0, "tag", .genre(g.0), g.1)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            CollectionSwitcher()
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
        }
    }

    private func row(_ title: String, _ icon: String, _ item: SidebarItem, _ count: Int) -> some View {
        Label(title, systemImage: icon)
            .badge(count)
            .tag(item)
    }

    private func icon(forFeature f: String) -> String {
        let l = f.lowercased()
        if l.contains("mt-32") || l.contains("canvas") || l.contains("sound") || l.contains("ultrasound") || l.contains("music") { return "music.note" }
        if l.contains("3dfx") || l.contains("cga") || l.contains("ega") || l.contains("vga") || l.contains("reel") { return "display" }
        if l.contains("multiplayer") || l.contains("network") { return "person.2" }
        if l.contains("pcjr") || l.contains("tandy") { return "desktopcomputer" }
        return "sparkles"
    }
}

/// Which collection the sidebar shows; collections not set up yet are
/// listed too, and open on their setup.
struct CollectionSwitcher: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Collection", selection: $model.collection) {
            ForEach(ExoCollection.all) { c in
                Label {
                    Text(model.isReady(c) ? c.id : "\(c.id) (not set up)")
                } icon: {
                    Image(systemName: icon(c))
                }
                .tag(c)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .help("Collection")
    }

    private func icon(_ c: ExoCollection) -> String {
        switch c.id {
        case ExoCollection.exoWin3x.id: return "macwindow"
        case ExoCollection.exoScummVM.id: return "theatermasks"
        default: return "opticaldiscdrive"
        }
    }
}
