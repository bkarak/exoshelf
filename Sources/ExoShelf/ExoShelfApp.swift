import AppKit
import ExoShelfCore
import SwiftUI

@main
struct ExoShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("ExoShelf", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    #if DEBUG
                    DebugDriver.start(model: model)
                    #endif
                    await model.start()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Game") {
                GameMenuCommands(model: model)
            }
            CommandGroup(after: .sidebar) {
                Button("Show as Grid") { model.viewMode = .grid }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Show as List") { model.viewMode = .list }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Keyboard access to the selected game.
struct GameMenuCommands: View {
    let model: AppModel

    var body: some View {
        let game = model.game(model.selection)
        let state = game.map(model.state(of:)) ?? .notInstalled
        Button("Play") {
            if let game { Task { await model.play(game) } }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(game == nil || state != .installed)

        Button("Download") {
            if let game { model.install(game) }
        }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(game == nil || state == .installed || game.map { model.installs[$0.id] != nil } == true)

        Divider()

        Button(game.map { model.favorites.contains($0.id) } == true ? "Remove from Favourites" : "Add to Favourites") {
            if let game { Task { await model.toggleFavorite(game) } }
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(game == nil)

        Button("Graphics…") {
            model.graphicsSheetGame = model.selection
        }
        .keyboardShortcut("g", modifiers: [.command, .option])
        .disabled(game == nil)

        Button("Show in Finder") {
            if let game { model.revealInFinder(game) }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(state != .installed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run from `swift run` there is no bundle to say we are a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
