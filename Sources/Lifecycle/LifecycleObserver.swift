import AppKit

/// Watches the events that invalidate a running capture or HID connection.
@MainActor
public final class LifecycleObserver {

    private let onSleep: () -> Void
    private let onWake: () -> Void
    private let onScreensChanged: () -> Void

    public init(onSleep: @escaping () -> Void,
                onWake: @escaping () -> Void,
                onScreensChanged: @escaping () -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake
        self.onScreensChanged = onScreensChanged
    }

    public func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onSleep() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onWake() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onScreensChanged() }
        }
    }
}
