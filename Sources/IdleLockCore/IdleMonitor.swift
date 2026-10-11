import AppKit
import Foundation

public final class IdleMonitor {
    private enum Mode {
        case normal
        case countdown(startIdle: TimeInterval, deadline: Date)
        case test(deadline: Date)
        case verifyingLock(referenceIdle: TimeInterval?, deadline: Date)
        case locked(referenceIdle: TimeInterval?)
        case lockFailed(referenceIdle: TimeInterval?)
    }

    private let settings: AppSettings
    private let idleReader: IdleTimeReading
    private let lockService: LockControlling
    private let overlay: CountdownOverlayController
    private let logger: IdleLockLogger
    private let sessionLockReader: SessionLockStateReading
    private var timer: Timer?
    private var mode: Mode = .normal
    private var lastHIDError: String?
    private var pendingPostponedHide: DispatchWorkItem?
    private var sessionObserverTokens: [NSObjectProtocol] = []

    public private(set) var state: IdleLockRunState = .active {
        didSet {
            if oldValue != state {
                onStateChanged?(state)
            }
        }
    }

    public var onStateChanged: ((IdleLockRunState) -> Void)?

    public init(
        settings: AppSettings,
        idleReader: IdleTimeReading,
        lockService: LockControlling,
        overlay: CountdownOverlayController,
        logger: IdleLockLogger,
        sessionLockReader: SessionLockStateReading = CGSessionLockStateReader()
    ) {
        self.settings = settings
        self.idleReader = idleReader
        self.lockService = lockService
        self.overlay = overlay
        self.logger = logger
        self.sessionLockReader = sessionLockReader
        self.overlay.onSnooze = { [weak self] seconds in
            self?.snooze(seconds: seconds)
        }
        self.overlay.onDisable = { [weak self] in
            self?.disableUntilResumed()
        }
        self.overlay.onDismiss = { [weak self] in
            self?.dismissPopup()
        }
        self.overlay.onEdgeDismiss = { [weak self] in
            self?.dismissPopupFromScreenEdge()
        }
    }

    deinit {
        stop()
    }

    public func start() {
        installSessionObserversIfNeeded()
        logger.log("Idle monitor started delay=\(Int(settings.lockDelaySeconds))s countdown=\(Int(settings.countdownSeconds))s")
        let availability = lockService.availability(promptForAccessibility: false)
        if let strategy = availability.strategy {
            logger.log("Selected lock strategy: \(strategy.description)")
        } else if let reason = availability.reason {
            logger.log("No lock strategy available: \(reason)")
        }
        schedule(after: 0.25)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        overlay.hide()
        removeSessionObservers()
    }

    public func refreshSoon() {
        schedule(after: 0.25)
    }

    public func lockNow() {
        beginLock(referenceIdle: nil)
    }

    private func beginLock(referenceIdle: TimeInterval?) {
        switch mode {
        case .verifyingLock, .locked:
            return
        default:
            break
        }

        pendingPostponedHide?.cancel()
        overlay.hide()
        let deadline = Date().addingTimeInterval(LockAttemptGuard.verificationTimeout)
        mode = .verifyingLock(referenceIdle: referenceIdle, deadline: deadline)
        state = .locking
        do {
            try lockService.lockNow()
            logger.log("Lock requested; waiting for this Mac to confirm its session is locked")
            schedule(after: 0.2)
        } catch {
            let message = error.localizedDescription
            logger.log("Lock failed: \(message)")
            mode = .lockFailed(referenceIdle: referenceIdle)
            state = .disabled(message)
            schedule(after: 1)
        }
    }

    public func testCountdown() {
        pendingPostponedHide?.cancel()
        let duration = max(1, settings.countdownSeconds)
        mode = .test(deadline: Date().addingTimeInterval(duration))
        logger.log("Test countdown started for \(Int(duration))s")
        overlay.showCountdown(remainingSeconds: Int(duration.rounded(.up)))
        state = .countdown(Int(duration.rounded(.up)))
        schedule(after: 1)
    }

    public func pause(for seconds: TimeInterval) {
        settings.pause(for: seconds)
        cancelCountdown(showPostponed: false)
        state = .paused(settings.pauseDescription ?? "Paused")
        logger.log("Paused for \(Int(seconds))s")
        schedule(after: 5)
    }

    public func pauseUntilResumed() {
        settings.pauseUntilResumed()
        cancelCountdown(showPostponed: false)
        state = .paused("Paused until resumed")
        logger.log("Paused until resumed")
        schedule(after: 5)
    }

    public func disableUntilResumed() {
        settings.pauseUntilResumed()
        mode = .normal
        overlay.showPostponed(
            message: "Locking disabled",
            detail: "Resume from the menu when you want Lock Anyway active again."
        )
        state = .paused("Paused until resumed")
        logger.log("Disabled until resumed from countdown popup")
        schedulePostponedHide()
        schedule(after: 5)
    }

