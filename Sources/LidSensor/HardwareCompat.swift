import Foundation
import IOKit
import IOKit.hid

public enum LidSupport: Equatable {
    case supported
    case presentButUnreadable(model: String)
    case unsupported(model: String)
}

/// Identifies the lid-angle sensor and diagnoses why it is unavailable when it is.
///
/// Device identification (vendor, product, usage page, usage) was reverse
/// engineered by Sam Henri Gold's LidAngleSensor. See NOTICE.
public enum HardwareCompat {

    public static let vendorID = 0x05AC
    public static let productID = 0x8104
    public static let usagePage = 0x0020   // Sensor
    public static let usage = 0x008A       // Orientation

    /// The machine identifier, e.g. "Mac16,8".
    public static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown Mac" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        // sysctl reports the length including the trailing NUL; decoding it
        // would leave one in the string.
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Two-tier probe.
    ///
    /// Tier 1 matches the full sensor-page descriptor. Tier 2 checks whether the
    /// product exists under any usage page at all, which distinguishes "this Mac
    /// has no sensor" from "this Mac has the sensor but exposes it where we
    /// cannot read it". Every competing app collapses both into one dead end.
    public static func diagnose() -> LidSupport {
        let model = hardwareModel()

        if matchCount([
            "VendorID": vendorID,
            "ProductID": productID,
            "PrimaryUsagePage": usagePage,
            "PrimaryUsage": usage,
        ]) > 0 {
            return .supported
        }

        if matchCount(["VendorID": vendorID, "ProductID": productID]) > 0 {
            return .presentButUnreadable(model: model)
        }

        return .unsupported(model: model)
    }

    private static func matchCount(_ matching: [String: Int]) -> Int {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return 0 }
        return devices.count
    }
}
