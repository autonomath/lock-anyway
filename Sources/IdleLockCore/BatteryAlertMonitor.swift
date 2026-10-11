import AppKit
import Foundation
import IOKit.ps

public struct BatterySnapshot: Equatable {
    public var hasBattery: Bool
    public var isOnBattery: Bool
    public var percent: Int
    public var minutesToEmpty: Int?

    public init(hasBattery: Bool, isOnBattery: Bool, percent: Int, minutesToEmpty: Int?) {
        self.hasBattery = hasBattery
        self.isOnBattery = isOnBattery
        self.percent = percent
        self.minutesToEmpty = minutesToEmpty
    }

    public static let noBattery = BatterySnapshot(hasBattery: false, isOnBattery: false, percent: 100, minutesToEmpty: nil)

    var logDescription: String {
        guard hasBattery else {
            return "no battery detected"
        }
        var text = "\(percent)% on \(isOnBattery ? "battery" : "external power")"
        if let minutesToEmpty {
            text += ", about \(BatteryMath.durationLabel(minutes: minutesToEmpty)) left"
        }
        return text
    }
}

public protocol PowerSourceReading: AnyObject {
    func currentSnapshot() -> BatterySnapshot
    func startObserving(_ onChange: @escaping () -> Void)
    func stopObserving()
}

public final class IOKitPowerSourceReader: PowerSourceReading {
    private var runLoopSource: CFRunLoopSource?
    private var onChange: (() -> Void)?

    public init() {}

    deinit {
        stopObserving()
    }

    public func currentSnapshot() -> BatterySnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return .noBattery
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else {
                continue
            }
            if let isPresent = description[kIOPSIsPresentKey] as? Bool, !isPresent {
                continue
            }

            let isOnBattery = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            let percent = BatteryMath.percent(
                current: description[kIOPSCurrentCapacityKey] as? Int ?? 0,
                maximum: description[kIOPSMaxCapacityKey] as? Int ?? 100
            )
            let minutes = BatteryMath.minutesToEmpty(
                raw: description[kIOPSTimeToEmptyKey] as? Int,
                isOnBattery: isOnBattery
            )
            return BatterySnapshot(hasBattery: true, isOnBattery: isOnBattery, percent: percent, minutesToEmpty: minutes)
        }

        return .noBattery
    }

    public func startObserving(_ onChange: @escaping () -> Void) {
        stopObserving()
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else {
                return
            }
            Unmanaged<IOKitPowerSourceReader>.fromOpaque(context).takeUnretainedValue().onChange?()
        }, context)?.takeRetainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    public func stopObserving() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        onChange = nil
    }
}

public enum BatteryMath {
    public static func percent(current: Int, maximum: Int) -> Int {
        guard maximum > 0 else {
            return min(max(current, 0), 100)
        }
        let value = (Double(current) * 100 / Double(maximum)).rounded()
        return min(max(Int(value), 0), 100)
    }

    public static func minutesToEmpty(raw: Int?, isOnBattery: Bool) -> Int? {
        guard isOnBattery, let raw, raw > 0, raw < 65_535 else {
            return nil
        }
        return raw
    }

