import Foundation
import IOKit
import IOKit.hid

/// Opens the lid-angle HID device and polls it for the current angle.
///
/// Probes report 7 (hundredths of a degree) once at open time and uses it for
/// the lifetime of the connection if the device answers, falling back to
/// report 1 (whole degrees) otherwise. Reading report 7 is what gives Slant
/// sub-degree motion without downstream smoothing.
public final class LidSensor: @unchecked Sendable {

    /// Called on the sensor queue with each new angle in degrees.
    public var onAngle: ((Double) -> Void)?

    /// True when the device answered report 7 and sub-degree data is available.
    public private(set) var hasSubDegreeResolution = false

    /// Retained for the lifetime of the sensor. Releasing the manager
    /// invalidates the device it opened, so reads silently start failing.
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private var timer: DispatchSourceTimer?
    private static let queueKey = DispatchSpecificKey<Void>()
    private let queue = DispatchQueue(label: "app.slant.sensor")

    private static let trackingInterval: DispatchTimeInterval = .microseconds(8_333) // 120Hz
    private static let idleInterval: DispatchTimeInterval = .milliseconds(100)        // 10Hz

    public init?() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Int] = [
            "VendorID": HardwareCompat.vendorID,
            "ProductID": HardwareCompat.productID,
            "PrimaryUsagePage": HardwareCompat.usagePage,
            "PrimaryUsage": HardwareCompat.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let found = devices.first else { return nil }
        device = found

        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return nil }
        self.manager = manager

        queue.setSpecific(key: Self.queueKey, value: ())
        hasSubDegreeResolution = (readReport(id: 7, length: 5) != nil)
    }

    /// 120Hz while the lid is moving, 10Hz at rest.
    public func setTracking(_ active: Bool) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(),
                        repeating: active ? Self.trackingInterval : Self.idleInterval)
        source.setEventHandler { [weak self] in self?.sample() }
        source.resume()
        timer = source
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Reads the current angle once.
    ///
    /// Device access is confined to `queue`. `IOHIDDeviceGetReport` is not
    /// documented as safe to call concurrently against one handle, and this is
    /// reachable from two threads: the 120Hz polling timer, and the main thread
    /// whenever the menu bar asks for a live readout or the app checks the
    /// angle immediately after waking. Confining it also keeps a HID syscall
    /// off the main thread. hinge confines all device access the same way.
    public func currentAngle() -> Double? {
        if Thread.isMainThread || !isOnSensorQueue() {
            return queue.sync { readAngleUnsafe() }
        }
        return readAngleUnsafe()
    }

    private func isOnSensorQueue() -> Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) != nil
    }

    /// Must only be called on `queue`.
    private func readAngleUnsafe() -> Double? {
        if hasSubDegreeResolution {
            return readReport(id: 7, length: 5).flatMap { LidReport.degrees(fromReport7: $0) }
        }
        return readReport(id: 1, length: 3).flatMap { LidReport.degrees(fromReport1: $0) }
    }

    private func sample() {
        guard let value = readAngleUnsafe() else { return }
        onAngle?(value)
    }

    private func readReport(id: Int, length: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: length)
        var size: CFIndex = length
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature,
                                          CFIndex(id), &buffer, &size)
        guard result == kIOReturnSuccess, size >= length else { return nil }
        return buffer
    }
}
