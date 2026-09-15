import AppKit
import QuartzCore

/// A borderless, click-through, always-on-top window covering the entire
/// built-in framebuffer.
///
/// Sits at `CGShieldingWindowLevel()` — the level the login and lock screens use
/// — so it renders above the menu bar, the notch region, the Dock and
/// full-screen apps. Sized to `NSScreen.frame` rather than `visibleFrame`, which
/// already includes the notch area.
///
/// Window level technique from sumimakito's Mac-Duo. See NOTICE.
public final class FoldOverlayWindow: NSWindow {

    public let metalLayer = CAMetalLayer()

    public init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        metalLayer.frame = host.bounds
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.contentsScale = screen.backingScaleFactor
        metalLayer.drawableSize = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )
        host.layer?.addSublayer(metalLayer)
        contentView = host
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// Put the window on screen but invisible.
    ///
    /// `hide()` only orders the window out; the Metal layer keeps whatever it
    /// last drew. Ordering straight back in therefore flashes the final frame of
    /// the previous fold for one refresh before the new one lands. The layer
    /// still needs to be on screen to get a drawable, so it goes on screen at
    /// zero alpha and `reveal()` brings it up once there is something to see.
    public func prepareHidden() {
        alphaValue = 0
        orderFrontRegardless()
    }

    public func reveal() { alphaValue = 1 }

    public func show() { orderFrontRegardless() }

    public func hide() {
        orderOut(nil)
        alphaValue = 0
    }
}
