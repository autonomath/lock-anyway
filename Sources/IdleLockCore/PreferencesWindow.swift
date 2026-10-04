import AppKit
import SwiftUI

public final class PreferencesWindowController {
    private let settings: AppSettings
    private let monitor: IdleMonitor
    private let launchAgent: LaunchAgentService
    private let logger: IdleLockLogger
    private let showLog: () -> Void
    private var window: NSWindow?

    public init(
        settings: AppSettings,
        monitor: IdleMonitor,
        launchAgent: LaunchAgentService,
        logger: IdleLockLogger,
        showLog: @escaping () -> Void
    ) {
        self.settings = settings
        self.monitor = monitor
        self.launchAgent = launchAgent
        self.logger = logger
        self.showLog = showLog
    }

    public func show() {
        if window == nil {
            let view = PreferencesView(
                settings: settings,
                monitor: monitor,
                launchAgent: launchAgent,
                logger: logger,
                showLog: showLog
            )
            let hosting = NSHostingController(rootView: view)
            let created = NSWindow(contentViewController: hosting)
            created.title = "Lock Anyway Preferences"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.setContentSize(NSSize(width: 560, height: 500))
            created.center()
            window = created
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PreferencesView: View {
    @ObservedObject var settings: AppSettings
    let monitor: IdleMonitor
    let launchAgent: LaunchAgentService
    let logger: IdleLockLogger
    let showLog: () -> Void

    @State private var customDelayText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Schedule") {
                    VStack(alignment: .leading, spacing: 12) {
                        preferenceRow("Lock after") {
                            Picker("Lock after", selection: delayBinding) {
                                ForEach(IdleLockDefaults.delayPresetSeconds, id: \.self) { seconds in
                                    Text(DurationFormatter.menuDelayLabel(seconds)).tag(seconds)
                                }
                                Text("Custom").tag(settings.customDelaySeconds)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        preferenceRow("Custom delay") {
                            HStack(spacing: 8) {
                                TextField("Examples: 30s, 5m, 1h", text: $customDelayText)
                                    .textFieldStyle(.roundedBorder)
                                Button("Apply") {
                                    applyCustomDelay()
                                }
                            }
                        }

                        preferenceRow("Countdown") {
                            Picker("Countdown warning", selection: countdownBinding) {
                                ForEach(IdleLockDefaults.countdownPresetSeconds, id: \.self) { seconds in
                                    Text(DurationFormatter.menuDelayLabel(seconds)).tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }

                        Toggle("Sound at countdown start", isOn: soundBinding)
                            .padding(.leading, 126)

                        Button("Preview Popup") {
                            monitor.testCountdown()
                        }
                        .padding(.leading, 126)
                    }
                    .padding(8)
                }

                GroupBox("Pause") {
                    HStack(spacing: 8) {
                        Button("Pause 30 min") {
                            monitor.pause(for: 1_800)
                        }
                        Button("Pause 1 hour") {
                            monitor.pause(for: 3_600)
                        }
                        Button("Until resumed") {
                            monitor.pauseUntilResumed()
                        }
                        Button("Resume") {
                            monitor.resume()
                        }
                    }
                    .padding(8)
                }

                GroupBox("System") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Start at Login", isOn: startAtLoginBinding)
                    }
                    .padding(8)
                }

                GroupBox("Diagnostics") {
                    HStack(spacing: 10) {
                        Button("Show Log") {
                            showLog()
                        }

                        Text(logger.logURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(8)
                }
            }
            .padding(22)
        }
        .onAppear {
            customDelayText = DurationFormatter.compact(settings.customDelaySeconds)
        }
    }

    private func preferenceRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .frame(width: 114, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var delayBinding: Binding<TimeInterval> {
        Binding(
            get: {
                if IdleLockDefaults.delayPresetSeconds.contains(settings.lockDelaySeconds) {
                    return settings.lockDelaySeconds
                }
                return settings.customDelaySeconds
            },
            set: { value in
                settings.setLockDelaySeconds(value)
                monitor.refreshSoon()
            }
        )
    }

    private var countdownBinding: Binding<TimeInterval> {
        Binding(
            get: { settings.countdownSeconds },
            set: { value in
                settings.setCountdownSeconds(value)
                monitor.refreshSoon()
            }
        )
    }

    private var soundBinding: Binding<Bool> {
        Binding(
            get: { settings.soundEnabled },
            set: { settings.setSoundEnabled($0) }
        )
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.startAtLogin },
            set: { enabled in
                do {
                    if enabled {
                        try launchAgent.installLaunchAgent(loadNow: false)
                    } else {
                        try launchAgent.disableLaunchAgent()
                    }
                    settings.setStartAtLogin(enabled)
                } catch {
                    settings.setStartAtLogin(false)
                    logger.log("Start at Login change failed: \(error.localizedDescription)")
                    showError(error.localizedDescription)
                }
            }
        )
    }

    private func applyCustomDelay() {
        guard let seconds = DurationParser.parseSeconds(customDelayText) else {
            showError("Could not parse custom delay.")
            return
        }
        settings.setCustomDelaySeconds(seconds)
        customDelayText = DurationFormatter.compact(settings.customDelaySeconds)
        monitor.refreshSoon()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Lock Anyway"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
