import AppKit

/// A permanent 1x1 near-invisible window.
///
/// ScreenCaptureKit only enumerates applications that own a window. Without one
/// alive before the first capture filter is built, our own app is missing from
/// `SCShareableContent.applications`, cannot be excluded from the filter, and
/// the overlay ends up capturing its own output in a feedback loop.
///
/// Technique from sumimakito's Mac-Duo. See NOTICE.
@MainActor
public final class PresenceWindow {

    private let window: NSWindow

    public init() {
        window = NSWindow(
            // On screen, not off it. The filter is built with
            // onScreenWindowsOnly: true, so an off-screen window leaves this
            // app unlisted, nothing gets excluded, and the overlay captures
            // itself in a feedback loop.
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0.004
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    public func keepAlive() {
        window.orderFrontRegardless()
    }
}