    public func dismissPopup() {
        pendingPostponedHide?.cancel()
        mode = .normal
        overlay.hide()
        if settings.isPaused {
            state = .paused(settings.pauseDescription ?? "Paused")
        } else {
            state = .active
        }
        logger.log("Popup dismissed")
        schedule(after: 5)
    }

    public func dismissPopupFromScreenEdge() {
        pendingPostponedHide?.cancel()
        mode = .normal
        overlay.hide()
        if settings.isPaused {
            state = .paused(settings.pauseDescription ?? "Paused")
        } else {
            state = .active
        }
        logger.log("Popup hidden by cursor at screen edge")
        schedule(after: 5)
    }

    public func resume() {
        settings.resume()
        cancelCountdown(showPostponed: false)
        logger.log("Resumed")
        schedule(after: 0.25)
    }

    public func snooze(seconds: TimeInterval) {
        settings.pause(for: seconds)
        mode = .normal
        overlay.showPostponed(message: "Lock postponed for \(DurationFormatter.compact(seconds))")
        state = .paused(settings.pauseDescription ?? "Paused")
        logger.log("Snoozed for \(Int(seconds))s")
        schedulePostponedHide()
        schedule(after: 5)
    }

    private func tick() {
        switch mode {
        case .normal:
            normalTick()
        case .countdown(let startIdle, let deadline):
            countdownTick(startIdle: startIdle, deadline: deadline)
        case .test(let deadline):
            testTick(deadline: deadline)
        case .verifyingLock(let referenceIdle, let deadline):
            verifyingLockTick(referenceIdle: referenceIdle, deadline: deadline)
        case .locked(let referenceIdle):
            lockedTick(referenceIdle: referenceIdle)
        case .lockFailed(let referenceIdle):
            lockFailedTick(referenceIdle: referenceIdle)
        }
    }

    private func normalTick() {
        let availability = lockService.availability(promptForAccessibility: false)
        if availability.strategy == nil {
            let message = availability.reason ?? "No lock strategy is available."
            state = .disabled(message)
            schedule(after: 5)
            return
        }

        settings.clearExpiredPause()
        do {
            let idle = try idleReader.idleSeconds()
            lastHIDError = nil
            let decision = IdleStateMachine.decision(
                idleSeconds: idle,
                delaySeconds: settings.lockDelaySeconds,
                countdownSeconds: settings.countdownSeconds,
                pausedIndefinitely: settings.pausedIndefinitely,
                pausedUntil: settings.pausedUntil
            )
            handle(decision: decision, idleSeconds: idle)
        } catch {
            let message = error.localizedDescription
            if lastHIDError != message {
                logger.log("HID idle read failed: \(message)")
                lastHIDError = message
            }
            state = .disabled(message)
            schedule(after: 5)
        }
    }

    private func handle(decision: IdleMonitorDecision, idleSeconds: TimeInterval) {
        switch decision {
        case .paused(let reason):
            overlay.hide()
            state = .paused(reason)
            schedule(after: 5)
        case .active(let nextPoll):
            overlay.hide()
            state = .active
            schedule(after: nextPoll)
        case .countdown(let remaining):
            startCountdown(remaining: remaining, startIdle: idleSeconds)
        case .lockNow:
            logger.log("Idle threshold reached; locking")
            beginLock(referenceIdle: idleSeconds)
        }
    }

    private func startCountdown(remaining: TimeInterval, startIdle: TimeInterval) {
        let rounded = CountdownClock.displaySeconds(remaining: remaining)
        let deadline = Date().addingTimeInterval(TimeInterval(rounded))
        mode = .countdown(startIdle: startIdle, deadline: deadline)
        if settings.soundEnabled {
            NSSound.beep()
        }
        logger.log("Countdown started remaining=\(rounded)s idle=\(Int(startIdle))s")
        overlay.showCountdown(remainingSeconds: rounded)
        state = .countdown(rounded)
        schedule(after: CountdownClock.nextPollInterval(until: deadline))
    }

    private func countdownTick(startIdle: TimeInterval, deadline: Date) {
        do {
            let idle = try idleReader.idleSeconds()
            if IdleStateMachine.shouldCancelCountdown(currentIdle: idle, countdownStartIdle: startIdle) {
                if isCursorAtScreenEdge() {
                    logger.log("Countdown canceled by HID activity at screen edge; popup hidden")
                    cancelCountdown(showPostponed: false)
                    state = .active
                } else {
                    logger.log("Countdown canceled by HID activity")
                    cancelCountdown(showPostponed: true)
                }
                schedule(after: 5)
                return
            }

            let rounded = CountdownClock.displaySeconds(until: deadline)
            if rounded <= 0 {
                logger.log("Countdown reached zero; locking")
                lockNow()
                return
            }

            overlay.updateCountdown(remainingSeconds: rounded)
            state = .countdown(rounded)
            schedule(after: CountdownClock.nextPollInterval(until: deadline))
        } catch {
            let message = error.localizedDescription
            logger.log("HID idle read failed during countdown: \(message)")
            cancelCountdown(showPostponed: false)
            state = .disabled(message)
            schedule(after: 5)
        }
    }

