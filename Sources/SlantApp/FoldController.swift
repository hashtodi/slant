import AppKit
import Metal
import QuartzCore
import LidSensor
import LidMotion
import DesktopCapture
import FoldOverlay
import FoldRenderer
import Lifecycle
import MenuBar

/// Owns the whole pipeline: sensor to spring to renderer to overlay.
@MainActor
final class FoldController {

    var onFailure: ((String) -> Void)?
    /// Set once start() determines why it could not run, for the menu bar.
    private(set) var health: MenuBarController.Health = .ready

    private let presence = PresenceWindow()
    private var sensor: LidSensor?
    private var capture: DesktopCapture?
    private var overlay: FoldOverlayWindow?
    private var renderer: FoldRenderer?
    private var displayLink: CADisplayLink?
    private var demoTimer: Timer?

    /// Smooths the lid angle itself, in degrees.
    ///
    /// An earlier version sprang an abstract 0...1 progress and then converted
    /// it back to an angle for the projection. That round trip ran the motion
    /// through a second easing curve and pushed the whole effect down the
    /// range: at a real 80 degrees it was drawing 85, so nothing visible
    /// happened until around 60. The projection is already gentle near the
    /// reference angle; it needs no help.
    private var spring = CriticallyDampedSpring(value: 90, frequency: 16)
    private var stillness = LidStillness(seed: 100)
    /// The lid angle the projection should settle at, in degrees.
    private var targetAngle: Double = 90
    private var latestTexture: MTLTexture?
    private var lastTimestamp: CFTimeInterval = 0

    // Demo-mode telemetry, so a run can be verified without eyeballing it.
    private var framesReceived = 0
    private var rendersPerformed = 0
    private var rendersFailed = 0
    private(set) var lastAngle: Double = 0
    private var framesFrozen = 0

    /// While the lid is moving the desktop is not changing, so the picture is
    /// frozen at the moment the fold begins.
    ///
    /// This is the difference between a fold that looks solid and one that
    /// shimmers. A live feed during the fold means the overlay can appear in its
    /// own capture, and means capture cadence beats against render cadence.
    /// Neither can happen to a still image.
    private var isFolding = false
    /// Frames of THIS fold that have been handed to the compositor.
    private var foldFramesDrawn = 0
    private var hasDumped = false
    private var demoCyclesDone = 0
    private var demoStarted: CFTimeInterval = 0
    private var overlayShownAt: CFTimeInterval = 0

    /// Increments for every frame accepted from capture.
    ///
    /// The renderer rebuilds its blur pyramid when this changes. It cannot key
    /// off the texture object, because CVMetalTextureCache recycles those and a
    /// fresh frame can arrive wearing an old object's identity — which is
    /// exactly how a changed desktop ended up folding with a stale picture.
    private var frameGeneration: UInt64 = 0

    /// The lid angle the renderer should draw, smoothed by the spring.
    ///
    /// The geometry is driven by an angle rather than an abstract 0...1, so the
    /// spring smooths the angle itself and the projection stays physically
    /// meaningful at every instant.
    private var shownAngle: Double = 90

    /// True from the moment start() is entered until it finishes.
    ///
    /// start() suspends at several awaits. Without a flag set *before* the
    /// first one, a menu toggle or a display change can run stop() in the gap
    /// and the suspended call then resumes and rebuilds the whole pipeline
    /// behind the user's back — leaving a sensor and a capture stream running
    /// while the menu says "Turn Slant On", and a display link leaked and still
    /// firing. hinge and Mac-Duo both guard this explicitly.
    private var isStarting = false
    private var lifecycle: LifecycleObserver?
    private var statsTimer: Timer?
    private var peakProgress: Double = 0

    private var isDemo: Bool {
        ProcessInfo.processInfo.environment["SLANT_DEMO"] == "1"
    }

