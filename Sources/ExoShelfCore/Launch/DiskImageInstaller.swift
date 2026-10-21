import Foundation

/// Installs an app from a macOS disk image: downloads it, mounts it
/// read-only, and copies the app out with `ditto`, which keeps the
/// signature and extended attributes intact.
enum DiskImageInstaller {
    enum Failure: Error, CustomStringConvertible {
        case toolFailed(String)
        case appMissing

        var description: String {
            switch self {
            case .toolFailed(let s): return "Could not open the disk image: \(s)"
            case .appMissing: return "The disk image did not contain the app."
            }
        }
    }

    /// Returns the installed app. Any app of the same name in `directory`
    /// is replaced.
    static func install(from url: URL, named name: String, app appName: String, into directory: URL,
                        progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let delegate = DownloadProgressDelegate(progress: progress)
        let (tmp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.toolFailed("\(url.absoluteString) answered \(http.statusCode)")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("exoshelf-dmg-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let dmg = work.appendingPathComponent(name)
        try fm.moveItem(at: tmp, to: dmg)

        let mount = work.appendingPathComponent("mnt")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        let source = mount.appendingPathComponent(appName)
        guard fm.fileExists(atPath: source.path) else { throw Failure.appMissing }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(appName)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try run("/usr/bin/ditto", [source.path, target.path])
        return target
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw Failure.toolFailed(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }
}

final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: (@Sendable (Double) -> Void)?

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