    public static func durationLabel(minutes: Int) -> String {
        if minutes < 60 {
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    public static func timeRemainingText(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else {
            return nil
        }
        return "About \(durationLabel(minutes: minutes)) left"
    }
}

public enum BatteryAlertLevel: Int, CaseIterable, Identifiable {
    case low = 10
    case veryLow = 5
    case critical = 2

    public var id: Int {
        rawValue
    }

    public var threshold: Int {
        rawValue
    }

    public var coversScreen: Bool {
        self != .low
    }

    public var playsSound: Bool {
        self != .low
    }

    public var title: String {
        switch self {
        case .low:
            return "Battery low"
        case .veryLow:
            return "Battery very low"
        case .critical:
            return "Plug in now"
        }
    }

    public func detail(minutesToEmpty: Int?) -> String {
        let advice = self == .critical ? "Your Mac will go to sleep very soon." : "Connect a charger soon."
        guard let time = BatteryMath.timeRemainingText(minutes: minutesToEmpty) else {
            return advice
        }
        return "\(time). \(advice)"
    }
}

public struct BatteryAlertDecision: Equatable {
    public var firedThresholds: Set<Int>
    public var alertToShow: BatteryAlertLevel?
    public var shouldHide: Bool
}

public enum BatteryAlertPolicy {
    /// Each level fires once per discharge. A fired level re-arms only after the
    /// battery charges above it on external power, so small readings bouncing
    /// on battery never repeat an alert.
    public static func evaluate(
        snapshot: BatterySnapshot,
        enabled: Bool,
        firedThresholds: Set<Int>
    ) -> BatteryAlertDecision {
        guard enabled, snapshot.hasBattery else {
            return BatteryAlertDecision(firedThresholds: [], alertToShow: nil, shouldHide: true)
        }

        guard snapshot.isOnBattery else {
            let rearmed = firedThresholds.filter { snapshot.percent <= $0 }
            return BatteryAlertDecision(firedThresholds: rearmed, alertToShow: nil, shouldHide: true)
        }

        let crossed = BatteryAlertLevel.allCases.filter {
            snapshot.percent <= $0.threshold && !firedThresholds.contains($0.threshold)
        }
        guard let mostSevere = crossed.min(by: { $0.threshold < $1.threshold }) else {
            return BatteryAlertDecision(firedThresholds: firedThresholds, alertToShow: nil, shouldHide: false)
        }
        return BatteryAlertDecision(
            firedThresholds: firedThresholds.union(crossed.map(\.threshold)),
            alertToShow: mostSevere,
            shouldHide: false
        )
    }
}

public struct BatteryAlertContent: Equatable {
    public var level: BatteryAlertLevel
    public var percent: Int
    public var minutesToEmpty: Int?
    public var isPreview: Bool

    public init(level: BatteryAlertLevel, percent: Int, minutesToEmpty: Int?, isPreview: Bool) {
        self.level = level
        self.percent = percent
        self.minutesToEmpty = minutesToEmpty
        self.isPreview = isPreview
    }

    public var title: String {
        level.title
    }

    public var detail: String {
        level.detail(minutesToEmpty: minutesToEmpty)
    }

    public static func preview(_ level: BatteryAlertLevel) -> BatteryAlertContent {
        let sampleMinutes: Int
        switch level {
        case .low:
            sampleMinutes = 25
        case .veryLow:
            sampleMinutes = 12
        case .critical:
            sampleMinutes = 4
        }
        return BatteryAlertContent(level: level, percent: level.threshold, minutesToEmpty: sampleMinutes, isPreview: true)
    }
}

public final class BatteryAlertMonitor {
    private let settings: AppSettings
    private let reader: PowerSourceReading
    private let overlay: BatteryAlertOverlayController
    private let logger: IdleLockLogger
    private var firedThresholds: Set<Int> = []
    private var lastSnapshot: BatterySnapshot?
    private var activeLevel: BatteryAlertLevel?
    private var previewContent: BatteryAlertContent?
    private var isSuppressed = false
    private var fallbackTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    public init(
        settings: AppSettings,
        reader: PowerSourceReading,
        overlay: BatteryAlertOverlayController,
        logger: IdleLockLogger
    ) {
        self.settings = settings
        self.reader = reader
        self.overlay = overlay
        self.logger = logger
        self.overlay.onDismiss = { [weak self] in
            self?.dismiss()
        }
    }

    deinit {
        stop()
    }

    public var hasBattery: Bool {
        reader.currentSnapshot().hasBattery
    }

    public static func lockStateSuppressesAlerts(_ state: IdleLockRunState) -> Bool {
        switch state {
        case .countdown, .locking, .locked:
            return true
        case .active, .paused, .disabled:
            return false
        }
    }

    public func start() {
        reader.startObserving { [weak self] in
            self?.refresh()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
        refresh()
    }

    public func stop() {
        reader.stopObserving()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        overlay.hide()
    }

    public func setAlertsEnabled(_ enabled: Bool) {
        settings.setBatteryAlertsEnabled(enabled)
        logger.log("Low battery alerts \(enabled ? "enabled" : "disabled")")
        refresh()
    }

    public func updateLockState(_ state: IdleLockRunState) {
        let suppressed = Self.lockStateSuppressesAlerts(state)
        guard suppressed != isSuppressed else {
            return
        }
        isSuppressed = suppressed

        if suppressed {
            previewContent = nil
            if overlay.isVisible {
                overlay.hide()
                if activeLevel != nil {
                    logger.log("Low battery alert hidden while this Mac is locking or locked")
                }
            }
        } else {
            refresh()
            if !overlay.isVisible {
                presentActiveAlert()
            }
        }
    }

    public func preview(_ level: BatteryAlertLevel) {
        let content = BatteryAlertContent.preview(level)
        previewContent = content
        logger.log("Low battery alert preview \(level.threshold)%")
        playSound(for: level)
        overlay.show(content)
    }

    public func refresh() {
        let snapshot = reader.currentSnapshot()
        logIfChanged(snapshot)
        lastSnapshot = snapshot

        let enabled = settings.batteryAlertsEnabled
        let decision = BatteryAlertPolicy.evaluate(
            snapshot: snapshot,
            enabled: enabled,
            firedThresholds: firedThresholds
        )
        firedThresholds = decision.firedThresholds

        if decision.shouldHide {
            let reason: String
            if !enabled {
                reason = "alerts turned off"
            } else if !snapshot.hasBattery {
                reason = "no battery detected"
            } else {
                reason = "external power connected"
            }
            closeActiveAlert(reason: reason)
            return
        }

        if let level = decision.alertToShow {
            logger.log("Low battery alert \(level.threshold)% fired at \(snapshot.percent)%")
            playSound(for: level)
            activeLevel = level
            if isSuppressed {
                logger.log("Low battery alert deferred until this Mac is active again")
            } else {
                previewContent = nil
                overlay.show(content(for: level, snapshot: snapshot))
            }
            return
        }

        if let activeLevel, previewContent == nil, !isSuppressed, overlay.isVisible {
            overlay.update(content(for: activeLevel, snapshot: snapshot))
        }
    }

    private func content(for level: BatteryAlertLevel, snapshot: BatterySnapshot) -> BatteryAlertContent {
        BatteryAlertContent(
            level: level,
            percent: snapshot.percent,
            minutesToEmpty: snapshot.minutesToEmpty,
            isPreview: false
        )
    }

    private func presentActiveAlert() {
        guard !isSuppressed,
              previewContent == nil,
              let activeLevel,
              let snapshot = lastSnapshot
        else {
            return
        }
        overlay.show(content(for: activeLevel, snapshot: snapshot))
    }

    private func closeActiveAlert(reason: String) {
        guard let level = activeLevel else {
            return
        }
        activeLevel = nil
        logger.log("Low battery alert \(level.threshold)% closed: \(reason)")
        if previewContent == nil {
            overlay.hide()
        }
    }

    private func dismiss() {
        if previewContent != nil {
            previewContent = nil
            overlay.hide()
            logger.log("Low battery alert preview dismissed")
            presentActiveAlert()
            return
        }

        if let activeLevel {
            logger.log("Low battery alert \(activeLevel.threshold)% dismissed")
        }
        activeLevel = nil
        overlay.hide()
    }

    private func logIfChanged(_ snapshot: BatterySnapshot) {
        if let lastSnapshot,
           lastSnapshot.hasBattery == snapshot.hasBattery,
           lastSnapshot.isOnBattery == snapshot.isOnBattery,
           lastSnapshot.percent == snapshot.percent {
            return
        }
        logger.log("Power source: \(snapshot.logDescription)")
    }

    private func playSound(for level: BatteryAlertLevel) {
        guard level.playsSound else {
            return
        }
        if NSSound(named: NSSound.Name("Sosumi"))?.play() != true {
            NSSound.beep()
        }
    }
}