    func start() async {
        guard !isStarting, sensor == nil else { return }
        isStarting = true
        defer { isStarting = false }
        SlantLog.reset()
        DesktopCapture.logDiagnostics()
        presence.keepAlive()

        if !isDemo {
            switch HardwareCompat.diagnose() {
            case .supported:
                break
            case .presentButUnreadable(let model):
                health = .noSensor(model: model)
                onFailure?("""
                Slant found the lid-angle sensor on this \(model), but macOS is \
                exposing it on the vendor page, where it cannot be read.
                """)
                return
            case .unsupported(let model):
                health = .noSensor(model: model)
                onFailure?("""
                This \(model) has no lid-angle sensor. Slant needs one, and no \
                software can substitute for the missing hardware.
                """)
                return
            }
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            onFailure?("Slant could not open a Metal device.")
            return
        }
        guard let screen = builtInScreen() else {
            health = .noBuiltInDisplay
            onFailure?("""
            Slant could not find the built-in display. It only folds the \
            MacBook's own screen, so there is nothing for it to do while the \
            lid is shut or only external displays are connected.
            """)
            return
        }

        // suspendForSleep keeps the overlay and renderer alive so waking is
        // instant. Reuse them rather than building a second set.
        let window: FoldOverlayWindow
        if let existing = overlay {
            window = existing
        } else {
            window = FoldOverlayWindow(screen: screen)
            guard let foldRenderer = FoldRenderer(device: device, layer: window.metalLayer) else {
                onFailure?("Slant could not build its Metal pipeline.")
                return
            }
            overlay = window
            renderer = foldRenderer
        }

        let desktopCapture = DesktopCapture(device: device)
        desktopCapture.onFrame = { [weak self] texture in
            Task { @MainActor in
                guard let self else { return }
                // Freeze only once there is actually something to freeze.
                // Refusing frames before the first one arrives leaves the
                // renderer with no picture and nothing is ever drawn.
                if self.isFolding, self.latestTexture != nil {
                    self.framesFrozen += 1
                    return
                }
                self.latestTexture = texture
                self.frameGeneration &+= 1
                self.framesReceived += 1

                // Diagnostic: write the fold stages to PNG and quit, so the
                // output can be inspected directly rather than described.
                if ProcessInfo.processInfo.environment["SLANT_DUMP"] == "1", !self.hasDumped {
                    self.hasDumped = true
                    let dir = ProcessInfo.processInfo.environment["SLANT_DUMP_DIR"] ?? "/tmp"
                    let files = self.renderer?.dumpStages(texture: texture, to: dir) ?? []
                    SlantLog.write("dumped \(files.count) stage(s): \(files.joined(separator: " "))")
                    SlantLog.write("source texture: \(texture.width)x\(texture.height)")
                    exit(0)
                }
            }
        }
        do {
            try await desktopCapture.start()
        } catch CaptureError.permissionDenied {
            health = .needsScreenRecording
            // Registers Slant in the privacy list and shows the system prompt,
            // so there is something for the user to switch on.
            ScreenRecordingPermission.request()
            onFailure?("""
            Slant needs Screen Recording permission to see the desktop it folds. \
            Open System Settings > Privacy & Security > Screen & System Audio \
            Recording and enable Slant.

            Nothing is recorded and nothing leaves your Mac.
            """)
            return
        } catch {
            onFailure?("Slant could not start screen capture: \(error.localizedDescription)")
            return
        }
        capture = desktopCapture

        startDisplayLink(on: window)

        if isDemo {
            startDemoDriver()
            return
        }

        let lidSensor = LidSensor()
        lidSensor?.onAngle = { [weak self] angle in
            Task { @MainActor in self?.receive(angle: angle) }
        }
        lidSensor?.setTracking(true)
        sensor = lidSensor
        startStats()
        observeLifecycle()
        showImmediatelyIfAlreadyClosing(sensor: lidSensor)
    }

    /// Sleep is not a shutdown.
    ///
    /// The desktop cannot change while the lid is shut, so the frozen picture
    /// stays valid and the capture object keeps its cached filter. Discarding
    /// them means the effect cannot appear until a fresh filter is built, which
    /// measured ~4.5s — long after the lid is open again.
    func suspendForSleep() {
        demoTimer?.invalidate(); demoTimer = nil
        displayLink?.invalidate(); displayLink = nil
        sensor?.stop(); sensor = nil
        capture?.stop()
        foldFramesDrawn = 0
        overlay?.hide()
        lastTimestamp = 0
    }

