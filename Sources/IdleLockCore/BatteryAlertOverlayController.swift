import AppKit
import SwiftUI

private final class BatteryFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

public final class BatteryAlertOverlayController {
    fileprivate final class AlertModel: ObservableObject {
        @Published var content: BatteryAlertContent

        init(content: BatteryAlertContent) {
            self.content = content
        }
    }

    private enum Style {
        case corner
        case fullScreen
    }

    private enum CornerLayout {
        static let cardSize = NSSize(width: 340, height: 104)
        static let shadowPadding: CGFloat = 18
        static let screenInset: CGFloat = 12

        static var panelSize: NSSize {
            NSSize(width: cardSize.width + shadowPadding * 2, height: cardSize.height + shadowPadding * 2)
        }
    }

    private var panels: [NSPanel] = []
    private var presentedStyle: Style?
    private let model = AlertModel(content: .preview(.low))

    public var onDismiss: (() -> Void)?

    public init() {}

    public var isVisible: Bool {
        !panels.isEmpty
    }

    public func show(_ content: BatteryAlertContent) {
        let style: Style = content.level.coversScreen ? .fullScreen : .corner
        if style != presentedStyle {
            removePanels()
        }
        model.content = content
        if panels.isEmpty {
            buildPanels(style: style)
        }
        presentPanels()
    }

    public func update(_ content: BatteryAlertContent) {
        guard isVisible, content != model.content else {
            return
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            model.content = content
        }
    }

    public func hide() {
        removePanels()
    }

    private func removePanels() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        presentedStyle = nil
    }

    private func buildPanels(style: Style) {
        presentedStyle = style
        panels = NSScreen.screens.map { screen in
            switch style {
            case .corner:
                let size = CornerLayout.panelSize
                let visible = screen.visibleFrame
                let frame = NSRect(
                    x: visible.maxX - CornerLayout.screenInset - CornerLayout.cardSize.width - CornerLayout.shadowPadding,
                    y: visible.maxY - CornerLayout.screenInset - CornerLayout.cardSize.height - CornerLayout.shadowPadding,
                    width: size.width,
                    height: size.height
                )
                let view = BatteryCornerCardView(
                    model: model,
                    cardSize: CornerLayout.cardSize,
                    padding: CornerLayout.shadowPadding,
                    onDismiss: { [weak self] in self?.onDismiss?() }
                )
                return makePanel(frame: frame, screen: screen, rootView: view)
            case .fullScreen:
                let view = BatteryFullScreenView(
                    model: model,
                    onDismiss: { [weak self] in self?.onDismiss?() }
                )
                return makePanel(frame: screen.frame, screen: screen, rootView: view)
            }
        }
    }

    private func makePanel<Content: View>(frame: NSRect, screen: NSScreen, rootView: Content) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.setFrame(frame, display: true)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        let hostingView = BatteryFirstMouseHostingView(rootView: rootView)
        hostingView.frame = container.bounds
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
}

private enum BatteryAlertStyle {
    static let cardBackground = Color(red: 0.96, green: 0.96, blue: 0.93)

    static func tint(_ level: BatteryAlertLevel) -> Color {
        switch level {
        case .low:
            return Color(red: 0.70, green: 0.45, blue: 0.00)
        case .veryLow:
            return Color(red: 0.82, green: 0.33, blue: 0.02)
        case .critical:
            return Color(red: 0.74, green: 0.10, blue: 0.10)
        }
    }

    static func symbolName(_ level: BatteryAlertLevel) -> String {
        level == .low ? "battery.25percent" : "battery.0percent"
    }
}

private struct BatteryCornerCardView: View {
    @ObservedObject var model: BatteryAlertOverlayController.AlertModel
    let cardSize: NSSize
    let padding: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        let content = model.content
        let tint = BatteryAlertStyle.tint(content.level)

        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 2) {
                Image(systemName: BatteryAlertStyle.symbolName(content.level))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                BatteryPercentText(value: content.percent, numberSize: 34, signSize: 20, color: tint)
            }
            .frame(width: 84)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(content.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                    if content.isPreview {
                        PreviewBadge()
                    }
                }
                Text(content.detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.black.opacity(0.70))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 24)

            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .frame(width: cardSize.width, height: cardSize.height)
        .background(BatteryAlertStyle.cardBackground)
        .overlay(alignment: .leading) {
            tint.frame(width: 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.20), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.62))
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.07))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
            .padding(8)
        }
        .shadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 6)
        .padding(padding)
    }
}

private struct BatteryFullScreenView: View {
    @ObservedObject var model: BatteryAlertOverlayController.AlertModel
    let onDismiss: () -> Void

    var body: some View {
        let content = model.content
        let tint = BatteryAlertStyle.tint(content.level)

        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    onDismiss()
                }

            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: BatteryAlertStyle.symbolName(content.level))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(content.title)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.black)
                    if content.isPreview {
                        PreviewBadge()
                    }
                }

                BatteryPercentText(value: content.percent, numberSize: 76, signSize: 40, color: tint)

                Text(content.detail)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.black.opacity(0.74))
                    .multilineTextAlignment(.center)

                Button {
                    onDismiss()
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 180, height: 42)
                        .background(tint)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(28)
            .frame(width: 560)
            .background(BatteryAlertStyle.cardBackground)
            .overlay(alignment: .top) {
                tint.frame(height: 5)
            }
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

private struct BatteryPercentText: View {
    let value: Int
    let numberSize: CGFloat
    let signSize: CGFloat
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            number
            Text("%")
                .font(.system(size: signSize, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) percent")
    }

    @ViewBuilder
    private var number: some View {
        if #available(macOS 14.0, *) {
            numberText
                .contentTransition(.numericText(countsDown: true))
        } else {
            numberText
        }
    }

    private var numberText: some View {
        Text("\(value)")
            .font(.system(size: numberSize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

private struct PreviewBadge: View {
    var body: some View {
        Text("PREVIEW")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Color.black.opacity(0.62))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.08))
            .clipShape(Capsule())
    }
}
