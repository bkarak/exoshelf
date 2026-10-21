#if DEBUG
import AppKit
import ExoShelfCore

/// Development aid, absent from release builds: with `EXOSHELF_DRIVER_DIR`
/// set, the app reads commands from `<dir>/cmd` (one per line) and writes
/// PNG snapshots of its own window, so the UI can be checked from a script.
///
///     select <shortcode>   query <text>   mode grid|list   sidebar all|installed
///     collection <id>      scope this|all   setup <collection>
///     install <shortcode>  play <shortcode>   settings   shot <name>
@MainActor
enum DebugDriver {
    static func start(model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["EXOSHELF_DRIVER_DIR"] else { return }
        let base = URL(fileURLWithPath: dir)
        let cmd = base.appendingPathComponent("cmd")
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(400))
                guard let text = try? String(contentsOf: cmd, encoding: .utf8), !text.isEmpty else { continue }
                try? FileManager.default.removeItem(at: cmd)
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    let arg = parts.count > 1 ? parts[1] : ""
                    switch parts.first ?? "" {
                    case "select": model.selection = model.allGames.first { $0.shortcode == arg }?.id
                    case "query": model.query = arg
                    case "mode": model.viewMode = arg == "list" ? .list : .grid
                    case "sidebar": model.sidebar = arg == "installed" ? .installed : .all
                    case "collection": if let c = ExoCollection.named(arg) { model.collection = c }
                    case "scope": model.searchScope = arg == "all" ? .all : .collection
                    case "setup": if let c = ExoCollection.named(arg) { Task { await model.runSetup(c) } }
                    case "install": if let g = model.allGames.first(where: { $0.shortcode == arg }) { model.install(g) }
                    case "play": if let g = model.allGames.first(where: { $0.shortcode == arg }) { await model.play(g) }
                    case "settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    case "wait": try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
                    case "shot": snapshot(to: base.appendingPathComponent("\(arg).png"))
                    case "views": dumpViews(to: base.appendingPathComponent("\(arg).txt"))
                    default: break
                    }
                }
            }
        }
    }

    /// Table and scroll views with their frames, for layout trouble that a
    /// snapshot only shows as an empty area.
    static func dumpViews(to url: URL) {
        var out = ""
        func walk(_ v: NSView, _ depth: Int) {
            let name = String(describing: type(of: v))
            if v is NSScrollView || v is NSTableView || v is NSClipView || name.contains("Sidebar") || name.contains("List") {
                let rows = (v as? NSTableView).map { " rows=\($0.numberOfRows)" } ?? ""
                out += String(repeating: " ", count: depth) + "\(name) \(v.frame) hidden=\(v.isHidden) alpha=\(v.alphaValue)\(rows)\n"
            }
            for sub in v.subviews { walk(sub, depth + 1) }
        }
        for w in NSApp.windows where w.isVisible { if let v = w.contentView?.superview { walk(v, 0) } }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    static func snapshot(to url: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 }
        for (i, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let out = i == 0 ? url : url.deletingPathExtension().appendingPathExtension("\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
        }
    }
}
#endif
