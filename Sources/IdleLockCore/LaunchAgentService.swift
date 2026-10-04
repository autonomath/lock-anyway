import Foundation

public final class LaunchAgentService {
    public static let label = "com.user.idle-lock"

    public let plistURL: URL
    public let defaultInstalledAppURL: URL
    public let defaultInstalledExecutableURL: URL
    private let logger: IdleLockLogger

    public init(logger: IdleLockLogger) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.plistURL = home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
        self.defaultInstalledAppURL = URL(fileURLWithPath: "/Applications/Lock Anyway.app")
        self.defaultInstalledExecutableURL = defaultInstalledAppURL.appendingPathComponent("Contents/MacOS/IdleLock")
        self.logger = logger
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public func installLaunchAgent(loadNow: Bool = false, executableURL: URL? = nil) throws {
        let targetExecutableURL = executableURL ?? currentExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: targetExecutableURL.path) else {
            throw IdleLockError.launchAgentInstallFailed(
                "Expected executable is missing: \(targetExecutableURL.path). Install the app first."
            )
        }

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let logBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [targetExecutableURL.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": logBase.appendingPathComponent("LockAnyway.out.log").path,
            "StandardErrorPath": logBase.appendingPathComponent("LockAnyway.err.log").path
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        logger.log("LaunchAgent plist written at \(plistURL.path) executable=\(targetExecutableURL.path)")

        _ = try? runLaunchctl(["enable", serviceTarget()])
        if loadNow {
            _ = try? runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
            try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        }
    }

    public func disableLaunchAgent() throws {
        _ = try? runLaunchctl(["disable", serviceTarget()])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        logger.log("LaunchAgent disabled")
    }

    public func installForCurrentAppIfPossible(loadNow: Bool = false) {
        do {
            try installLaunchAgent(loadNow: loadNow, executableURL: currentExecutableURL())
        } catch {
            logger.log("Unable to install LaunchAgent automatically: \(error.localizedDescription)")
        }
    }

    private func currentExecutableURL() -> URL {
        if let executableURL = Bundle.main.executableURL {
            return executableURL
        }
        return defaultInstalledExecutableURL
    }

    private func serviceTarget() -> String {
        "gui/\(getuid())/\(Self.label)"
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw IdleLockError.launchAgentInstallFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
