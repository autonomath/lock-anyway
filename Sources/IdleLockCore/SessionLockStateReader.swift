import CoreGraphics
import Foundation

public enum SessionLockState: Equatable {
    case locked
    case unlocked
    case unavailable
}

public protocol SessionLockStateReading {
    func currentState() -> SessionLockState
}

public final class CGSessionLockStateReader: SessionLockStateReading {
    public init() {}

    public func currentState() -> SessionLockState {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return .unavailable
        }

        if let locked = session["CGSSessionScreenIsLocked"] as? Bool {
            return locked ? .locked : .unlocked
        }
        if let locked = session["CGSSessionScreenIsLocked"] as? NSNumber {
            return locked.boolValue ? .locked : .unlocked
        }

        return session["kCGSSessionOnConsoleKey"] == nil ? .unavailable : .unlocked
    }
}

public enum LockVerificationDecision: Equatable {
    case waiting
    case confirmed
    case failed
}

public enum LockAttemptGuard {
    public static let verificationTimeout: TimeInterval = 3

    public static func decision(
        sessionState: SessionLockState,
        now: Date,
        deadline: Date
    ) -> LockVerificationDecision {
        if sessionState == .locked {
            return .confirmed
        }
        return now < deadline ? .waiting : .failed
    }

    public static func detectedUserActivity(
        currentIdle: TimeInterval,
        referenceIdle: TimeInterval
    ) -> Bool {
        currentIdle + 1 < referenceIdle
    }
}
