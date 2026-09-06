import AppKit

/// Scoped event ownership survives source-row replacement and always ends on
/// release, Escape, deactivation or window closure. It never injects system input.
@MainActor final class BrowserSidebarDragEventSession {
    // MARK: Lifecycle

    isolated deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        notifications.forEach(NotificationCenter.default.removeObserver)
        timer?.invalidate()
    }

    // MARK: Internal

    var onMove: (CGPoint) -> Void = { _ in }
    var onRelease: (CGPoint) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onTick: (TimeInterval) -> Void = { _ in }

    func start(in window: NSWindow?) {
        stop()
        guard let window else { return }
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDragged,
            .leftMouseUp,
            .keyDown,
        ]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            if event.type == .rightMouseDown || event
                .type == .otherMouseDown || (event.type == .leftMouseUp && event.window !== window)
            {
                onCancel()
                return event
            }
            guard event.window === window else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    onCancel()
                    return nil
                }
            } else if event.type == .leftMouseUp {
                onRelease(event.locationInWindow)
            } else {
                onMove(event.locationInWindow)
            }
            return event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            notifications
                .append(NotificationCenter.default
                    .addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.onCancel() }
                    })
        }
        notifications.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onCancel() }
        })
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = min(now - self.lastTick, 0.05)
                self.lastTick = now
                self.onTick(elapsed)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        timer?.invalidate()
        timer = nil
        window = nil
    }

    // MARK: Private

    private weak var window: NSWindow?
    private var monitor: Any?
    private var notifications = [NSObjectProtocol]()
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
}