    func stop() {
        demoTimer?.invalidate()
        demoTimer = nil
        statsTimer?.invalidate()
        statsTimer = nil
        displayLink?.invalidate()
        displayLink = nil
        sensor?.stop()
        sensor = nil
        capture?.stop()
        capture = nil
        foldFramesDrawn = 0
        overlay?.hide()
        overlay = nil
        renderer = nil
        latestTexture = nil
        lastTimestamp = 0
        spring = CriticallyDampedSpring(value: 90, frequency: 16)
        targetAngle = 90
        shownAngle = 90
        isFolding = false
        // `lifecycle` is deliberately kept: it is what rebuilds us on wake.
    }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first {
            guard let number = $0.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    private func receive(angle: Double) {
        lastAngle = angle
        stillness.update(angle: angle, dt: 1.0 / 120.0)
        // The geometry is driven by the angle directly. Clamped at the
        // reference angle, above which the projection is the identity anyway.
        targetAngle = min(angle, FoldGeometry.referenceAngle)
        let active = targetAngle < FoldGeometry.referenceAngle - 0.25
        if active || !spring.isAtRest {
            if !isFolding {
                // Stop the stream handing over frames for the duration of the
                // fold. Refusing them only at this end still let the capture
                // queue recycle the buffer backing the picture we are drawing.
                capture?.setPaused(true)
                sensor?.setTracking(true)
                // On screen but invisible until the first frame of THIS fold is
                // drawn, or the layer's last frame from the previous fold shows
                // for a refresh first.
                foldFramesDrawn = 0
                overlay?.prepareHidden()
            }
            isFolding = true
            displayLink?.isPaused = false
            overlay?.show()
        }
    }

    private func startDisplayLink(on window: FoldOverlayWindow) {
        guard let view = window.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        // Capped at 60 even on ProMotion: the fold is brief and 120Hz here is
        // pure battery cost for no visible benefit.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    /// Drives fold progress from a slow triangle wave instead of the sensor, so
    /// the effect can be screen-recorded with the lid open. You cannot record the
    /// real thing: the display sleeps as the lid shuts.

    /// Periodic telemetry, in both real and demo mode.
    ///
    /// Real mode used to run blind, which is why an obvious feedback loop went
    /// unnoticed until it showed up in a screenshot.
    /// If the lid is already part-closed when we come up — the usual case after
    /// waking from a full close — snap straight to the right amount of fold and
    /// start drawing, rather than waiting for the next sensor movement.
    ///
    /// hinge is the only competitor that does this; Mac-Duo, MacDuo and DuoFlip
    /// all deliberately suppress the effect on wake, and DuoFlip's README admits
    /// it "cannot guarantee a transition on the first frame after wake".
    private func showImmediatelyIfAlreadyClosing(sensor: LidSensor?) {
        guard let angle = sensor?.currentAngle() else { return }
        lastAngle = angle
        let reference = FoldGeometry.referenceAngle
        guard angle < reference - 0.25 else { return }
        let progress = FoldProgress.progress(angle: angle, openAngle: stillness.anchor)
        targetAngle = min(angle, reference)
        spring.snap(to: targetAngle)
        shownAngle = targetAngle
        isFolding = true
        overlay?.show()
        displayLink?.isPaused = false
        SlantLog.write(String(format: "wake: lid already at %.2f, snapping to %.3f", angle, progress))
    }

    /// An absolute ceiling on demo mode regardless of cycle length.
    static let demoHardLimit: CFTimeInterval = 180

    /// How long the overlay may stay up before it is forced down.
    ///
    /// A stuck sensor or a wedged spring must not be able to leave a
    /// full-screen overlay covering the machine indefinitely. The overlay hides
    /// the menu bar while it is up, which is precisely when a user most needs
    /// to reach the menu bar to quit.
    static let overlayWatchdog: CFTimeInterval = 25

    /// Current lid angle, for the menu bar readout.
    func currentAngle() -> Double? {
        // Only report an angle while a sensor is actually attached. Falling
        // back to the last seen value made a dead sensor look alive.
        guard sensor != nil else { return nil }
        return lastAngle > 0 ? lastAngle : nil
    }

    private func startStats() {
        guard ProcessInfo.processInfo.environment["SLANT_QUIET"] != "1" else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                SlantLog.write(String(
                    format: "angle=%.2f open=%.2f targetAngle=%.2f shownAngle=%.2f drawn=%d failed=%d fresh=%d frozen=%d frozenPicture=%@",
                    self.lastAngle, self.stillness.anchor, self.targetAngle,
                    self.shownAngle, self.rendersPerformed, self.rendersFailed,
                    self.framesReceived, self.framesFrozen,
                    self.isFolding ? "yes" : "no"))
            }
        }
    }

