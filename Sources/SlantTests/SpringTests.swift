import TestKit
import LidMotion

enum SpringTests {
    static func run() {
        TestKit.suite("CriticallyDampedSpring") {

            TestKit.test("converges to target") {
                var spring = CriticallyDampedSpring(value: 0, frequency: 16)
                for _ in 0..<600 { spring.advance(to: 100, dt: 1.0 / 60.0) }
                TestKit.expectEqual(spring.value, 100, accuracy: 0.01)
            }

            TestKit.test("does not overshoot") {
                var spring = CriticallyDampedSpring(value: 0, frequency: 16)
                var maximum = 0.0
                for _ in 0..<600 {
                    spring.advance(to: 100, dt: 1.0 / 60.0)
                    maximum = max(maximum, spring.value)
                }
                TestKit.expectLessThanOrEqual(maximum, 100.5, "critically damped must not bounce")
            }

            TestKit.test("starts moving then comes to rest") {
                var spring = CriticallyDampedSpring(value: 0, frequency: 16)
                spring.advance(to: 100, dt: 1.0 / 60.0)
                TestKit.expectFalse(spring.isAtRest, "should be moving after one step")
                for _ in 0..<600 { spring.advance(to: 100, dt: 1.0 / 60.0) }
                TestKit.expectTrue(spring.isAtRest, "should settle")
            }

            TestKit.test("zero delta time is a no-op") {
                var spring = CriticallyDampedSpring(value: 10, frequency: 16)
                spring.advance(to: 100, dt: 0)
                TestKit.expectEqual(spring.value, 10, accuracy: 0)
            }

            // hinge scales spring stiffness with lid speed (30 -> 55 rad/s).
            // A constant stiffness either lags a fast close or feels rigid on a
            // slow one; scaling it tracks the hand at both speeds.
            TestKit.test("stiffens while moving fast") {
                var spring = CriticallyDampedSpring(value: 0, frequency: 16)
                TestKit.expectEqual(spring.currentFrequency, 16, accuracy: 0.001, "at rest")
                for _ in 0..<6 { spring.advance(to: 1, dt: 1.0 / 60.0) }
                TestKit.expectTrue(spring.currentFrequency > 16,
                                   "should stiffen while moving, got \(spring.currentFrequency)")
            }

            TestKit.test("stiffness is bounded") {
                var spring = CriticallyDampedSpring(value: 0, frequency: 16)
                for _ in 0..<30 { spring.advance(to: 1000, dt: 1.0 / 60.0) }
                TestKit.expectLessThanOrEqual(spring.currentFrequency, 16 + 24.0001,
                                              "bonus must be capped")
            }

            TestKit.test("relaxes back to base stiffness once settled") {
                var spring = CriticallyDampedSpring(value: 0, frequency: 16)
                for _ in 0..<600 { spring.advance(to: 1, dt: 1.0 / 60.0) }
                TestKit.expectEqual(spring.currentFrequency, 16, accuracy: 0.5, "settled")
            }

            TestKit.test("still does not overshoot when stiffening") {
                var spring = CriticallyDampedSpring(value: 0, frequency: 16)
                var maximum = 0.0
                for _ in 0..<600 {
                    spring.advance(to: 1, dt: 1.0 / 60.0)
                    maximum = max(maximum, spring.value)
                }
                TestKit.expectLessThanOrEqual(maximum, 1.005, "must stay critically damped")
            }

            TestKit.test("large delta time stays stable") {
                var spring = CriticallyDampedSpring(value: 0, frequency: 16)
                for _ in 0..<10 { spring.advance(to: 100, dt: 0.5) }
                TestKit.expectTrue(spring.value.isFinite, "must not diverge")
                TestKit.expectLessThanOrEqual(spring.value, 101, "must not explode")
            }
        }
    }
}
