import Foundation

/// Parses raw HID feature reports from the MacBook lid-angle sensor.
///
/// Two report formats exist. Report 7 carries hundredths of a degree and is
/// strongly preferred: reading it eliminates whole-degree stepping at the
/// source rather than smoothing it away downstream. Report 1 carries whole
/// degrees and is the fallback for hardware that does not answer report 7.
///
/// Report layouts documented by Sam Henri Gold's LidAngleSensor (report 1)
/// and sumimakito's Mac-Duo (report 7). See NOTICE.
public enum LidReport {

    public static let minDegrees: Double = 0
    public static let maxDegrees: Double = 360

    /// Report 7: 5 bytes `[0x07, b0, b1, b2, b3]`, little-endian UInt32,
    /// hundredths of a degree.
    public static func degrees(fromReport7 bytes: [UInt8]) -> Double? {
        guard bytes.count >= 5, bytes[0] == 0x07 else { return nil }
        let raw = UInt32(bytes[1])
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3]) << 16
            | UInt32(bytes[4]) << 24
        return validated(Double(raw) / 100.0)
    }

    /// Report 1: 3 bytes `[0x01, lo, hi]`, little-endian UInt16, whole degrees.
    public static func degrees(fromReport1 bytes: [UInt8]) -> Double? {
        guard bytes.count >= 3, bytes[0] == 0x01 else { return nil }
        let raw = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        return validated(Double(raw))
    }

    private static func validated(_ degrees: Double) -> Double? {
        guard degrees >= minDegrees, degrees <= maxDegrees else { return nil }
        return degrees
    }
}
