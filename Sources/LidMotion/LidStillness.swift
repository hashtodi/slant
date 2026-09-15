import Foundation

/// Learns the angle at which this user habitually rests the lid, so there is no
/// threshold setting to explain or get wrong.
///
/// A hysteresis dwell detector: the candidate angle resets whenever the lid
/// moves more than `moveThreshold`, and only becomes the anchor once it has held
/// still for `requiredDwell`. That rejects both sensor jitter and the transit
/// through intermediate angles while the lid is actually moving.
///
/// Approach follows DhananjayBhosale's MacDuo. See NOTICE.
public struct LidStillness {

    public private(set) var anchor: Double

    private var candidate: Double
    private var dwell: Double = 0

    /// Degrees of movement that reset the dwell timer.
    public static let moveThreshold: Double = 2.0
    /// Seconds of stillness required before the anchor moves.
    ///
    /// One second was far too eager. Pausing part-way through a close for even
    /// a moment made that angle the new "open" position, after which the effect
    /// stopped triggering above it and the anchor ratcheted further down with
    /// every subsequent pause. Four seconds is longer than any pause while
    /// actually moving a lid, and short enough to adapt to a genuinely new
    /// working position.
    public static let requiredDwell: Double = 4.0

    /// The lowest angle that may be treated as a resting position.
    ///
    /// Nobody works with the lid at 30 degrees, and adopting such an angle
    /// would disable the effect across the entire usable range.
    public static let minimumAnchor: Double = 55.0

    public init(seed: Double = 100) {
        anchor = seed
        candidate = seed
    }

    public mutating func update(angle: Double, dt: Double) {
        guard dt > 0 else { return }
        if abs(angle - candidate) >= Self.moveThreshold {
            candidate = angle
            dwell = 0
            return
        }
        dwell += dt
        guard dwell >= Self.requiredDwell,
              candidate >= Self.minimumAnchor,
              abs(candidate - anchor) >= Self.moveThreshold
        else { return }
        anchor = candidate
    }
}
