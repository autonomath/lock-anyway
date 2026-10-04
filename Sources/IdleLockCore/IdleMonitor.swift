import AppKit
import Foundation

public final class IdleMonitor {
    private enum Mode {
        case normal
        case countdown(startIdle: TimeInterval, deadline: Date)
        case test(deadline: Date)
    }

    private let settings: AppSettings
    private let idleReader: IdleTimeReading
    private let lockService: LockControlling
    private let overlay: CountdownOverlayController
    private let logger: IdleLockLogger
    private var timer: Timer?
    private var mode: Mode = .normal
    private var lastHIDError: String?
    private var pendingPostponedHide: DispatchWorkItem?

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
        logger: IdleLockLogger
    ) {
        self.settings = settings
        self.idleReader = idleReader
        self.lockService = lockService
        self.overlay = overlay
        self.logger = logger
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
        logger.log("Idle monitor started delay=\(Int(settings.lockDelaySeconds))s countdown=\(Int(settings.countdownSeconds))s")
        schedule(after: 0.25)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        overlay.hide()
    }

    public func refreshSoon() {
        schedule(after: 0.25)
    }

    public func lockNow() {
        pendingPostponedHide?.cancel()
        overlay.hide()
        do {
            try lockService.lockNow()
            logger.log("Lock Now completed")
            mode = .normal
            state = .active
            schedule(after: 5)
        } catch {
            let message = error.localizedDescription
            logger.log("Lock failed: \(message)")
            mode = .normal
            state = .disabled(message)
            schedule(after: 5)
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
            lockNow()
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
