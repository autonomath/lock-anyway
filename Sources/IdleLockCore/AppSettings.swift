import Combine
import Foundation

public final class AppSettings: ObservableObject {
    private enum Key {
        static let lockDelaySeconds = "lockDelaySeconds"
        static let countdownSeconds = "countdownSeconds"
        static let pausedUntil = "pausedUntil"
        static let pausedIndefinitely = "pausedIndefinitely"
        static let startAtLogin = "startAtLogin"
        static let soundEnabled = "soundEnabled"
        static let customDelaySeconds = "customDelaySeconds"
    }

    private let defaults: UserDefaults

    @Published public private(set) var lockDelaySeconds: TimeInterval
    @Published public private(set) var countdownSeconds: TimeInterval
    @Published public private(set) var pausedUntil: Date?
    @Published public private(set) var pausedIndefinitely: Bool
    @Published public private(set) var startAtLogin: Bool
    @Published public private(set) var soundEnabled: Bool
    @Published public private(set) var customDelaySeconds: TimeInterval

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedDelay = defaults.object(forKey: Key.lockDelaySeconds) as? TimeInterval
        let delay = SettingsValidator.sanitizeDelay(storedDelay ?? IdleLockDefaults.defaultDelaySeconds)
        self.lockDelaySeconds = delay

        let storedCountdown = defaults.object(forKey: Key.countdownSeconds) as? TimeInterval
        self.countdownSeconds = SettingsValidator.sanitizeCountdown(
            storedCountdown ?? IdleLockDefaults.defaultCountdownSeconds,
            delaySeconds: delay
        )

        if let timestamp = defaults.object(forKey: Key.pausedUntil) as? TimeInterval, timestamp > 0 {
            self.pausedUntil = Date(timeIntervalSince1970: timestamp)
        } else {
            self.pausedUntil = nil
        }

        self.pausedIndefinitely = defaults.bool(forKey: Key.pausedIndefinitely)

        if defaults.object(forKey: Key.startAtLogin) == nil {
            self.startAtLogin = true
        } else {
            self.startAtLogin = defaults.bool(forKey: Key.startAtLogin)
        }

        if defaults.object(forKey: Key.soundEnabled) == nil {
            self.soundEnabled = false
        } else {
            self.soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        }

        let storedCustom = defaults.object(forKey: Key.customDelaySeconds) as? TimeInterval
        self.customDelaySeconds = SettingsValidator.sanitizeDelay(storedCustom ?? delay)
        persistAll()
    }

    public var isPaused: Bool {
        if pausedIndefinitely {
            return true
        }
        guard let pausedUntil else {
            return false
        }
        return pausedUntil > Date()
    }

    public var pauseDescription: String? {
        if pausedIndefinitely {
            return "Paused until resumed"
        }
        if let pausedUntil, pausedUntil > Date() {
            return DurationFormatter.pauseLabel(until: pausedUntil)
        }
        return nil
    }

    public func setLockDelaySeconds(_ seconds: TimeInterval) {
        let sanitized = SettingsValidator.sanitizeDelay(seconds)
        lockDelaySeconds = sanitized
        countdownSeconds = SettingsValidator.sanitizeCountdown(countdownSeconds, delaySeconds: sanitized)
        if !IdleLockDefaults.delayPresetSeconds.contains(sanitized) {
            customDelaySeconds = sanitized
        }
        persistAll()
    }

    public func setCountdownSeconds(_ seconds: TimeInterval) {
        countdownSeconds = SettingsValidator.sanitizeCountdown(seconds, delaySeconds: lockDelaySeconds)
        persistAll()
    }

    public func setCustomDelaySeconds(_ seconds: TimeInterval) {
        customDelaySeconds = SettingsValidator.sanitizeDelay(seconds)
        setLockDelaySeconds(customDelaySeconds)
    }

    public func setStartAtLogin(_ enabled: Bool) {
        startAtLogin = enabled
        persistAll()
    }

    public func setSoundEnabled(_ enabled: Bool) {
        soundEnabled = enabled
        persistAll()
    }

    public func pause(for seconds: TimeInterval) {
        pausedIndefinitely = false
        pausedUntil = Date().addingTimeInterval(max(1, seconds))
        persistAll()
    }

    public func pauseUntilResumed() {
        pausedIndefinitely = true
        pausedUntil = nil
        persistAll()
    }

    public func resume() {
        pausedIndefinitely = false
        pausedUntil = nil
        persistAll()
    }

    public func clearExpiredPause(now: Date = Date()) {
        if let pausedUntil, pausedUntil <= now {
            self.pausedUntil = nil
            persistAll()
        }
    }

    private func persistAll() {
        defaults.set(lockDelaySeconds, forKey: Key.lockDelaySeconds)
        defaults.set(countdownSeconds, forKey: Key.countdownSeconds)
        defaults.set(pausedIndefinitely, forKey: Key.pausedIndefinitely)
        defaults.set(startAtLogin, forKey: Key.startAtLogin)
        defaults.set(soundEnabled, forKey: Key.soundEnabled)
        defaults.set(customDelaySeconds, forKey: Key.customDelaySeconds)
        if let pausedUntil {
            defaults.set(pausedUntil.timeIntervalSince1970, forKey: Key.pausedUntil)
        } else {
            defaults.removeObject(forKey: Key.pausedUntil)
        }
    }
}
