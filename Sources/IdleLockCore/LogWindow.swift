import AppKit
import SwiftUI

public final class LogWindowController {
    private let logger: IdleLockLogger
    private var window: NSWindow?

    public init(logger: IdleLockLogger) {
        self.logger = logger
    }

    public func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: LogWindowView(logger: logger))
            let created = NSWindow(contentViewController: hosting)
            created.title = "Lock Anyway Log"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.setContentSize(NSSize(width: 760, height: 480))
            created.center()
            window = created
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct LogWindowView: View {
    let logger: IdleLockLogger
    @State private var contents: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(logger.logURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") {
                    refresh()
                }
            }

            ScrollView {
                Text(contents.isEmpty ? "No log entries yet." : contents)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(16)
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        contents = logger.readTail()
    }
}
