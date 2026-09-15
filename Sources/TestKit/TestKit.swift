import Foundation

/// A minimal assertion harness.
///
/// Xcode is not installed on this machine, so neither XCTest nor swift-testing
/// is available. This provides just enough to keep the test-first workflow
/// honest: real assertions, real failure output, real exit codes. Test bodies
/// are written to port to XCTest almost verbatim if Xcode is installed later.
public enum TestKit {

    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var checks = 0
    nonisolated(unsafe) private static var currentSuite = ""

    public static func suite(_ name: String, _ body: () -> Void) {
        currentSuite = name
        body()
    }

    public static func test(_ name: String, _ body: () -> Void) {
        currentName = name
        body()
    }

    nonisolated(unsafe) private static var currentName = ""

    private static func record(_ message: String) {
        failures.append("\(currentSuite) > \(currentName): \(message)")
    }

    public static func expectEqual(_ actual: Double, _ expected: Double,
                                   accuracy: Double = 0, _ label: String = "",
                                   file: String = #fileID, line: Int = #line) {
        checks += 1
        guard abs(actual - expected) > accuracy else { return }
        record("\(label.isEmpty ? "" : label + " — ")expected \(expected) ± \(accuracy), got \(actual)  (\(file):\(line))")
    }

    public static func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                                                 _ label: String = "",
                                                 file: String = #fileID, line: Int = #line) {
        checks += 1
        guard actual != expected else { return }
        record("\(label.isEmpty ? "" : label + " — ")expected \(expected), got \(actual)  (\(file):\(line))")
    }

    public static func expectNil<T>(_ value: T?, _ label: String = "",
                                    file: String = #fileID, line: Int = #line) {
        checks += 1
        guard value != nil else { return }
        record("\(label.isEmpty ? "" : label + " — ")expected nil, got \(String(describing: value!))  (\(file):\(line))")
    }

    public static func expectNotNil<T>(_ value: T?, _ label: String = "",
                                       file: String = #fileID, line: Int = #line) {
        checks += 1
        guard value == nil else { return }
        record("\(label.isEmpty ? "" : label + " — ")expected a value, got nil  (\(file):\(line))")
    }

    public static func expectTrue(_ value: Bool, _ label: String = "",
                                  file: String = #fileID, line: Int = #line) {
        checks += 1
        guard !value else { return }
        record("\(label.isEmpty ? "" : label + " — ")expected true  (\(file):\(line))")
    }

    public static func expectFalse(_ value: Bool, _ label: String = "",
                                   file: String = #fileID, line: Int = #line) {
        checks += 1
        guard value else { return }
        record("\(label.isEmpty ? "" : label + " — ")expected false  (\(file):\(line))")
    }

    public static func expectLessThanOrEqual(_ actual: Double, _ limit: Double,
                                             _ label: String = "",
                                             file: String = #fileID, line: Int = #line) {
        checks += 1
        guard actual > limit else { return }
        record("\(label.isEmpty ? "" : label + " — ")expected <= \(limit), got \(actual)  (\(file):\(line))")
    }

    /// Prints the summary and exits non-zero if anything failed.
    public static func finish() -> Never {
        if failures.isEmpty {
            print("PASS — \(checks) checks, 0 failures")
            exit(0)
        }
        print("FAIL — \(checks) checks, \(failures.count) failures\n")
        for failure in failures { print("  ✗ \(failure)") }
        exit(1)
    }
}
