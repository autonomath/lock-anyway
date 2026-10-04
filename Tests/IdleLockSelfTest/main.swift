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
        isExecutableFile: { _ in false },
        isAccessibilityTrusted: { true }
    )
    tests.expect(shortcutResolver.resolve() == .available(.keyboardShortcut), "keyboard shortcut used when trusted")

    let unavailable = LockStrategyResolver(
        cgSessionCandidates: ["/missing"],
        isExecutableFile: { _ in false },
        isAccessibilityTrusted: { false }
    ).resolve()
    tests.expect(unavailable.strategy == nil, "unavailable without CGSession or Accessibility")
    tests.expect(unavailable.requiresAccessibilityPermission, "unavailable state requests Accessibility")
    tests.expect(unavailable.reason != nil, "unavailable state explains why")
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

if tests.failures > 0 {
    print("\(tests.failures) of \(tests.checks) checks failed")
    exit(1)
}

print("All \(tests.checks) IdleLock self-test checks passed")
