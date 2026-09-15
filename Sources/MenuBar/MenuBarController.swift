import AppKit
import ServiceManagement

/// The menu bar surface.
///
/// Five of seven comparable apps are agent apps living only in the menu bar, so
/// that is the convention. Within it, the details that build trust are a live
/// lid-angle readout (five of seven show one) and visible permission state —
/// without them a user whose sensor or permission is broken just sees nothing
/// happen and has no way to tell why.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {

    public enum Health {
        case ready
        case needsScreenRecording
        case noSensor(model: String)
        case noBuiltInDisplay
        case sensorLost
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let onToggle: (Bool) -> Void
    private let angleProvider: () -> Double?
    private let healthProvider: () -> Health
    public var onLog: ((String) -> Void)?
    private var isEnabled = true

    public init(onToggle: @escaping (Bool) -> Void,
                angleProvider: @escaping () -> Double?,
                healthProvider: @escaping () -> Health) {
        self.onToggle = onToggle
        self.angleProvider = angleProvider
        self.healthProvider = healthProvider
        super.init()
    }

    public func install() {
        refreshIcon()
        // Worth logging: the overlay renders above the menu bar, so if the
        // effect is ever stuck on, the icon is hidden underneath it. Knowing
        // the item was actually created separates "never made" from "covered".
        onLog?("menu bar item created: button=\(statusItem.button != nil), "
             + "image=\(statusItem.button?.image != nil)")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuild(menu)
    }

    /// The icon carries state: a warning when something needs attention, so a
    /// broken install is visible at a glance rather than silently doing nothing.
    public func refreshIcon() {
        let symbol: String
        switch healthProvider() {
        case .ready:                symbol = "laptopcomputer"
        case .needsScreenRecording: symbol = "exclamationmark.triangle"
        case .noSensor:             symbol = "laptopcomputer.slash"
        case .noBuiltInDisplay:     symbol = "laptopcomputer.slash"
        case .sensorLost:           symbol = "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Slant")
            ?? NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Slant")
        statusItem.button?.image = image
        // A title fallback guarantees the item is never a zero-width invisible
        // button if a symbol fails to resolve on some OS version.
        statusItem.button?.title = image == nil ? "Slant" : ""
    }

    // Rebuilt each time it opens so the angle readout is live.
    public func menuWillOpen(_ menu: NSMenu) {
        refreshIcon()
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        switch healthProvider() {
        case .ready:
            let angle = angleProvider()
            let text = angle.map { String(format: "Lid angle  %.1f°", $0) } ?? "Lid angle  —"
            menu.addItem(disabled(text))

        case .needsScreenRecording:
            menu.addItem(disabled("Screen Recording permission needed"))
            let open = NSMenuItem(title: "Open Screen Recording Settings…",
                                  action: #selector(openScreenRecording), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            // The detail nearly every competitor omits, and the one that costs
            // users the most time: the grant does not apply until relaunch.
            menu.addItem(disabled("Then quit and reopen Slant"))
            let relaunch = NSMenuItem(title: "Quit and Reopen Slant",
                                      action: #selector(relaunch), keyEquivalent: "")
            relaunch.target = self
            menu.addItem(relaunch)

        case .noSensor(let model):
            menu.addItem(disabled("No lid-angle sensor on this \(model)"))

        case .noBuiltInDisplay:
            menu.addItem(disabled("No built-in display to fold"))

        case .sensorLost:
            menu.addItem(disabled("Lost contact with the lid sensor"))
            let relaunch = NSMenuItem(title: "Quit and Reopen Slant",
                                      action: #selector(relaunch), keyEquivalent: "")
            relaunch.target = self
            menu.addItem(relaunch)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: isEnabled ? "Turn Slant Off" : "Turn Slant On",
                                action: #selector(toggleTapped), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Slant", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openScreenRecording() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func relaunch() {
        let path = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path.path]
        // Give ourselves time to exit before the new instance starts.
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func toggleTapped() {
        isEnabled.toggle()
        onToggle(isEnabled)
        if let menu = statusItem.menu { rebuild(menu) }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Registration can need explicit approval; send them where it lives.
            SMAppService.openSystemSettingsLoginItems()
        }
        if let menu = statusItem.menu { rebuild(menu) }
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }
}
