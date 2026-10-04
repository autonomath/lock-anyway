import AppKit
import Foundation

public enum IdleLockApplication {
    public static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Retainer.shared.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

private final class Retainer {
    static let shared = Retainer()
    var delegate: AppDelegate?
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings: AppSettings
    private let logger: IdleLockLogger
    private let overlay: CountdownOverlayController
    private let lockService: LockService
    private let launchAgent: LaunchAgentService
    private let monitor: IdleMonitor
    private var menuController: MenuController?
    private var preferencesWindow: PreferencesWindowController?
    private var logWindow: LogWindowController?

    override init() {
        self.settings = AppSettings()
        self.logger = IdleLockLogger()
        self.overlay = CountdownOverlayController()
        self.lockService = LockService(logger: logger)
        self.launchAgent = LaunchAgentService(logger: logger)
        self.monitor = IdleMonitor(
            settings: settings,
            idleReader: HIDIdleReader(),
            lockService: lockService,
            overlay: overlay,
            logger: logger
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log("Lock Anyway launched bundle=\(Bundle.main.bundleURL.path)")
        guard ensureSingleInstance() else {
            return
        }
        guard ensureNotRunningFromDiskImage() else {
            return
        }

        logWindow = LogWindowController(logger: logger)
        preferencesWindow = PreferencesWindowController(
            settings: settings,
            monitor: monitor,
            launchAgent: launchAgent,
            logger: logger,
            showLog: { [weak self] in self?.logWindow?.show() }
        )

        menuController = MenuController(
            settings: settings,
            monitor: monitor,
            lockService: lockService,
            showPreferences: { [weak self] in self?.preferencesWindow?.show() }
        )

        installAutomationObservers()

        monitor.onStateChanged = { [weak self] state in
            self?.menuController?.update(state: state)
        }

        if settings.startAtLogin {
            launchAgent.installForCurrentAppIfPossible()
        }

        monitor.start()
        showFirstRunAccessibilityPromptIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.log("Lock Anyway terminating")
        monitor.stop()
    }

    private func installAutomationObservers() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(showPreferencesForAutomation),
            name: Notification.Name("com.user.IdleLock.showPreferences"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(testCountdownForAutomation),
            name: Notification.Name("com.user.IdleLock.testCountdown"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func showPreferencesForAutomation() {
        preferencesWindow?.show()
    }

    @objc private func testCountdownForAutomation() {
        monitor.testCountdown()
    }

    private func showFirstRunAccessibilityPromptIfNeeded() {
        let key = "didShowAccessibilitySetupPrompt"
        guard !UserDefaults.standard.bool(forKey: key) else {
            return
        }

        let availability = lockService.availability(promptForAccessibility: false)
        guard availability.strategy == nil, availability.requiresAccessibilityPermission else {
            return
        }

        UserDefaults.standard.set(true, forKey: key)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else {
                return
            }
            let alert = NSAlert()
            alert.messageText = "Finish Setting Up Lock Anyway"
            alert.informativeText = "Lock Anyway may need Accessibility permission to press the macOS Lock Screen shortcut. It never reads or records what you type."
            alert.addButton(withTitle: "Open Permission Prompt")
            alert.addButton(withTitle: "Later")
            alert.alertStyle = .informational
            if alert.runModal() == .alertFirstButtonReturn {
                self.lockService.openAccessibilityPermissionHelp()
                self.monitor.refreshSoon()
            }
        }
    }

    private func ensureNotRunningFromDiskImage() -> Bool {
        let bundlePath = Bundle.main.bundleURL.path
        guard bundlePath.hasPrefix("/Volumes/") else {
            return true
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Lock Anyway to Applications"
        alert.informativeText = "Drag Lock Anyway.app to Applications, then open it from there. Running it from the disk image can break Start at Login and Accessibility permission."
        alert.addButton(withTitle: "Open Applications")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .informational
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
        NSApp.terminate(nil)
        return false
    }

    private func ensureSingleInstance() -> Bool {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.user.IdleLock"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentPID && !$0.isTerminated }

        guard let existing else {
            return true
        }

        logger.log("Another Lock Anyway instance is already running pid=\(existing.processIdentifier); exiting duplicate")
        NSApp.terminate(nil)
        return false
    }
}
