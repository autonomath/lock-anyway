import CoreGraphics
import Foundation

public enum IdleMonitorDecision: Equatable {
    case paused(String)
    case active(nextPoll: TimeInterval)
    case countdown(remaining: TimeInterval)
    case lockNow
}

public enum IdleStateMachine {
    public static func decision(
        idleSeconds: TimeInterval,
        delaySeconds: TimeInterval,
        countdownSeconds: TimeInterval,
        pausedIndefinitely: Bool,
        pausedUntil: Date?,
        now: Date = Date()
    ) -> IdleMonitorDecision {
        if pausedIndefinitely {
            return .paused("Paused until resumed")
        }

        if let pausedUntil, pausedUntil > now {
            return .paused(DurationFormatter.pauseLabel(until: pausedUntil))
        }

        if idleSeconds >= delaySeconds {
            return .lockNow
        }

        let countdownThreshold = max(0, delaySeconds - countdownSeconds)
        if idleSeconds >= countdownThreshold {
            return .countdown(remaining: max(0, delaySeconds - idleSeconds))
        }

        let secondsToThreshold = countdownThreshold - idleSeconds
        let nextPoll = min(5, max(0.5, secondsToThreshold))
        return .active(nextPoll: nextPoll)
    }

    public static func shouldCancelCountdown(currentIdle: TimeInterval, countdownStartIdle: TimeInterval) -> Bool {
        currentIdle + 0.75 < countdownStartIdle
    }
}

public enum ScreenEdgeDetector {
    public static func isAtEdge(
        point: CGPoint,
        screenFrames: [CGRect],
        margin: CGFloat = 24
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite, margin > 0 else {
            return false
        }

        for frame in screenFrames where frame.contains(point) {
            let insetX = min(margin, frame.width / 2)
            let insetY = min(margin, frame.height / 2)
            let innerFrame = frame.insetBy(dx: insetX, dy: insetY)
            return !innerFrame.contains(point)
        }

        return false
    }
}

public enum CountdownClock {
    public static func displaySeconds(remaining: TimeInterval) -> Int {
        guard remaining > 0 else {
            return 0
        }
        return max(1, Int(ceil(remaining)))
    }

    public static func displaySeconds(until deadline: Date, now: Date = Date()) -> Int {
        displaySeconds(remaining: deadline.timeIntervalSince(now))
    }

    public static func nextPollInterval(until deadline: Date, now: Date = Date()) -> TimeInterval {
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else {
            return 0.1
        }

        let displayed = ceil(remaining)
        let secondsUntilNextNumber = remaining - (displayed - 1)
        return min(0.5, max(0.05, secondsUntilNextNumber + 0.02))
    }
}
