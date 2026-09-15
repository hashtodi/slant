import Foundation

/// A critically damped spring integrated with semi-implicit Euler.
///
/// Critically damped means it converges as fast as possible without
/// overshooting, which is what a lid should feel like: it follows the hand and
/// settles, it never bounces. Driven once per frame so the render rate is
/// decoupled from the sensor's polling cadence, and so hundredths-of-a-degree
/// sensor jitter never reaches the screen.
public struct CriticallyDampedSpring {

    public private(set) var value: Double
    public private(set) var velocity: Double = 0

    /// Base angular frequency. Higher is stiffer. 16 tracks a hand closing a
    /// lid closely without feeling mechanical.
    public var frequency: Double

    /// How much stiffer the spring becomes at speed, and how fast it gets there.
    ///
    /// A constant stiffness has to choose: tight enough for a quick close and it
    /// feels rigid on a slow one; soft enough to feel fluid and it lags behind a
    /// fast one. Scaling stiffness with speed tracks the hand at both. hinge
    /// does the same thing, ranging 30 to 55 rad/s.
    public static let maximumStiffnessBonus: Double = 24
    public static let stiffnessPerUnitVelocity: Double = 12

    /// Explicit integration is only stable while `omega * step` stays small.
    /// Because stiffness now rises with velocity, a fixed sub-step is not safe:
    /// faster motion raises omega, which raises acceleration, which raises
    /// velocity again. Sizing each sub-step from the current stiffness breaks
    /// that feedback loop.
    private static let stabilityFactor: Double = 0.5

    /// A stalled frame should not integrate an unbounded span of time.
    private static let maxFrameTime: Double = 1.0
    private static let maxSubSteps = 512

    private static let restValueEpsilon: Double = 0.01
    private static let restVelocityEpsilon: Double = 0.01

    public init(value: Double, frequency: Double = 16) {
        self.value = value
        self.frequency = frequency
    }

    public var isAtRest: Bool {
        abs(velocity) < Self.restVelocityEpsilon
    }

    /// Stiffness right now, including the speed-dependent bonus.
    public var currentFrequency: Double {
        frequency + min(abs(velocity) * Self.stiffnessPerUnitVelocity,
                        Self.maximumStiffnessBonus)
    }

    /// Jumps straight to a value with no motion. Used when the display wakes
    /// with the lid already part-closed: easing in from zero there would be a
    /// visible, wrong animation.
    public mutating func snap(to newValue: Double) {
        value = newValue
        velocity = 0
    }

    public mutating func advance(to target: Double, dt: Double) {
        guard dt > 0 else { return }
        var remaining = min(dt, Self.maxFrameTime)
        var steps = 0
        while remaining > 0, steps < Self.maxSubSteps {
            steps += 1
            // Recomputed per sub-step so the spring stays critically damped as
            // stiffness changes: the damping term uses the same omega.
            let omega = currentFrequency
            let step = min(remaining, Self.stabilityFactor / omega)
            remaining -= step
            let acceleration = omega * omega * (target - value) - 2 * omega * velocity
            velocity += acceleration * step
            value += velocity * step
        }
        if abs(target - value) < Self.restValueEpsilon && isAtRest {
            value = target
            velocity = 0
        }
    }
}
