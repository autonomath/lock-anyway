import Foundation

public enum IdleLockDefaults {
    public static let delayPresetSeconds: [TimeInterval] = [60, 180, 300, 600, 900, 1_800]
    public static let countdownPresetSeconds: [TimeInterval] = [10, 30, 60]
    public static let snoozePresetSeconds: [TimeInterval] = [900, 1_800, 3_600, 7_200]
    public static let defaultDelaySeconds: TimeInterval = 300
    public static let defaultCountdownSeconds: TimeInterval = 30
    public static let minimumDelaySeconds: TimeInterval = 5
    public static let maximumDelaySeconds: TimeInterval = 86_400
}

public enum IdleLockRunState: Equatable {
    case active
    case paused(String)
    case countdown(Int)
    case disabled(String)

    public var displayName: String {
        switch self {
        case .active:
            return "Active"
        case .paused:
            return "Paused"
        case .countdown(let seconds):
            return "Countdown \(seconds)s"
        case .disabled:
            return "Disabled"
        }
    }
}

public enum LockStrategy: Equatable, CustomStringConvertible {
    case cgSession(path: String)
    case keyboardShortcut

    public var description: String {
        switch self {
        case .cgSession(let path):
            return "CGSession at \(path)"
        case .keyboardShortcut:
            return "Control-Command-Q keyboard shortcut"
        }
    }
}

public struct LockAvailability: Equatable {
    public let strategy: LockStrategy?
    public let reason: String?
    public let requiresAccessibilityPermission: Bool

    public static func available(_ strategy: LockStrategy) -> LockAvailability {
        LockAvailability(strategy: strategy, reason: nil, requiresAccessibilityPermission: false)
    }

    public static func unavailable(_ reason: String, requiresAccessibilityPermission: Bool = false) -> LockAvailability {
        LockAvailability(strategy: nil, reason: reason, requiresAccessibilityPermission: requiresAccessibilityPermission)
    }
}

public enum IdleLockError: LocalizedError {
    case hidServiceUnavailable
    case hidIdlePropertyUnavailable
    case unsupportedHIDIdleValue
    case lockUnavailable(String)
    case lockCommandFailed(String)
    case launchAgentInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .hidServiceUnavailable:
            return "IOHIDSystem is not available."
        case .hidIdlePropertyUnavailable:
            return "IOHIDSystem did not return HIDIdleTime."
        case .unsupportedHIDIdleValue:
            return "HIDIdleTime had an unsupported value type."
        case .lockUnavailable(let message):
            return message
        case .lockCommandFailed(let message):
            return message
        case .launchAgentInstallFailed(let message):
            return message
        }
    }
}

public enum SettingsValidator {
    public static func sanitizeDelay(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else {
            return IdleLockDefaults.defaultDelaySeconds
        }
        return min(max(seconds.rounded(), IdleLockDefaults.minimumDelaySeconds), IdleLockDefaults.maximumDelaySeconds)
    }

    public static func sanitizeCountdown(_ seconds: TimeInterval, delaySeconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else {
            return IdleLockDefaults.defaultCountdownSeconds
        }
        let maximum = max(1, delaySeconds - 1)
        return min(max(seconds.rounded(), 1), maximum)
    }
}

public enum DurationFormatter {
    public static func compact(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded())
        if rounded < 60 {
            return "\(rounded)s"
        }
        if rounded % 3_600 == 0 {
            return "\(rounded / 3_600)h"
        }
        if rounded % 60 == 0 {
            return "\(rounded / 60)m"
        }
        return "\(rounded)s"
    }

    public static func menuDelayLabel(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded())
        if rounded < 60 {
            return "\(rounded) sec"
        }
        let minutes = rounded / 60
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }

    public static func pauseLabel(until date: Date) -> String {
        let remaining = max(0, date.timeIntervalSinceNow)
        return "Paused for \(pauseDurationLabel(remaining))"
    }

    public static func pauseDurationLabel(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }
}

public enum DurationParser {
    public static func parseSeconds(_ input: String) -> TimeInterval? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            return nil
        }

        let suffixes: [(String, TimeInterval)] = [
            ("seconds", 1), ("second", 1), ("secs", 1), ("sec", 1), ("s", 1),
            ("minutes", 60), ("minute", 60), ("mins", 60), ("min", 60), ("m", 60),
            ("hours", 3_600), ("hour", 3_600), ("hrs", 3_600), ("hr", 3_600), ("h", 3_600)
        ]

        for (suffix, multiplier) in suffixes where value.hasSuffix(suffix) {
            let number = value.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let parsed = Double(number) else {
                return nil
            }
            return parsed * multiplier
        }

        return Double(value)
    }
}
