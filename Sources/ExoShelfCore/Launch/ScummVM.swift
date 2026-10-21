import Foundation

/// Finds and installs ScummVM, which runs eXoScummVM. eXo pins each game to
/// one of seven Windows builds; on a Mac the same version comes from
/// scummvm.org's official disk image, kept per version in ExoShelf's own
/// folder so that several can sit side by side.
public enum ScummVM {
    static let appName = "ScummVM.app"

    /// eXo's build folders under `emulators/scmvm/`, and the official
    /// release that stands in for each. The root build (folder "") reports
    /// 2.8.0, whatever its ini claims; the three git snapshots get the
    /// release each grew into.
    public static let releases: [String: String] = [
        "": "2.8.0",
        "2.5": "2.5.0",
        "2.9.0": "2.9.0",
        "2026.1.0": "2026.1.0",
        "svn2.3_18903": "2.5.0",
        "svn2.8_9335": "2.8.0",
        "svn3.0.0git19492": "2026.1.0",
    ]

    /// The release that runs games eXo pins to `build`. A folder eXo adds
    /// later is taken at its word when it reads like a version.
    public static func release(forBuild build: String) -> String {
        if let r = releases[build] { return r }
        if build.first?.isNumber == true, build.allSatisfy({ $0.isNumber || $0 == "." }) {
            return build.split(separator: ".").count == 2 ? build + ".0" : build
        }
        return "2026.1.0"
    }

    static func diskImage(_ version: String) -> (String, URL) {
        let name = "scummvm-\(version)-macosx.dmg"
        return (name, URL(string: "https://downloads.scummvm.org/frs/scummvm/\(version)/\(name)")!)
    }

    static func binary(inApp app: URL) -> URL { app.appendingPathComponent("Contents/MacOS/scummvm") }

    /// ExoShelf's own copy of a release: `<emulators>/ScummVM <version>/ScummVM.app`.
    public static func ownApp(version: String, emulators: URL) -> URL {
        emulators.appendingPathComponent("ScummVM \(version)").appendingPathComponent(appName)
    }

    /// The release's binary: ExoShelf's own copy, else a ScummVM in
    /// `/Applications` or `~/Applications` of exactly that version.
    public static func locate(version: String, emulators: URL) -> URL? {
        let fm = FileManager.default
        let own = binary(inApp: ownApp(version: version, emulators: emulators))
        if fm.isExecutableFile(atPath: own.path) { return own }
        let home = fm.homeDirectoryForCurrentUser.path
        for apps in ["/Applications", "\(home)/Applications"] {
            let app = URL(fileURLWithPath: apps).appendingPathComponent(appName)
            if appVersion(app) == version, fm.isExecutableFile(atPath: binary(inApp: app).path) { return binary(inApp: app) }
        }
        return nil
    }

    /// A ScummVM the user picked, as an app or a binary.
    public static func locate(preferred path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let p = path.hasSuffix(".app") ? binary(inApp: URL(fileURLWithPath: path)).path : path
        return FileManager.default.isExecutableFile(atPath: p) ? URL(fileURLWithPath: p) : nil
    }

    /// Releases ExoShelf has installed for itself.
    public static func installedReleases(emulators: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: emulators.path)) ?? []
        return names.compactMap { n in
            guard n.hasPrefix("ScummVM ") else { return nil }
            let v = String(n.dropFirst("ScummVM ".count))
            return locate(version: v, emulators: emulators).map { _ in v }
        }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// The app's version from its Info.plist, without starting it.
    public static func appVersion(_ app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// Downloads an official release from scummvm.org into ExoShelf's own
    /// folder. Returns the binary.
    public static func install(version: String, emulators: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let (name, url) = diskImage(version)
        let folder = ownApp(version: version, emulators: emulators).deletingLastPathComponent()
        let app = try await DiskImageInstaller.install(from: url, named: name, app: appName, into: folder, progress: progress)
        return binary(inApp: app)
    }
}
