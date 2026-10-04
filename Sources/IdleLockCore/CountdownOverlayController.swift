import AppKit
import SwiftUI

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

public final class CountdownOverlayController {
    fileprivate final class OverlayModel: ObservableObject {
        @Published var title: String
        @Published var detail: String
        @Published var remainingSeconds: Int
        @Published var showsRemaining: Bool

        init(title: String, detail: String, remainingSeconds: Int, showsRemaining: Bool) {
            self.title = title
            self.detail = detail
            self.remainingSeconds = remainingSeconds
            self.showsRemaining = showsRemaining
        }
    }

    private var panels: [NSPanel] = []
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private let model = OverlayModel(
        title: "Locking soon",
        detail: "Move mouse or press any key to stay unlocked.",
        remainingSeconds: 30,
        showsRemaining: true
    )

    public var onSnooze: ((TimeInterval) -> Void)?
    public var onDisable: (() -> Void)?
    public var onDismiss: (() -> Void)?
    public var onEdgeDismiss: (() -> Void)?

    public init() {}

    public func showCountdown(remainingSeconds: Int) {
        model.title = "Locking in \(remainingSeconds) seconds"
        model.detail = "Move mouse or press any key to stay unlocked, or choose extra time."
        model.remainingSeconds = remainingSeconds
        model.showsRemaining = true
        ensurePanels()
        startEventMonitors()
        presentPanels()
    }

    public func updateCountdown(remainingSeconds: Int) {
        guard model.remainingSeconds != remainingSeconds else {
            return
        }

        withAnimation(.easeInOut(duration: 0.28)) {
            model.title = "Locking in \(remainingSeconds) seconds"
            model.remainingSeconds = remainingSeconds
        }
    }

    public func showPostponed(message: String = "Lock postponed", detail: String = "Choose extra time or let this close automatically.") {
        model.title = message
        model.detail = detail
        model.remainingSeconds = 0
        model.showsRemaining = false
        ensurePanels()
        startEventMonitors()
        presentPanels()
    }

    public func showTestComplete() {
        model.title = "Countdown test complete"
        model.detail = "The test did not lock this Mac."
        model.remainingSeconds = 0
        model.showsRemaining = false
        ensurePanels()
        startEventMonitors()
        presentPanels()
    }

    public func hide() {
        stopEventMonitors()
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private func startEventMonitors() {
        startKeyMonitors()
        startMouseMonitors()
    }

    private func stopEventMonitors() {
        stopKeyMonitors()
        stopMouseMonitors()
    }

    private func startKeyMonitors() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard self?.handleKeyDown(event) == true else {
                    return event
                }
                return nil
            }
        }

        if globalKeyMonitor == nil {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                DispatchQueue.main.async {
                    _ = self?.handleKeyDown(event)
                }
            }
        }
    }

    private func stopKeyMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }

        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func startMouseMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]

        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
                guard self?.handleMouseForEdgeDismiss() == true else {
                    return event
                }
                return nil
            }
        }

        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
                DispatchQueue.main.async {
                    _ = self?.handleMouseForEdgeDismiss()
                }
            }
        }
    }

    private func stopMouseMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(blockedModifiers).isEmpty,
              let characters = event.charactersIgnoringModifiers,
              let index = Int(characters),
              SnoozeOption.all.indices.contains(index - 1)
        else {
            return false
        }

        onSnooze?(SnoozeOption.all[index - 1].seconds)
        return true
    }

    private func handleMouseForEdgeDismiss() -> Bool {
        guard ScreenEdgeDetector.isAtEdge(
            point: NSEvent.mouseLocation,
            screenFrames: NSScreen.screens.map(\.frame)
        ) else {
            return false
        }

        onEdgeDismiss?()
        return true
    }

    private func presentPanels() {
        let newlyVisiblePanels = panels.filter { !$0.isVisible }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        newlyVisiblePanels.forEach { panel in
            panel.alphaValue = reduceMotion ? 1 : 0
        }
        panels.forEach { $0.orderFrontRegardless() }

        guard !reduceMotion, !newlyVisiblePanels.isEmpty else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.allowsImplicitAnimation = true
            newlyVisiblePanels.forEach { panel in
                panel.animator().alphaValue = 1
            }
        }
    }

    private func ensurePanels() {
        guard panels.isEmpty else {
            return
        }

        panels = NSScreen.screens.map { screen in
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: screen.frame.size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.setFrame(screen.frame, display: true)
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true

            let view = CountdownOverlayView(
                model: model,
                onSnooze: { [weak self] seconds in self?.onSnooze?(seconds) },
                onDisable: { [weak self] in self?.onDisable?() },
                onDismiss: { [weak self] in self?.onDismiss?() }
            )

            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            container.autoresizingMask = [.width, .height]
            let hostingView = FirstMouseHostingView(rootView: view)
            hostingView.frame = container.bounds
            hostingView.autoresizingMask = [.width, .height]
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: container.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            panel.contentView = container
            return panel
        }
    }
}

