import Darwin
import CoreGraphics
import Foundation
import IdleLockCore

struct TestRunner {
    private(set) var failures = 0
    private(set) var checks = 0

    mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }
}

func makeDefaults() -> UserDefaults {
    let suite = "IdleLockTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

var tests = TestRunner()

do {
    let settings = AppSettings(defaults: makeDefaults())
    tests.expect(settings.lockDelaySeconds == 300, "default lock delay is 5 minutes")
    tests.expect(settings.countdownSeconds == 30, "default countdown is 30 seconds")
    tests.expect(settings.startAtLogin, "start at login defaults on")
    tests.expect(!settings.soundEnabled, "sound defaults off")
    tests.expect(settings.batteryAlertsEnabled, "battery alerts default on")
}

do {
    let defaults = makeDefaults()
    AppSettings(defaults: defaults).setBatteryAlertsEnabled(false)
    tests.expect(!AppSettings(defaults: defaults).batteryAlertsEnabled, "battery alerts off persists")
}

do {
    let defaults = makeDefaults()
    var settings = AppSettings(defaults: defaults)
    settings.setCountdownSeconds(60)
    settings.setCustomDelaySeconds(30)
    tests.expect(settings.lockDelaySeconds == 30, "custom delay is applied")
    tests.expect(settings.countdownSeconds == 29, "countdown clamps below short custom delay")

    settings = AppSettings(defaults: defaults)
    tests.expect(settings.lockDelaySeconds == 30, "custom delay persists")
    tests.expect(settings.countdownSeconds == 29, "clamped countdown persists")
}

do {
    let settings = AppSettings(defaults: makeDefaults())
    settings.pause(for: 1)
    tests.expect(settings.isPaused, "pause begins immediately")
    settings.clearExpiredPause(now: Date().addingTimeInterval(2))
    tests.expect(!settings.isPaused, "expired pause clears")
}

do {
    tests.expect(DurationParser.parseSeconds("30s") == 30, "parses seconds suffix")
    tests.expect(DurationParser.parseSeconds("5 min") == 300, "parses minutes suffix")
    tests.expect(DurationParser.parseSeconds("2h") == 7_200, "parses hours suffix")
    tests.expect(DurationParser.parseSeconds("45") == 45, "bare custom values are seconds")
    tests.expect(DurationParser.parseSeconds("") == nil, "rejects empty duration")
    tests.expect(DurationParser.parseSeconds("soon") == nil, "rejects invalid duration")
}

do {
    tests.expect(DurationFormatter.pauseDurationLabel(1) == "1 min", "pause display rounds seconds to minutes")
    tests.expect(DurationFormatter.pauseDurationLabel(119) == "2 min", "pause display rounds up minutes")
    tests.expect(DurationFormatter.pauseDurationLabel(3_599) == "1 hour", "pause display rounds near-hour to hours")
    tests.expect(DurationFormatter.pauseDurationLabel(7_200) == "2 hours", "pause display shows whole hours")
}

do {
    let active = IdleStateMachine.decision(
        idleSeconds: 10,
        delaySeconds: 300,
        countdownSeconds: 30,
        pausedIndefinitely: false,
        pausedUntil: nil
    )
    tests.expect(active == .active(nextPoll: 5), "active decision below threshold")

    let countdown = IdleStateMachine.decision(
        idleSeconds: 270,
        delaySeconds: 300,
        countdownSeconds: 30,
        pausedIndefinitely: false,
        pausedUntil: nil
    )
    tests.expect(countdown == .countdown(remaining: 30), "countdown starts at delay minus warning")

    let lock = IdleStateMachine.decision(
        idleSeconds: 300,
        delaySeconds: 300,
        countdownSeconds: 30,
        pausedIndefinitely: false,
        pausedUntil: nil
    )
    tests.expect(lock == .lockNow, "lock decision at delay")

    let paused = IdleStateMachine.decision(
        idleSeconds: 600,
        delaySeconds: 300,
        countdownSeconds: 30,
        pausedIndefinitely: true,
        pausedUntil: nil
    )
    tests.expect(paused == .paused("Paused until resumed"), "pause wins over idle threshold")

    tests.expect(
        IdleStateMachine.shouldCancelCountdown(currentIdle: 1, countdownStartIdle: 270),
        "countdown cancels when HID idle drops"
    )
    tests.expect(
        !IdleStateMachine.shouldCancelCountdown(currentIdle: 270.5, countdownStartIdle: 270),
        "countdown continues without activity"
    )
}

do {
    let cgResolver = LockStrategyResolver(
        cgSessionCandidates: ["/missing", "/cg"],
        isExecutableFile: { $0 == "/cg" },
        isAccessibilityTrusted: { true }
    )
    tests.expect(cgResolver.resolve() == .available(.cgSession(path: "/cg")), "CGSession is preferred when present")

    let shortcutResolver = LockStrategyResolver(
        cgSessionCandidates: ["/missing"],
        localSessionAPICandidates: [],
        isExecutableFile: { _ in false },
        isAccessibilityTrusted: { true }
    )
    tests.expect(shortcutResolver.resolve() == .available(.keyboardShortcut), "keyboard shortcut used when trusted")

    let unavailable = LockStrategyResolver(
        cgSessionCandidates: ["/missing"],
        localSessionAPICandidates: [],
        isExecutableFile: { _ in false },
        isAccessibilityTrusted: { false }
    ).resolve()
    tests.expect(unavailable.strategy == nil, "unavailable without CGSession or Accessibility")
    tests.expect(unavailable.requiresAccessibilityPermission, "unavailable state requests Accessibility")
    tests.expect(unavailable.reason != nil, "unavailable state explains why")
}

do {
    let localSessionResolver = LockStrategyResolver(
        cgSessionCandidates: ["/missing"],
        localSessionAPICandidates: ["/missing", "/local-session"],
        isExecutableFile: { _ in false },
        hasLocalSessionAPI: { $0 == "/local-session" },
        isAccessibilityTrusted: { false }
    )
    tests.expect(
        localSessionResolver.resolve() == .available(.localSessionAPI(path: "/local-session")),
        "local session API is preferred over a keyboard shortcut"
    )

    let deadline = Date().addingTimeInterval(3)
    tests.expect(
        LockAttemptGuard.decision(sessionState: .unlocked, now: Date(), deadline: deadline) == .waiting,
        "lock verification waits before its deadline"
    )
    tests.expect(
        LockAttemptGuard.decision(sessionState: .locked, now: Date(), deadline: deadline) == .confirmed,
        "lock verification confirms the host session"
    )
    tests.expect(
        LockAttemptGuard.decision(sessionState: .unavailable, now: deadline, deadline: deadline) == .failed,
        "unconfirmed lock fails once at its deadline"
    )
    tests.expect(
        !LockAttemptGuard.detectedUserActivity(currentIdle: 599.5, referenceIdle: 600),
        "small HID timing drift does not rearm a failed lock"
    )
    tests.expect(
        LockAttemptGuard.detectedUserActivity(currentIdle: 1, referenceIdle: 600),
        "real HID activity rearms a failed lock"
    )
}

do {
    tests.expect(CountdownClock.displaySeconds(remaining: 30.0) == 30, "countdown displays exact seconds")
    tests.expect(CountdownClock.displaySeconds(remaining: 29.99) == 30, "countdown holds a number until the next whole second")
    tests.expect(CountdownClock.displaySeconds(remaining: 29.0) == 29, "countdown changes on whole-second boundary")
    tests.expect(CountdownClock.displaySeconds(remaining: 0) == 0, "countdown reaches zero")
    tests.expect(CountdownClock.nextPollInterval(until: Date().addingTimeInterval(10)) <= 0.5, "countdown polls HID at least twice per second")
}

do {
    let frame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    tests.expect(
        ScreenEdgeDetector.isAtEdge(point: CGPoint(x: 8, y: 450), screenFrames: [frame]),
        "screen edge detector catches left edge"
    )
    tests.expect(
        ScreenEdgeDetector.isAtEdge(point: CGPoint(x: 720, y: 892), screenFrames: [frame]),
        "screen edge detector catches top edge"
    )
    tests.expect(
        !ScreenEdgeDetector.isAtEdge(point: CGPoint(x: 720, y: 450), screenFrames: [frame]),
        "screen edge detector ignores center"
    )
    tests.expect(
        !ScreenEdgeDetector.isAtEdge(point: CGPoint(x: 2_000, y: 450), screenFrames: [frame]),
        "screen edge detector ignores points outside all screens"
    )
}

do {
    do {
        let idle = try HIDIdleReader().idleSeconds()
        tests.expect(idle >= 0, "HID idle reader returns nonnegative seconds")
    } catch {
        tests.expect(false, "HID idle reader failed: \(error.localizedDescription)")
    }
}

do {
    func battery(_ percent: Int, onBattery: Bool = true) -> BatterySnapshot {
        BatterySnapshot(hasBattery: true, isOnBattery: onBattery, percent: percent, minutesToEmpty: nil)
    }

    var fired: Set<Int> = []
    func step(_ snapshot: BatterySnapshot, enabled: Bool = true) -> BatteryAlertDecision {
        let decision = BatteryAlertPolicy.evaluate(snapshot: snapshot, enabled: enabled, firedThresholds: fired)
        fired = decision.firedThresholds
        return decision
    }

    tests.expect(step(battery(11)).alertToShow == nil, "battery alert stays quiet at 11%")
    tests.expect(step(battery(10)).alertToShow == .low, "battery alert shows corner card at 10%")
    tests.expect(step(battery(9)).alertToShow == nil, "battery alert does not repeat at 9%")
    tests.expect(step(battery(5)).alertToShow == .veryLow, "battery alert shows full screen at 5%")
    tests.expect(step(battery(4)).alertToShow == nil, "battery alert does not repeat at 4%")
    tests.expect(step(battery(2)).alertToShow == .critical, "battery alert shows critical at 2%")
    tests.expect(step(battery(1)).alertToShow == nil, "battery alert does not repeat at 1%")
    tests.expect(BatteryAlertLevel.low.coversScreen == false && BatteryAlertLevel.veryLow.coversScreen, "only 5% and 2% cover the screen")
    tests.expect(!BatteryAlertLevel.low.playsSound && BatteryAlertLevel.critical.playsSound, "only 5% and 2% play a sound")

    fired = []
    tests.expect(step(battery(12)).alertToShow == nil, "battery alert stays quiet at 12%")
    tests.expect(step(battery(4)).alertToShow == .veryLow, "a drop from 12% to 4% shows only the 5% alert")
    tests.expect(fired == [10, 5], "a drop from 12% to 4% marks 10% and 5% as fired")
    tests.expect(step(battery(2)).alertToShow == .critical, "2% still fires after a skipped level")

    fired = []
    _ = step(battery(10))
    let charging = step(battery(9, onBattery: false))
    tests.expect(charging.shouldHide && charging.alertToShow == nil, "external power hides the battery alert")
    tests.expect(fired.contains(10), "10% stays fired while charging below 11%")
    _ = step(battery(10, onBattery: false))
    tests.expect(fired.contains(10), "10% stays fired while charging at 10%")
    tests.expect(step(battery(9)).alertToShow == nil, "unplugging at 9% skips the 10% alert")
    _ = step(battery(11, onBattery: false))
    tests.expect(!fired.contains(10), "charging above 10% re-arms the 10% alert")
    tests.expect(step(battery(11)).alertToShow == nil, "unplugging at 11% stays quiet")
    tests.expect(step(battery(10)).alertToShow == .low, "the re-armed 10% alert fires again")

    fired = [10]
    _ = step(battery(11))
    tests.expect(fired.contains(10), "a reading bouncing up on battery does not re-arm 10%")

    fired = []
    tests.expect(step(battery(7)).alertToShow == .low, "starting at 7% shows the 10% alert")
    tests.expect(step(battery(7)).alertToShow == nil, "starting at 7% shows the 10% alert once")

    fired = []
    let disabled = step(battery(5), enabled: false)
    tests.expect(disabled.alertToShow == nil && disabled.shouldHide, "disabled battery alerts never fire")
    let noBattery = step(.noBattery)
    tests.expect(noBattery.alertToShow == nil && noBattery.shouldHide, "a Mac without a battery never fires")

    tests.expect(BatteryMath.percent(current: 57, maximum: 100) == 57, "battery percent of 57/100 is 57")
    tests.expect(BatteryMath.percent(current: 2_815, maximum: 5_630) == 50, "battery percent of 2815/5630 is 50")
    tests.expect(BatteryMath.timeRemainingText(minutes: 24) == "About 24 minutes left", "battery time under an hour")
    tests.expect(BatteryMath.timeRemainingText(minutes: 65) == "About 1 hr 5 min left", "battery time over an hour")
    tests.expect(BatteryMath.timeRemainingText(minutes: nil) == nil, "unknown battery time shows no text")
    tests.expect(BatteryMath.minutesToEmpty(raw: -1, isOnBattery: true) == nil, "calculating battery time is unknown")
    tests.expect(BatteryMath.minutesToEmpty(raw: 30, isOnBattery: false) == nil, "battery time is hidden on external power")
    tests.expect(
        BatteryAlertLevel.low.detail(minutesToEmpty: 24) == "About 24 minutes left. Connect a charger soon.",
        "battery alert detail includes time left"
    )
    tests.expect(
        BatteryAlertLevel.critical.detail(minutesToEmpty: nil) == "Your Mac will go to sleep very soon.",
        "critical battery alert warns about sleep"
    )

    tests.expect(BatteryAlertMonitor.lockStateSuppressesAlerts(.locked), "battery alerts wait while locked")
    tests.expect(BatteryAlertMonitor.lockStateSuppressesAlerts(.countdown(10)), "battery alerts wait during the lock countdown")
    tests.expect(!BatteryAlertMonitor.lockStateSuppressesAlerts(.active), "battery alerts show while active")

    let realBattery = IOKitPowerSourceReader().currentSnapshot()
    tests.expect(!realBattery.hasBattery || (0...100).contains(realBattery.percent), "real battery percent is between 0 and 100")
}

if tests.failures > 0 {
    print("\(tests.failures) of \(tests.checks) checks failed")
    exit(1)
}

print("All \(tests.checks) IdleLock self-test checks passed")
