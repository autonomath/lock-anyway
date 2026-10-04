import Foundation

public final class IdleLockLogger {
    public static let defaultLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LockAnyway.log")

    public let logURL: URL
    private let queue = DispatchQueue(label: "com.user.IdleLock.logger")
    private let timestampFormatter: ISO8601DateFormatter

    public init(logURL: URL = IdleLockLogger.defaultLogURL) {
        self.logURL = logURL
        self.timestampFormatter = ISO8601DateFormatter()
        self.timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func log(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let line = "\(timestamp) \(message)\n"
        queue.async { [logURL] in
            do {
                try FileManager.default.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                fputs("Lock Anyway log write failed: \(error)\n", stderr)
            }
        }
    }

    public func readTail(maxBytes: Int = 65_536) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return ""
        }
        defer {
            try? handle.close()
        }

        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Unable to read log: \(error.localizedDescription)"
        }
    }
}
