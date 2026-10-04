import AppKit
import Foundation

public final class MenuController: NSObject {
    private let statusItem: NSStatusItem
    private let settings: AppSettings
    private let monitor: IdleMonitor
    private let lockService: LockService
    private let showPreferences: () -> Void
    private var state: IdleLockRunState = .active

    public init(
        settings: AppSettings,
        monitor: IdleMonitor,
        lockService: LockService,
        showPreferences: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.settings = settings
        self.monitor = monitor
        self.lockService = lockService
        self.showPreferences = showPreferences
        super.init()
        statusItem.length = NSStatusItem.squareLength
        update(state: .active)
    }

    public func update(state: IdleLockRunState) {
        self.state = state
        updateStatusButton()
        rebuildMenu()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else {
            return
        }
        button.imagePosition = .imageOnly
        button.image = statusIcon(for: state)
        button.image?.isTemplate = true
        button.title = ""
        button.toolTip = "Lock Anyway: \(state.displayName)"
    }

    private func statusIcon(for state: IdleLockRunState) -> NSImage? {
        let name: String
        switch state {
        case .active:
            name = "lock.circle"
        case .paused:
            name = "pause.circle"
        case .countdown:
            name = "timer"
        case .disabled:
            name = "lock.trianglebadge.exclamationmark"
        }

        return NSImage(systemSymbolName: name, accessibilityDescription: state.displayName)
            ?? fallbackStatusIcon(for: state)
    }

    private func fallbackStatusIcon(for state: IdleLockRunState) -> NSImage? {
        let name: String
        switch state {
        case .active:
            name = "lock"
        case .paused:
            name = "pause.circle"
        case .countdown:
            name = "timer"
        case .disabled:
            name = "exclamationmark.triangle"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: state.displayName)
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let stateItem = NSMenuItem(title: stateDescription, action: stateItemAction, keyEquivalent: "")
        stateItem.image = stateIcon
        stateItem.image?.isTemplate = true
        stateItem.isEnabled = true
        stateItem.toolTip = stateToolTip
        menu.addItem(stateItem)
        menu.addItem(.separator())

        menu.addItem(lockDelayMenu())

        if settings.isPaused {
            menu.addItem(NSMenuItem(title: "Resume", action: #selector(resume), keyEquivalent: ""))
        }

        menu.addItem(pauseMenu())

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private var stateDescription: String {
        switch state {
        case .active:
            return "Active - locks after \(DurationFormatter.menuDelayLabel(settings.lockDelaySeconds))"
        case .paused(let reason):
            return reason
        case .countdown(let seconds):
            return "Locking in \(seconds)s"
        case .disabled(let reason):
            return reason.localizedCaseInsensitiveContains("accessibility")
                ? "Needs Accessibility Permission..."
                : "Disabled"
        }
    }

    private var stateToolTip: String {
        switch state {
        case .active:
            return "Lock Anyway is monitoring keyboard and mouse inactivity."
        case .paused(let reason):
            return reason
        case .countdown(let seconds):
            return "Lock Anyway will lock this Mac in \(seconds) seconds."
        case .disabled(let reason):
            return reason
        }
    }

    private var stateIcon: NSImage? {
        switch state {
        case .active:
            return NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Active")
        case .paused:
            return NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Paused")
        case .countdown:
            return NSImage(systemSymbolName: "timer", accessibilityDescription: "Countdown")
        case .disabled:
            return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Disabled")
        }
    }

    private var stateItemAction: Selector? {
        switch state {
        case .disabled(let reason) where reason.localizedCaseInsensitiveContains("accessibility"):
            return #selector(grantAccessibility)
        case .disabled:
            return #selector(showDisabledReason)
        default:
            return #selector(openPreferences)
        }
    }

    private func lockDelayMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Lock after", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for seconds in IdleLockDefaults.delayPresetSeconds {
            let preset = NSMenuItem(title: DurationFormatter.menuDelayLabel(seconds), action: #selector(setDelay(_:)), keyEquivalent: "")
            preset.representedObject = seconds
            preset.state = Int(settings.lockDelaySeconds) == Int(seconds) ? .on : .off
            preset.target = self
            submenu.addItem(preset)
        }

        let custom = NSMenuItem(title: "Custom...", action: #selector(customDelay), keyEquivalent: "")
        custom.target = self
        submenu.addItem(custom)

        if !IdleLockDefaults.delayPresetSeconds.contains(settings.lockDelaySeconds) {
            let current = NSMenuItem(title: "Current: \(DurationFormatter.menuDelayLabel(settings.lockDelaySeconds))", action: #selector(setDelay(_:)), keyEquivalent: "")
            current.representedObject = settings.lockDelaySeconds
            current.state = .on
            current.target = self
            submenu.addItem(.separator())
            submenu.addItem(current)
        }

        item.submenu = submenu
        return item
    }

    private func pauseMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Pause for", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let thirty = NSMenuItem(title: "30 min", action: #selector(pauseFor(_:)), keyEquivalent: "")
        thirty.representedObject = TimeInterval(1_800)
        let hour = NSMenuItem(title: "1 hour", action: #selector(pauseFor(_:)), keyEquivalent: "")
        hour.representedObject = TimeInterval(3_600)
        let until = NSMenuItem(title: "Until resumed", action: #selector(pauseUntilResumed), keyEquivalent: "")

        [thirty, hour, until].forEach {
            $0.target = self
            submenu.addItem($0)
        }

        item.submenu = submenu
        return item
    }

    @objc private func setDelay(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else {
            return
        }
        settings.setLockDelaySeconds(seconds)
        monitor.refreshSoon()
        update(state: state)
    }

    @objc private func customDelay() {
        let alert = NSAlert()
        alert.messageText = "Custom Lock Delay"
        alert.informativeText = "Enter seconds, minutes, or hours. Examples: 30s, 5m, 1h."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = DurationFormatter.compact(settings.customDelaySeconds)
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn,
              let parsed = DurationParser.parseSeconds(field.stringValue)
        else {
            return
        }

        settings.setCustomDelaySeconds(parsed)
        monitor.refreshSoon()
        update(state: state)
    }

    @objc private func pauseFor(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else {
            return
        }
        monitor.pause(for: seconds)
        update(state: monitor.state)
    }

    @objc private func pauseUntilResumed() {
        monitor.pauseUntilResumed()
        update(state: monitor.state)
    }

    @objc private func resume() {
        monitor.resume()
        update(state: monitor.state)
    }

    @objc private func grantAccessibility() {
        lockService.openAccessibilityPermissionHelp()
        monitor.refreshSoon()
    }

    @objc private func showDisabledReason() {
        if case .disabled(let reason) = state {
            showError(reason)
        }
    }

    @objc private func openPreferences() {
        showPreferences()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Lock Anyway"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
