import Foundation
import LidMotion

/// Where each point of the physical screen looks onto a desktop that never moves.
///
/// The model: the desktop hangs in the vertical plane the screen occupied at 90
/// degrees and stays there. The panel then rotates forward out of that plane.
/// The panel is a window, so for a point on it we follow the viewer's ray
/// onward until it meets the fixed plane, and show whatever is at that spot.
///
/// Everything the effect does falls out of that one idea:
///
/// * the hinge edge never leaves the plane, so the bottom maps one to one and
///   stays exactly as wide as the screen;
/// * rays through the upper panel reach *past* the sides of the desktop, so the
///   picture narrows toward the top and black appears in the upper corners;
/// * those same rays land *above* the top of the desktop, so the picture is
///   progressively cut away from the top.
///
/// Nothing is squeezed. The desktop is never deformed to fit the panel; the
/// panel simply sees less of it. That mismatch — the shape moves, the picture
/// does not — is what reads as glass rather than as a shrinking billboard, and
/// it is the same trick the iPhone Duo's fold uses.
public enum FoldGeometry {

    /// Viewer distance from the screen, in screen heights.
    /// Smaller is a nearer viewpoint and a more dramatic fold.
    ///
    /// Fitted to the reference video, not chosen: measuring the width taper
    /// across four frames of a real lid closing gives 3.05 (rms 0.006). That is
    /// about 58cm from a 14 inch panel, and it lands within 3% of where the
    /// camera filming that video actually stood.
    public static var eyeDistance: Double {
        tunable("SLANT_EYE_DISTANCE", default: 3.8)
    }

    /// Where the assumed viewpoint sits, as a fraction of the panel's top edge.
    ///
    /// 1 means level with the top edge of the screen, and that single choice is
    /// what makes the height rule come out exactly right. Substituting
    /// `eyeHeight = sin(theta)` into the vertical mapping collapses it:
    ///
    ///     V(top) = h + t*(sin(theta) - h)  ->  sin(theta) + t*0  =  sin(theta)
    ///
    /// A panel of height h tipped to theta stands `h*sin(theta)` tall, so it can
    /// cover an upright snapshot up to exactly `sin(theta)` of its height. Half
    /// the picture at 30 degrees. The eye distance drops out entirely, so the
    /// vertical behaviour no longer depends on a viewer position nobody can
    /// measure — while the horizontal taper, which depends only on distance,
    /// still comes from real perspective.
    ///
    /// It also bounds the stretch. Filling the panel with `sin(theta)` of the
    /// picture costs `1/sin(theta)` of vertical magnification, handed straight
    /// back by the panel's own foreshortening: 1.4x at 45 degrees, 2x at 30, and
    /// no angle at which it blows up. Assuming a fixed seated eye instead needed
    /// 5x at 45 degrees and went singular at 36, and it looked like it.
    ///
    /// 0 returns to a viewpoint level with the hinge, which is the reference
    /// video's tripod and a much gentler crop. Override with SLANT_EYE_LEVEL.
    public static var eyeLevel: Double {
        tunable("SLANT_EYE_LEVEL", default: 1)
    }

    /// The assumed eye height for a given lid angle, in screen heights.
    public static func eyeHeight(lidAngle: Double) -> Double {
        let clamped = min(max(lidAngle, 0), 180)
        return eyeLevel * sin(clamped * .pi / 180)
    }

    /// The angle at which the assumed viewer lies in the plane of the panel.
    ///
    /// Past it the mapping turns the picture inside out. With the eye tracking
    /// the top edge this needs `eyeLevel > eyeDistance` to happen at all, so it
    /// is unreachable — but the explicit-viewpoint mapping below still accepts a
    /// fixed eye, and a fixed eye does have one.
    public static func horizonAngle(eyeDistance: Double, eyeHeight: Double) -> Double {
        atan2(eyeHeight, max(eyeDistance, 0.2)) * 180 / .pi
    }

    /// How much the picture is magnified vertically at the hinge to survive the
    /// panel's foreshortening. What bounds how far the fold may usefully go.
    public static func preDistortion(lidAngle: Double,
                                     eyeDistance: Double, eyeHeight: Double) -> Double {
        let radians = lidAngle * .pi / 180
        let rate = sin(radians) - eyeHeight * cos(radians) / max(eyeDistance, 0.2)
        return rate > 0.0001 ? 1 / rate : .infinity
    }

    /// The lid angle at which the desktop is captured and pinned. At this angle
    /// the mapping is exactly the identity, so the effect begins from nothing.
    public static var referenceAngle: Double {
        tunable("SLANT_REFERENCE_ANGLE", default: 90)
    }

