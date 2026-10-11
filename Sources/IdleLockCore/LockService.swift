import ApplicationServices
import AppKit
import Darwin
import Foundation

private final class LocalShortcutFocusWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

public protocol LockControlling {
    func availability(promptForAccessibility: Bool) -> LockAvailability
    func lockNow() throws
}

public struct LockStrategyResolver {
    public var cgSessionCandidates: [String]
    public var localSessionAPICandidates: [String]
    public var isExecutableFile: (String) -> Bool
    public var hasLocalSessionAPI: (String) -> Bool
    public var isAccessibilityTrusted: () -> Bool

    public init(
        cgSessionCandidates: [String] = LockService.defaultCGSessionCandidates,
        localSessionAPICandidates: [String] = LockService.defaultLocalSessionAPICandidates,
        isExecutableFile: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        hasLocalSessionAPI: @escaping (String) -> Bool = { LocalSessionLockAPI.isAvailable(at: $0) },
        isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.cgSessionCandidates = cgSessionCandidates
        self.localSessionAPICandidates = localSessionAPICandidates
        self.isExecutableFile = isExecutableFile
        self.hasLocalSessionAPI = hasLocalSessionAPI
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    public func resolve() -> LockAvailability {
        if let path = cgSessionCandidates.first(where: isExecutableFile) {
            return .available(.cgSession(path: path))
        }

        if let path = localSessionAPICandidates.first(where: hasLocalSessionAPI) {
            return .available(.localSessionAPI(path: path))
        }

        if isAccessibilityTrusted() {
            return .available(.keyboardShortcut)
        }

        return .unavailable(
            "Accessibility permission is required to send Control-Command-Q on this macOS version.",
            requiresAccessibilityPermission: true
        )
    }
}

public final class LockService: LockControlling {
    public static let defaultCGSessionCandidates = [
        "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
        "/System/Library/CoreServices/CGSession",
        "/usr/bin/CGSession",
        "/bin/CGSession"
    ]
    public static let defaultLocalSessionAPICandidates = [
        "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
        "/System/Library/PrivateFrameworks/login.framework/login",
        "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
    ]

    private let logger: IdleLockLogger
    private let resolverFactory: () -> LockStrategyResolver

    public init(
        logger: IdleLockLogger,
        resolverFactory: @escaping () -> LockStrategyResolver = { LockStrategyResolver() }
    ) {
        self.logger = logger
        self.resolverFactory = resolverFactory
    }

    public func availability(promptForAccessibility: Bool = false) -> LockAvailability {
        let resolved = resolverFactory().resolve()
        if resolved.strategy != nil || !promptForAccessibility || !resolved.requiresAccessibilityPermission {
            return resolved
        }

        requestAccessibilityPermission()
        return resolverFactory().resolve()
    }

    public func lockNow() throws {
        let available = availability(promptForAccessibility: true)
        guard let strategy = available.strategy else {
            throw IdleLockError.lockUnavailable(available.reason ?? "No lock strategy is available.")
        }

        switch strategy {
        case .cgSession(let path):
            try runCGSession(path: path)
        case .localSessionAPI(let path):
            try LocalSessionLockAPI.lock(using: path)
            logger.log("Lock request sent to the local macOS session API")
        case .keyboardShortcut:
            try postLockShortcut()
        }
    }

    public func requestAccessibilityPermission() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func openAccessibilityPermissionHelp() {
        requestAccessibilityPermission()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func runCGSession(path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-suspend"]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw IdleLockError.lockCommandFailed("Unable to run CGSession: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            throw IdleLockError.lockCommandFailed("CGSession exited with status \(process.terminationStatus).")
        }

        logger.log("Lock command sent with CGSession")
    }

    private func postLockShortcut() throws {
        guard AXIsProcessTrusted() else {
            throw IdleLockError.lockUnavailable("Accessibility permission is required to send Control-Command-Q.")
        }

        let focusWindow = makeLocalShortcutFocusWindow()
        defer { focusWindow.orderOut(nil) }

        NSApp.activate(ignoringOtherApps: true)
        focusWindow.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            throw IdleLockError.lockCommandFailed(
                "Lock Anyway could not take local focus, so it did not send a lock shortcut to the active app."
            )
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw IdleLockError.lockCommandFailed("Unable to create Control-Command-Q event source.")
        }

        let controlKey: CGKeyCode = 59
        let commandKey: CGKeyCode = 55
        let qKey: CGKeyCode = 12
        let noFlags = CGEventFlags(rawValue: 0)

        try postKey(source: source, keyCode: controlKey, keyDown: true, flags: [.maskControl])
        try postKey(source: source, keyCode: commandKey, keyDown: true, flags: [.maskControl, .maskCommand])
        try postKey(source: source, keyCode: qKey, keyDown: true, flags: [.maskControl, .maskCommand])
        try postKey(source: source, keyCode: qKey, keyDown: false, flags: [.maskControl, .maskCommand])
        try postKey(source: source, keyCode: commandKey, keyDown: false, flags: [.maskControl])
        try postKey(source: source, keyCode: controlKey, keyDown: false, flags: noFlags)

        logger.log("Lock command sent with Control-Command-Q")
    }

    private func makeLocalShortcutFocusWindow() -> NSWindow {
        let window = LocalShortcutFocusWindow(
            contentRect: NSRect(x: -10, y: -10, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }

    private func postKey(source: CGEventSource, keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags) throws {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            throw IdleLockError.lockCommandFailed("Unable to create Control-Command-Q key event.")
        }

        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(20_000)
    }
}

public enum LocalSessionLockAPI {
    private static let symbolName = "SACLockScreenImmediate"
    private typealias LockFunction = @convention(c) () -> Void

    public static func isAvailable(at path: String) -> Bool {
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            return false
        }
        defer { dlclose(handle) }
        return dlsym(handle, symbolName) != nil
    }

    static func lock(using path: String) throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw IdleLockError.lockCommandFailed("Unable to load the local macOS session service.")
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, symbolName) else {
            throw IdleLockError.lockCommandFailed("The local macOS session lock function is unavailable.")
        }

        let lock = unsafeBitCast(symbol, to: LockFunction.self)
        lock()
    }
}
