import Foundation

/// Writes to stderr and to ~/Library/Logs/Slant.log.
///
/// When the app is launched by LaunchServices (which is how it must be launched
/// for privacy permissions to be attributed to Slant rather than to the
/// terminal), stdio is discarded — so a file is the only way to observe a run.
public enum SlantLog {

    private static let url: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Slant.log")
    }()

    public static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }

    public static func reset() {
        try? FileManager.default.removeItem(at: url)
    }

    public static var path: String { url.path }
}
