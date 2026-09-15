import TestKit
import LidSensor

enum LidReportTests {
    static func run() {
        TestKit.suite("LidReport") {

            TestKit.test("report 7 parses hundredths of a degree") {
                // 9000 hundredths == 90.00 degrees, little-endian 32-bit
                TestKit.expectEqual(
                    LidReport.degrees(fromReport7: [0x07, 0x28, 0x23, 0x00, 0x00]) ?? -1,
                    90.0, accuracy: 0.001)
            }

            TestKit.test("report 7 preserves sub-degree resolution") {
                // 12345 hundredths == 123.45 degrees
                TestKit.expectEqual(
                    LidReport.degrees(fromReport7: [0x07, 0x39, 0x30, 0x00, 0x00]) ?? -1,
                    123.45, accuracy: 0.001)
            }

            TestKit.test("report 7 rejects wrong report id") {
                TestKit.expectNil(LidReport.degrees(fromReport7: [0x01, 0x28, 0x23, 0x00, 0x00]))
            }

            TestKit.test("report 7 rejects short buffer") {
                TestKit.expectNil(LidReport.degrees(fromReport7: [0x07, 0x28, 0x23]))
            }

            TestKit.test("report 7 rejects out of range") {
                // 40000 hundredths == 400 degrees
                TestKit.expectNil(LidReport.degrees(fromReport7: [0x07, 0x40, 0x9C, 0x00, 0x00]))
            }

            TestKit.test("report 1 parses whole degrees") {
                TestKit.expectEqual(
                    LidReport.degrees(fromReport1: [0x01, 0x5A, 0x00]) ?? -1,
                    90.0, accuracy: 0.001)
            }

            TestKit.test("report 1 rejects wrong report id") {
                TestKit.expectNil(LidReport.degrees(fromReport1: [0x07, 0x5A, 0x00]))
            }

            TestKit.test("report 1 rejects short buffer") {
                TestKit.expectNil(LidReport.degrees(fromReport1: [0x01, 0x5A]))
            }

            TestKit.test("report 1 rejects out of range") {
                TestKit.expectNil(LidReport.degrees(fromReport1: [0x01, 0x90, 0x01]))
            }
        }
    }
}
