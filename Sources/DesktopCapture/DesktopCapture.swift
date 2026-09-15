import Foundation
import AppKit
import ScreenCaptureKit
import FoldRenderer
import CoreMedia
import CoreGraphics
import Metal
import CoreGraphics
import CoreVideo

/// Triggers the system Screen Recording prompt and registers the app in the
/// privacy list so the user has something to toggle.
///
/// Note the asymmetry: `CGRequestScreenCaptureAccess` is the right call to
/// *prompt*, but `CGPreflightScreenCaptureAccess` is the wrong call to *check*
/// — it can retain a stale result. Checking goes through SCShareableContent.
public enum ScreenRecordingPermission {

    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

public enum CaptureError: Error {
    case permissionDenied
    case noBuiltInDisplay
    case streamFailed(Error)
}

/// Streams the built-in display into Metal textures, excluding our own windows.
public final class DesktopCapture: NSObject, SCStreamOutput, @unchecked Sendable {

    /// Called on the capture queue with each new frame.
    public var onFrame: ((MTLTexture) -> Void)?

    private let device: MTLDevice
    private var stream: SCStream?
    /// Building a filter enumerates every window on the system and measured
    /// ~4.5s on an M4 Pro. Caching it is what makes restarting after wake fast
    /// enough for the effect to appear while the lid is still moving.
    /// Mac-Duo caches for the same reason.
    private var cachedFilter: SCContentFilter?
    private var cachedDisplayID: CGDirectDisplayID?
    private var textureCache: CVMetalTextureCache?
    /// Retained so the MTLTexture handed to the renderer stays valid.
    private var liveTexture: CVMetalTexture?

    /// While paused, incoming frames are dropped without touching
    /// `liveTexture`.
    ///
    /// The renderer keeps sampling the frame it froze at the start of a fold,
    /// and that frame stays alive only because `liveTexture` holds it. Letting
    /// the stream keep overwriting that property releases the very buffer the
    /// GPU is still reading. Mac-Duo sidesteps this by freezing to a self-owned
    /// CGImage instead of a live stream buffer.
    private let pauseLock = NSLock()
    private var isPaused = false
    private let outputQueue = DispatchQueue(label: "app.slant.capture")

    public init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// Verifies access with a real `SCShareableContent` fetch rather than
    /// `CGPreflightScreenCaptureAccess()`, which can retain a stale result and
    /// wrongly block an otherwise authorised session.
    ///
    /// Critique and technique from DhananjayBhosale's MacDuo. See NOTICE.
    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            let nsError = error as NSError
            SlantLog.write("SCShareableContent failed: domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)")
            // -3801 is SCStreamErrorUserDeclined. Anything else is a real
            // failure and must not be reported to the user as a permission
            // problem, or they will chase a setting that is already correct.
            if nsError.code == -3801 || nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.streamFailed(error)
        }
    }

    /// Logs everything relevant to diagnosing a capture failure.
    public static func logDiagnostics() {
        SlantLog.write("--- Slant diagnostics ---")
        SlantLog.write("bundle id:   \(Bundle.main.bundleIdentifier ?? "nil")")
        SlantLog.write("bundle path: \(Bundle.main.bundlePath)")
        SlantLog.write("preflight screen capture: \(CGPreflightScreenCaptureAccess())")
        SlantLog.write("responsible pid: \(ProcessInfo.processInfo.processIdentifier)")
    }

    public func start() async throws {
        let configuration = SCStreamConfiguration()
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.showsCursor = false
        configuration.queueDepth = 5
        // The picture is frozen for the duration of a fold, so a fast stream
        // buys nothing and costs battery all day. Ten per second bounds how
        // stale the standby image can be at 100ms, which is below the point
        // anyone would notice the fold showing a moment-old desktop, while
        // still costing a fraction of a full-rate stream.
        let fps = Int32(max(1, min(60, Int(FoldGeometry.tunable("SLANT_CAPTURE_FPS", default: 10)))))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: fps)

        // Reuse the cached filter when the display has not changed. This is the
        // difference between reappearing instantly after wake and arriving
        // several seconds too late.
        if let filter = cachedFilter,
           let displayID = cachedDisplayID,
           CGDisplayIsBuiltin(displayID) != 0 {
            configuration.width = Int(CGDisplayPixelsWide(displayID))
            configuration.height = Int(CGDisplayPixelsHigh(displayID))
            try await begin(filter: filter, configuration: configuration)
            SlantLog.write("capture restarted from cached filter")
            return
        }

        // The presence window needs a moment to register with the window server
        // before SCShareableContent will list this application. Without the
        // wait, ownApplications comes back empty and the overlay ends up in its
        // own capture.
        try? await Task.sleep(nanoseconds: 500_000_000)

        let content = try await shareableContent()

        guard let display = content.displays.first(where: {
            CGDisplayIsBuiltin($0.displayID) != 0
        }) else { throw CaptureError.noBuiltInDisplay }

        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        SlantLog.write("self-exclusion: matched \(ownApplications.count) own application(s)")
        if ownApplications.isEmpty {
            SlantLog.write("WARNING: not listed in SCShareableContent — feedback loop likely")
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )

        configuration.width = display.width
        configuration.height = display.height

        cachedFilter = filter
        cachedDisplayID = display.displayID
        try await begin(filter: filter, configuration: configuration)
    }

    private func begin(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        do {
            try await newStream.startCapture()
        } catch {
            throw CaptureError.streamFailed(error)
        }
        stream = newStream
    }

    /// Drops the cached filter, forcing a full rebuild on the next start.
    /// Needed when the display configuration actually changes.
    public func invalidateFilter() {
        cachedFilter = nil
        cachedDisplayID = nil
    }

    /// Stops or resumes handing frames to the renderer.
    public func setPaused(_ paused: Bool) {
        pauseLock.lock()
        isPaused = paused
        pauseLock.unlock()
    }

    public func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        pauseLock.lock()
        let paused = isPaused
        pauseLock.unlock()
        guard !paused else { return }

        guard type == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }

        // Let the pool reclaim surfaces promptly; Mac-Duo flushes every frame.
        CVMetalTextureCacheFlush(cache, 0)

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, imageBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard result == kCVReturnSuccess,
              let wrapped = cvTexture,
              let texture = CVMetalTextureGetTexture(wrapped) else { return }

        liveTexture = wrapped
        onFrame?(texture)
    }
}
