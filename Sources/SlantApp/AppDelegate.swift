import AppKit
import DesktopCapture
import MenuBar

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = FoldController()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onFailure = { [weak self] message in
            SlantLog.write("FAILURE: " + message)
            Task { @MainActor in self?.menuBar?.refreshIcon() }
            if ProcessInfo.processInfo.environment["SLANT_NO_ALERT"] == "1" {
                exit(2)
            }
            // No modal, and no quitting. The menu bar now carries the reason
            // and the fix, so the app stays available instead of vanishing.
        }
        let bar = MenuBarController(
            onToggle: { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    Task { await self.controller.start() }
                } else {
                    self.controller.stop()
                }
            },
            angleProvider: { [weak self] in self?.controller.currentAngle() },
            healthProvider: { [weak self] in self?.controller.health ?? .ready }
        )
        bar.onLog = { SlantLog.write($0) }
        bar.install()
        menuBar = bar

        SlantLog.write("Slant running. Quit from the menu bar, "
                     + "or from a terminal with: pkill -f SlantApp")

        Task { await controller.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