    /// Texture coordinates for the four screen corners, in the order
    /// bottom-left, bottom-right, top-right, top-left.
    ///
    /// Values outside 0...1 mean the screen is looking past the edge of the
    /// desktop, which the shader paints as void.
    public static func textureCorners(lidAngle: Double) -> [(x: Double, y: Double)] {
        // Past full fold the effect is finished, so the geometry holds there.
        // It used to follow the lid all the way to nought, and the magnification
        // it needs runs away down there — 2.9x at 20 degrees, 5.8x at 10, 11.5x
        // at 5 — so every close ended in a smear nobody asked for. Frozen here
        // rather than inside, so the assumed eye height is derived from the same
        // held angle instead of sliding on underneath it.
        let held = min(max(lidAngle, FoldProgress.fullFoldAngle), referenceAngle)
        return textureCorners(lidAngle: held,
                              eyeDistance: eyeDistance,
                              eyeHeight: eyeHeight(lidAngle: held))
    }

    /// Which mapping to use. Switchable so the two can be compared on one
    /// install — the Screen Recording grant is revoked by every rebuild, so a
    /// second model behind a rebuild is a second permission dance.
    public enum Model: String {
        /// The desktop pinned upright; the panel is a window that cuts into it.
        case pinned
        /// noveum/hinge's trapezoid: everything stays, compressed toward the top.
        case warp
        /// No reprojection: the desktop one texel to one pixel, the panel simply
        /// stopping at sin(theta) of its height. Nothing is magnified, so nothing
        /// can read as stretched — at the cost that the picture is glued to the
        /// glass and foreshortens with it instead of standing still in the room.
        case flat
    }

    public static var model: Model {
        guard let raw = ProcessInfo.processInfo.environment["SLANT_MODEL"],
              let parsed = Model(rawValue: raw) else { return .pinned }
        return parsed
    }

    /// How much of the fold's onset to ease the geometry in over.
    ///
    /// 0 follows the mapping straight from the reference angle, which is what
    /// the reference video does: it already carries 6% of taper at 79 degrees,
    /// long before any "nothing until 75" would allow. 1 holds the mapping at
    /// exact passthrough until the onset and eases in across the whole fold.
    ///
    /// The two cannot both be had. The video's effect begins as soon as the lid
    /// leaves its resting angle; a quiet stretch down to 75 degrees is a
    /// departure from it, not a refinement of it.
    public static var onsetEase: Double {
        tunable("SLANT_ONSET_EASE", default: 0)
    }

    /// How much wider the top row samples at full fold. hinge ships 0.30.
    public static var warpTaper: Double {
        tunable("SLANT_TAPER", default: 0.30)
    }

    /// noveum/hinge's mapping (MIT), `Fold.metal:34-36`:
    ///
    ///     float taper = p.taper * p.progress;
    ///     float q = (1.0 + taper) / (1.0 + taper * in.uv.y);
    ///     float2 uv = float2((in.uv.x - 0.5) * q + 0.5, in.uv.y * q);
    ///
    /// with `uv.y = 0` at the top. In our corner convention that reduces to:
    /// hinge row identity, top row sampled `taper/2` wider on each side, top
    /// texture row still exactly 1.
    ///
    /// No eye position and no trigonometry. It is a homography — both source
    /// coordinates are linear in `(x, y, 1)` over `w = 1 + t*y` — so it needs
    /// none of the machinery above, only different corners.
    ///
    /// What it does not do is crop. The whole desktop stays on screen and the
    /// upper part is compressed, which is the handoff's rejected attempt #1.
    /// Its compensation is that the distortion is gentle and bounded: isotropic
    /// at the top, and only `1 + taper` of vertical stretch at the hinge,
    /// against 2.34x for the pinned model at full fold.
    /// The flat model's mapping: the identity, at every angle.
    public static func flatCorners() -> [(x: Double, y: Double)] {
        [(x: 0, y: 0), (x: 1, y: 0), (x: 1, y: 1), (x: 0, y: 1)]
    }

    /// How much of the picture's height the panel still shows.
    ///
    /// Only the flat model hides any: a panel of height h tipped to theta stands
    /// `h*sin(theta)` tall, and with no magnification to fill the rest, that is
    /// exactly how far up the picture it reaches. The other two magnify to fill
    /// the panel, so they always show a full column and cut from the top by
    /// moving the texture coordinate instead.
    public static func visibleHeight(lidAngle: Double, model: Model) -> Double {
        guard model == .flat else { return 1 }
        let clamped = min(max(lidAngle, 0), 90)
        return sin(clamped * .pi / 180)
    }

    public static func warpCorners(progress: Double) -> [(x: Double, y: Double)] {
        let taper = warpTaper * min(max(progress, 0), 1)
        return [
            (x: 0, y: 0),
            (x: 1, y: 0),
            (x: 1 + taper / 2, y: 1),
            (x: -taper / 2, y: 1),
        ]
    }

