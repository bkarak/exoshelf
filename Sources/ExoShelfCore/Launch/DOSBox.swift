import Foundation

/// Finds DOSBox Staging, the emulator ExoShelf runs every game under, and
/// can install the official release into `~/Applications`.
public enum DOSBox {
    static let appName = "DOSBox Staging.app"

    public static var searchPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Applications/\(appName)/Contents/MacOS/dosbox",
            "\(home)/Applications/\(appName)/Contents/MacOS/dosbox",
            "/opt/homebrew/bin/dosbox",
            "/usr/local/bin/dosbox",
        ]
    }

    /// The configured binary if it exists, else the first one found.
    public static func locate(preferred: String? = nil) -> URL? {
        let fm = FileManager.default
        if let p = preferred, !p.isEmpty {
            let path = p.hasSuffix(".app") ? p + "/Contents/MacOS/dosbox" : p
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return searchPaths.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// `dosbox --version`'s first line, e.g. "dosbox-staging, version 0.83.0".
    public static func version(of binary: URL) async -> String? {
        await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = binary
            p.arguments = ["--version"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            p.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init)
                c.resume(returning: line)
            }
            do { try p.run() } catch { c.resume(returning: nil) }
        }
    }

    public enum InstallError: Error, CustomStringConvertible {
        case noMacBuild
        case mountFailed(String)
        case appMissing

        public var description: String {
            switch self {
            case .noMacBuild: return "The latest DOSBox Staging release has no macOS disk image."
            case .mountFailed(let s): return "Could not open the DOSBox Staging disk image: \(s)"
            case .appMissing: return "The disk image did not contain DOSBox Staging.app."
            }
        }
    }

    /// Downloads the latest official macOS release from GitHub and copies
    /// the app into `~/Applications`. Returns the emulator binary.
    public static func installLatest(progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let (assetName, assetURL) = try await latestMacDiskImage()
        let apps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        do {
            let app = try await DiskImageInstaller.install(from: assetURL, named: assetName, app: appName, into: apps, progress: progress)
            return app.appendingPathComponent("Contents/MacOS/dosbox")
        } catch DiskImageInstaller.Failure.appMissing {
            throw InstallError.appMissing
        } catch DiskImageInstaller.Failure.toolFailed(let s) {
            throw InstallError.mountFailed(s)
        }
    }

    /// The release page's redirect names the latest tag without touching
    /// the rate-limited API; the API is the fallback.
    static func latestMacDiskImage() async throws -> (String, URL) {
        let repo = "https://github.com/dosbox-staging/dosbox-staging"
        var head = URLRequest(url: URL(string: "\(repo)/releases/latest")!)
        head.httpMethod = "HEAD"
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let final = response.url?.lastPathComponent, final.hasPrefix("v") {
            let name = "dosbox-staging-macOS-\(final).dmg"
            let url = URL(string: "\(repo)/releases/download/\(final)/\(name)")!
            var check = URLRequest(url: url)
            check.httpMethod = "HEAD"
            if let (_, r) = try? await URLSession.shared.data(for: check), (r as? HTTPURLResponse)?.statusCode == 200 {
                return (name, url)
            }
        }
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let assets: [Asset]
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/dosbox-staging/dosbox-staging/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (json, _) = try await URLSession.shared.data(for: request)
        guard let release = try? JSONDecoder().decode(Release.self, from: json),
              let asset = release.assets.first(where: { $0.name.contains("macOS") && $0.name.hasSuffix(".dmg") }) else {
            throw InstallError.noMacBuild
        }
        return (asset.name, asset.browser_download_url)
    }
}