    private func testTick(deadline: Date) {
        let rounded = CountdownClock.displaySeconds(until: deadline)
        if rounded <= 0 {
            logger.log("Test countdown completed")
            mode = .normal
            overlay.showTestComplete()
            state = .active
            schedulePostponedHide()
            schedule(after: 5)
            return
        }

        overlay.updateCountdown(remainingSeconds: rounded)
        state = .countdown(rounded)
        schedule(after: CountdownClock.nextPollInterval(until: deadline))
    }

    private func verifyingLockTick(referenceIdle: TimeInterval?, deadline: Date) {
        switch LockAttemptGuard.decision(
            sessionState: sessionLockReader.currentState(),
            now: Date(),
            deadline: deadline
        ) {
        case .waiting:
            schedule(after: 0.25)
        case .confirmed:
            confirmHostLock(referenceIdle: referenceIdle)
        case .failed:
            let message = "This Mac did not confirm that it locked. Automatic retries are stopped until local keyboard or mouse activity is detected."
            logger.log("Lock request was not confirmed; automatic retry suppressed")
            mode = .lockFailed(referenceIdle: referenceIdle)
            state = .disabled(message)
            schedule(after: 1)
        }
    }

    private func lockedTick(referenceIdle: TimeInterval?) {
        switch sessionLockReader.currentState() {
        case .locked, .unavailable:
            schedule(after: 2)
            return
        case .unlocked:
            logger.log("Host session unlocked; monitoring rearmed")
            mode = .normal
            state = .active
            schedule(after: 0.25)
        }
    }

    private func lockFailedTick(referenceIdle: TimeInterval?) {
        if sessionLockReader.currentState() == .locked {
            confirmHostLock(referenceIdle: referenceIdle)
            return
        }

        guard let referenceIdle else {
            schedule(after: 1)
            return
        }
        rearmAfterUserActivity(referenceIdle: referenceIdle, logMessage: "Local HID activity detected; monitoring rearmed after unconfirmed lock")
    }

    private func rearmAfterUserActivity(referenceIdle: TimeInterval, logMessage: String) {
        do {
            let idle = try idleReader.idleSeconds()
            guard LockAttemptGuard.detectedUserActivity(currentIdle: idle, referenceIdle: referenceIdle) else {
                schedule(after: 1)
                return
            }
            logger.log(logMessage)
            mode = .normal
            state = .active
            schedule(after: 0.25)
        } catch {
            schedule(after: 1)
        }
    }

    private func confirmHostLock(referenceIdle: TimeInterval?) {
        guard case .locked = mode else {
            logger.log("Host session lock confirmed")
            mode = .locked(referenceIdle: referenceIdle)
            state = .locked
            schedule(after: 2)
            return
        }
    }

    private func installSessionObserversIfNeeded() {
        guard sessionObserverTokens.isEmpty else {
            return
        }

        let distributed = DistributedNotificationCenter.default()
        sessionObserverTokens.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleSessionLockedSignal() }
        })
        sessionObserverTokens.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleSessionUnlockedSignal() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        sessionObserverTokens.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleSessionLockedSignal() }
        })
        sessionObserverTokens.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleSessionUnlockedSignal() }
        })
    }

    private func removeSessionObservers() {
        guard !sessionObserverTokens.isEmpty else {
            return
        }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        sessionObserverTokens.forEach {
            distributed.removeObserver($0)
            workspace.removeObserver($0)
        }
        sessionObserverTokens.removeAll()
    }

    private func handleSessionLockedSignal() {
        let referenceIdle: TimeInterval?
        switch mode {
        case .verifyingLock(let idle, _), .lockFailed(let idle), .locked(let idle):
            referenceIdle = idle
        default:
            referenceIdle = nil
        }
        confirmHostLock(referenceIdle: referenceIdle)
    }

    private func handleSessionUnlockedSignal() {
        guard case .locked = mode else {
            return
        }
        logger.log("Host session unlocked; monitoring rearmed")
        mode = .normal
        state = .active
        schedule(after: 0.25)
    }

    private func cancelCountdown(showPostponed: Bool) {
        mode = .normal
        if showPostponed {
            overlay.showPostponed()
            state = .active
            schedulePostponedHide()
        } else {
            overlay.hide()
        }
    }

    private func schedulePostponedHide() {
        pendingPostponedHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.overlay.hide()
        }
        pendingPostponedHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func isCursorAtScreenEdge() -> Bool {
        ScreenEdgeDetector.isAtEdge(
            point: NSEvent.mouseLocation,
            screenFrames: NSScreen.screens.map(\.frame)
        )
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer(timeInterval: max(0.1, seconds), repeats: false) { [weak self] _ in
            self?.tick()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}