    /// The mapping eased in from exact passthrough.
    ///
    /// Borrowed from DhananjayBhosale/MacDuo (MIT), whose shader blends
    /// `mix(uv, sourceUV, onset)` to start "without a pixel jump from exact
    /// passthrough". Ours blends on the fold's own progress curve.
    ///
    /// This is what makes "nothing until 75 degrees" achievable. The picture is
    /// pinned to the 90 degree plane, so the raw mapping leaves the identity as
    /// soon as the lid leaves 90 — something was always visible up there, no
    /// matter how late blur arrived. At progress 0 this is the identity to the
    /// last bit, and at progress 1 it is the raw mapping untouched, so the
    /// height rule still lands exactly on sin(theta) at full fold.
    ///
    /// It moves the crop toward the reference footage as a side effect: raw
    /// sin(theta) cuts 26% of the picture by 48 degrees where the video cuts
    /// 11%, and blended it cuts 17%.
    public static func textureCorners(lidAngle: Double,
                                      progress: Double) -> [(x: Double, y: Double)] {
        switch model {
        case .warp:   return warpCorners(progress: progress)
        case .flat:   return flatCorners()
        case .pinned: return pinnedCorners(lidAngle: lidAngle, progress: progress)
        }
    }

    /// The pinned mapping, eased in from exact passthrough. Addressed directly
    /// rather than through `model`, so its tests do not depend on which mapping
    /// happens to be selected.
    public static func pinnedCorners(lidAngle: Double,
                                     progress: Double) -> [(x: Double, y: Double)] {
        let ease = min(max(onsetEase, 0), 1)
        let eased = 1 - ease * (1 - min(max(progress, 0), 1))
        let folded = textureCorners(lidAngle: lidAngle)
        guard eased < 1 else { return folded }
        let identity = [(x: 0.0, y: 0.0), (x: 1.0, y: 0.0), (x: 1.0, y: 1.0), (x: 0.0, y: 1.0)]
        return zip(identity, folded).map { flat, bent in
            (x: flat.x + (bent.x - flat.x) * eased,
             y: flat.y + (bent.y - flat.y) * eased)
        }
    }

    /// The same mapping for an explicit viewpoint.
    ///
    /// The reference-video assertions need this: they check the model against
    /// footage shot from a tripod, which is not where the shipped default sits.
    /// Without it those tests would only ever pin the default in place.
    public static func textureCorners(lidAngle: Double,
                                      eyeDistance: Double,
                                      eyeHeight: Double) -> [(x: Double, y: Double)] {
        // Above the reference angle there is nothing to show: the desktop is
        // pinned at that angle, so the mapping is the identity.
        //
        // Below the horizon the panel is edge-on to the assumed viewer and the
        // mapping inverts, so it holds there.
        let angle = min(max(lidAngle,
                            horizonAngle(eyeDistance: eyeDistance, eyeHeight: eyeHeight)),
                        referenceAngle)
        let radians = angle * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let eyeZ = max(eyeDistance, 0.2)
        let eyeY = eyeHeight

        func look(_ screenX: Double, _ screenY: Double) -> (x: Double, y: Double) {
            // The panel point sits at height screenY*sin and stands screenY*cos
            // in front of the fixed plane. Follow the ray from the eye through
            // it until it reaches that plane.
            let denominator = eyeZ - screenY * cosine
            let t = denominator > 0.0001 ? eyeZ / denominator : 1
            return (t * screenX + 0.5, eyeY + t * (screenY * sine - eyeY))
        }

        // The top edge stays in contact with the picture.
        //
        // Just after the effect starts, the top of the panel is tipped far
        // enough forward that the sight line clears the top of the desktop and
        // finds nothing beyond it. Ray projection says paint that black; the
        // reference video has no such band at any angle, and a gap there would
        // read as the picture falling away from the bezel rather than being
        // eaten into. So the top is held against the picture until the crop
        // arrives to take it. The correction is under 3% and gone by 61
        // degrees, where the crop begins in earnest.
        func lookTop(_ screenX: Double) -> (x: Double, y: Double) {
            let corner = look(screenX, 1)
            return (corner.x, min(corner.y, 1))
        }

        return [
            look(-0.5, 0),
            look(0.5, 0),
            lookTop(0.5),
            lookTop(-0.5),
        ]
    }

    /// Reads a tuning override from the environment.
    ///
    /// The look is tuned by eye, and on an unsigned build every rebuild costs
    /// the user a Screen Recording re-grant. Environment overrides mean the
    /// whole feel can be adjusted without recompiling.
    public static func tunable(_ name: String, default fallback: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[name],
              let value = Double(raw) else { return fallback }
        return value
    }
}

/// How far through the effect a given lid angle is, for shaping blur and dim.
///
/// The renderer's diagnostic dump needs a progress value without standing up
/// the whole motion stack. It used to carry its own copy of the curve, which
/// drifted from the real one; since the dump is the only way to see the output
/// without Screen Recording permission, a dump that paces differently from the
/// app is worse than no dump. So this is a thin call through to the same curve,
/// asked for a lid rested high enough to use the onset ceiling.
public enum FoldProgressBridge {
    public static func progress(forLidAngle angle: Double) -> Double {
        FoldProgress.progress(angle: angle,
                              openAngle: FoldProgress.highestStartAngle + FoldProgress.deadZone)
    }
}