private struct CountdownOverlayView: View {
    @ObservedObject var model: CountdownOverlayController.OverlayModel
    let onSnooze: (TimeInterval) -> Void
    let onDisable: () -> Void
    let onDismiss: () -> Void
    private let buttonColumns = [
        GridItem(.fixed(150), spacing: 10),
        GridItem(.fixed(150), spacing: 10),
        GridItem(.fixed(150), spacing: 10),
        GridItem(.fixed(150), spacing: 10)
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    onDismiss()
                }

            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    AnimatedCountdownTitle(
                        title: model.title,
                        remainingSeconds: model.remainingSeconds,
                        animatesNumber: model.showsRemaining
                    )
                    if model.showsRemaining {
                        AnimatedCountdownNumber(value: model.remainingSeconds)
                    }
                    Text(model.detail)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.black.opacity(0.74))
                }

                LazyVGrid(columns: buttonColumns, spacing: 10) {
                    ForEach(SnoozeOption.all) { option in
                        Button {
                            onSnooze(option.seconds)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(option.key)")
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.05, green: 0.26, blue: 0.64))
                                    .frame(width: 36, height: 36)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                Text(option.title)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .frame(width: 150, height: 64)
                            .background(Color(red: 0.05, green: 0.26, blue: 0.64))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button("Disable Locking") {
                    onDisable()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.14, green: 0.18, blue: 0.24))
                .frame(width: 180, height: 42)
                .background(Color(red: 0.89, green: 0.92, blue: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.16), lineWidth: 1)
                )
                .buttonStyle(.plain)
            }
            .padding(28)
            .frame(width: 720)
            .background(Color(red: 0.96, green: 0.96, blue: 0.93))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.20), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 26, x: 0, y: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct AnimatedCountdownTitle: View {
    let title: String
    let remainingSeconds: Int
    let animatesNumber: Bool

    @ViewBuilder
    var body: some View {
        if #available(macOS 14.0, *), animatesNumber {
            titleText
                .contentTransition(.numericText(countsDown: true))
        } else {
            titleText
                .id(title)
                .transition(.opacity)
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.black)
    }
}

private struct AnimatedCountdownNumber: View {
    let value: Int

    @ViewBuilder
    var body: some View {
        if #available(macOS 14.0, *) {
            numberText
                .contentTransition(.numericText(countsDown: true))
        } else {
            ZStack {
                numberText
                    .id(value)
                    .transition(.opacity)
            }
        }
    }

    private var numberText: some View {
        Text("\(value)")
            .font(.system(size: 76, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(red: 0.04, green: 0.19, blue: 0.42))
    }
}

private struct SnoozeOption: Identifiable {
    static let all = [
        SnoozeOption(key: 1, seconds: 900, title: "15 minutes"),
        SnoozeOption(key: 2, seconds: 1_800, title: "30 minutes"),
        SnoozeOption(key: 3, seconds: 3_600, title: "1 hour"),
        SnoozeOption(key: 4, seconds: 7_200, title: "2 hours")
    ]

    let key: Int
    let seconds: TimeInterval
    let title: String

    var id: TimeInterval {
        seconds
    }
}
