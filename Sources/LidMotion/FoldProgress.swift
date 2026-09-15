import Foundation

/// Maps a lid angle to a 0...1 fold progress.
///
/// Two things make this feel physical rather than mechanical:
///
/// **A dead zone.** Nothing happens until the lid has dropped a good way below
/// where it rests. Starting the instant the angle moves makes the effect twitch
/// while you are simply adjusting the screen. Every competing implementation
/// gates activation somehow: Mac-Duo defaults to a 90 degree start angle,
/// DuoFlip to 90, CakeAL exposes 40-140, and hinge plays its entire fold out in
/// the last few degrees of travel.
///
/// **A smoothstep curve.** A linear ramp starts and stops abruptly. Easing both
/// ends is what MacDuo and DuoFlip both do, and it reads as motion with weight.
public enum FoldProgress {

    /// Degrees below the resting angle before anything happens at all.
    ///
    /// 18 was far out of line with the field — DuoFlip gates on about 1-2
    /// degrees, hinge on well under one, and Mac-Duo uses an absolute threshold
    /// rather than a relative one. A large dead zone also wastes travel: the
    /// whole effect then has to happen in whatever is left. Eight degrees is
    /// enough to ignore ordinary screen adjustment without eating the range,
    /// and the smoothstep below keeps the onset gentle regardless.
    /// Override with SLANT_DEADZONE.
    public static var deadZone: Double {
        tunable("SLANT_DEADZONE", default: 8)
    }

    /// At or below this angle the fold is complete. Override with SLANT_FULL_ANGLE.
    ///
    /// At or below this angle the fold is complete. Override with SLANT_FULL_ANGLE.
    ///
    /// 30 degrees is where the reference video's fold has run its course, and
    /// it is the angle the height rule is quoted at — half the picture showing.
    /// It costs 2.8x vertical magnification, which is the real limit; a test
    /// holds it. This was briefly 55 to dodge a singularity that a fixed seated
    /// eye introduced, which meant everything below 55 sat at maximum blur.
    public static var fullFoldAngle: Double {
        tunable("SLANT_FULL_ANGLE", default: 30)
    }

    /// The effect never begins above this angle, however high the lid rests.
    ///
    /// A purely relative dead zone starts the fold at 117 degrees for someone
    /// who works at 125, which is the moment their hand touches the lid. The
    /// whole field gates near 90: Mac-Duo and DuoFlip both default to a 90
    /// degree start angle, and CakeAL exposes 40-140. Capping the onset keeps
    /// the quiet stretch that makes the effect feel deliberate, while the
    /// relative dead zone still adapts for anyone working with a low lid.
    /// Override with SLANT_START_CEILING.
    ///
    /// 88, because blur has to be under way before the geometry is obvious.
    ///
    /// Measuring the reference video's sharpness band by band shows the top has
    /// lost nearly all its detail by about 88 degrees, while the panel has
    /// barely started to splay. Holding this at 75 left the first 15 degrees of
    /// the fold carrying a visible crop and taper on a perfectly sharp picture,
    /// which reads as a geometric cut rather than a fold.
    ///
    /// This drives blur and dim only. The geometry is driven by the lid angle
    /// directly and begins at the reference angle regardless.
    public static var highestStartAngle: Double {
        tunable("SLANT_START_CEILING", default: 88)
    }

    /// The angle at which the effect begins, given where this user rests the lid.
    ///
    /// Strictly below where the lid rests. This used to be clamped upward to
    /// guarantee a minimum span, which was harmless while the fold completed at
    /// 22 degrees and became a bug when it moved to 55: the floor could land
    /// above someone's resting angle, and the effect then sat permanently
    /// half-folded with the lid untouched. A short fold is a worse effect; one
    /// that never switches off is a broken one. Someone who works with a very
    /// low lid gets little travel, or none, and `progress` guards that.
    public static func startAngle(openAngle: Double) -> Double {
        min(openAngle - deadZone, highestStartAngle)
    }

    public static func progress(angle: Double, openAngle: Double) -> Double {
        let start = startAngle(openAngle: openAngle)
        let span = start - fullFoldAngle
        guard span > 0 else { return 0 }
        let t = min(max((start - angle) / span, 0), 1)
        return t * t * (3 - 2 * t)   // smoothstep
    }

    static func tunable(_ name: String, default fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[name],
              let value = Double(raw) else { return fallback }
        return value
    }
}