    private func startDemoDriver() {
        foldFramesDrawn = 0
        overlay?.prepareHidden()
        overlay?.show()
        displayLink?.isPaused = false
        startStats()
        let period = FoldGeometry.tunable("SLANT_PERIOD", default: 6)
        let maxCycles = FoldGeometry.tunable("SLANT_DEMO_CYCLES", default: 3)
        let started = CACurrentMediaTime()
        demoStarted = started
        SlantLog.write(String(format:
            "demo mode: %.0f cycles of %.0fs, then quitting. Stop early with: pkill -f SlantApp",
            maxCycles, period))
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let total = CACurrentMediaTime() - started

                // A full-screen overlay that never stops is not something to
                // leave running on someone's machine. Demo mode exists to be
                // recorded, so it ends by itself.
                if total >= period * maxCycles || total >= Self.demoHardLimit {
                    SlantLog.write("demo mode finished, quitting")
                    NSApp.terminate(nil)
                    return
                }

                let elapsed = total.truncatingRemainder(dividingBy: period)
                let half = period / 2
                let next = elapsed < half ? elapsed / half : (period - elapsed) / half
                if next > 0.001 { self.isFolding = true }
                let reference = FoldGeometry.referenceAngle
                self.targetAngle = reference - next * (reference - FoldProgress.fullFoldAngle)
            }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp

        if !isDemo {
            if overlayShownAt == 0 { overlayShownAt = now }
            if now - overlayShownAt > Self.overlayWatchdog {
                SlantLog.write("watchdog: overlay up too long, forcing it down")
                overlayShownAt = 0
                targetAngle = FoldGeometry.referenceAngle
                spring.snap(to: FoldGeometry.referenceAngle)
                shownAngle = FoldGeometry.referenceAngle
                isFolding = false
                link.isPaused = true
                lastTimestamp = 0
                foldFramesDrawn = 0
        overlay?.hide()
                return
            }
        }
        let dt = lastTimestamp == 0 ? 1.0 / 60.0 : now - lastTimestamp
        lastTimestamp = now

        spring.advance(to: targetAngle, dt: dt)
        shownAngle = spring.value

        if let texture = latestTexture {
            // Count only frames that actually reached the screen.
            let shownProgress = FoldProgressBridge.progress(forLidAngle: shownAngle)
            if renderer?.render(texture: texture, lidAngle: shownAngle,
                                progress: shownProgress,
                                generation: frameGeneration) == true {
                rendersPerformed += 1
                // Two, not one: render() returns once the buffer is committed,
                // and presentation is asynchronous, so revealing on the first
                // can still beat the frame onto the glass. The second costs one
                // refresh — about 16ms — and makes it certain.
                foldFramesDrawn += 1
                if foldFramesDrawn == 2 { overlay?.reveal() }
            } else {
                rendersFailed += 1
            }
            peakProgress = min(peakProgress, spring.value)
        }

        // Idle costs nothing: once the spring settles fully open, stop drawing.
        let reference = FoldGeometry.referenceAngle
        if spring.isAtRest, spring.value >= reference - 0.25, targetAngle >= reference - 0.25 {
            // Fully open again: unfreeze so the next fold uses a fresh picture.
            isFolding = false
            overlayShownAt = 0
            capture?.setPaused(false)
            if !isDemo {
                // Drop back to the idle polling tier. This existed but was
                // never engaged, so the sensor ran at 120Hz all day.
                sensor?.setTracking(false)
                link.isPaused = true
                lastTimestamp = 0
                foldFramesDrawn = 0
        overlay?.hide()
            }
        }
    }
}


extension FoldController {

    /// Sleep, wake and display changes all invalidate a running capture or the
    /// HID connection, so each one tears down and rebuilds.
    func observeLifecycle() {
        guard lifecycle == nil else { return }
        let observer = LifecycleObserver(
            onSleep: { [weak self] in self?.suspendForSleep() },
            onWake: { [weak self] in self?.reconnect(attemptsRemaining: 5) },
            onScreensChanged: { [weak self] in
                guard let self else { return }
                // A real display change is the one case where the cached filter
                // is genuinely stale.
                self.capture?.invalidateFilter()
                self.stop()
                Task { await self.start() }
            }
        )
        observer.observe()
        lifecycle = observer
    }

    /// The HID device is briefly absent immediately after wake, so retry rather
    /// than give up on the first failure.
    func reconnect(attemptsRemaining: Int) {
        Task { @MainActor in
            await start()
            guard sensor == nil else { return }

            guard attemptsRemaining > 1 else {
                // Giving up silently leaves capture and the overlay running
                // with no sensor driving them, and a menu readout frozen on a
                // stale angle that still looks live.
                health = .sensorLost
                SlantLog.write("sensor did not come back after wake; stopping")
                onFailure?("""
                Slant lost contact with the lid-angle sensor after waking and \
                could not reconnect. Quit and reopen Slant to try again.
                """)
                stop()
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            reconnect(attemptsRemaining: attemptsRemaining - 1)
        }
    }
}
