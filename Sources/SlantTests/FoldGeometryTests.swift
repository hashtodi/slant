import Foundation
import TestKit
import FoldRenderer
import LidMotion

enum FoldGeometryTests {
    static func run() {
        TestKit.suite("FoldGeometry") {

            // At the reference angle the desktop is exactly where the screen is,
            // so looking through the screen is the identity and the effect
            // begins from nothing rather than snapping on.
            TestKit.test("identity at the reference angle") {
                let c = FoldGeometry.textureCorners(lidAngle: FoldGeometry.referenceAngle)
                TestKit.expectEqual(c[0].x, 0, accuracy: 1e-9, "bottom-left x")
                TestKit.expectEqual(c[0].y, 0, accuracy: 1e-9, "bottom-left y")
                TestKit.expectEqual(c[1].x, 1, accuracy: 1e-9, "bottom-right x")
                TestKit.expectEqual(c[2].x, 1, accuracy: 1e-9, "top-right x")
                TestKit.expectEqual(c[2].y, 1, accuracy: 1e-9, "top-right y")
                TestKit.expectEqual(c[3].x, 0, accuracy: 1e-9, "top-left x")
            }

            TestKit.test("stays the identity above the reference angle") {
                let c = FoldGeometry.textureCorners(lidAngle: 130)
                TestKit.expectEqual(c[2].y, 1, accuracy: 1e-9, "no effect leaning back")
                TestKit.expectEqual(c[2].x, 1, accuracy: 1e-9, "no widening leaning back")
            }

            // The hinge never leaves the plane the desktop is pinned to.
            TestKit.test("bottom edge is always one to one") {
                for angle in [90.0, 75.0, 60.0, 40.0, 20.0, 5.0] {
                    let c = FoldGeometry.textureCorners(lidAngle: angle)
                    TestKit.expectEqual(c[0].x, 0, accuracy: 1e-9, "bottom-left x at \(angle)")
                    TestKit.expectEqual(c[0].y, 0, accuracy: 1e-9, "bottom-left y at \(angle)")
                    TestKit.expectEqual(c[1].x, 1, accuracy: 1e-9, "bottom-right x at \(angle)")
                    TestKit.expectEqual(c[1].y, 0, accuracy: 1e-9, "bottom-right y at \(angle)")
                }
            }

            // Rays through the top of the panel reach past the sides of the
            // desktop, so the screen is wider than the picture up there.
            TestKit.test("screen sees past the sides at the top") {
                for angle in [75.0, 60.0, 40.0] {
                    let c = FoldGeometry.textureCorners(lidAngle: angle)
                    TestKit.expectTrue(c[2].x > 1, "top-right looks past the edge at \(angle)")
                    TestKit.expectTrue(c[3].x < 0, "top-left looks past the edge at \(angle)")
                }
            }

            // And those rays land above the desktop, so it is cut from the top.
            TestKit.test("crops from the top as it closes") {
                let at60 = min(FoldGeometry.textureCorners(lidAngle: 60)[2].y, 1)
                let at40 = min(FoldGeometry.textureCorners(lidAngle: 40)[2].y, 1)
                let at20 = min(FoldGeometry.textureCorners(lidAngle: 20)[2].y, 1)
                TestKit.expectTrue(at60 < 1, "some of the top is gone by 60 degrees")
                TestKit.expectTrue(at40 < at60, "more cropped at 40 than 60")
                TestKit.expectTrue(at20 < at40, "more cropped at 20 than 40")
            }

            TestKit.test("narrowing and cropping both increase monotonically") {
                var previousWidth = Double.infinity
                // How much of the desktop's height is still on screen. Above
                // the top corner the screen looks past the picture entirely, so
                // anything beyond 1 is simply "all of it".
                var previousVisible = Double.infinity
                var angle = FoldGeometry.referenceAngle
                while angle >= 5 {
                    let c = FoldGeometry.textureCorners(lidAngle: angle)
                    let visibleWidth = 1.0 / (c[2].x - c[3].x)
                    let visibleHeight = min(c[2].y, 1.0)
                    TestKit.expectTrue(visibleWidth <= previousWidth + 1e-9,
                                       "picture must keep narrowing at \(angle)")
                    TestKit.expectTrue(visibleHeight <= previousVisible + 1e-9,
                                       "crop must keep advancing at \(angle)")
                    previousWidth = visibleWidth
                    previousVisible = visibleHeight
                    angle -= 1
                }
            }


            // ----------------------------------------------------------------
            // Ground truth from the reference video.
            //
            // Five frames of a real lid closing, filmed by a fixed camera, were
            // measured: the void wedges were detected by luma and straight
            // lines fitted to the picture's and the panel's edges. Solving the
            // projected panel height across the frames recovers the camera
            // (2.97 screen heights away, 0.19 above the hinge) and with it the
            // lid angle of each frame.
            //
            // These are the only numbers in the project that come from outside
            // it. If a change to the geometry breaks them, the fold no longer
            // matches the thing it is imitating.
            // ----------------------------------------------------------------

            // Visible width, relative to the near-open frame. The measurement is
            // a ratio of picture width to panel width, so the near-open frame
            // carries the bezel and is the unit the others are quoted against.
            // The eye fitted to the footage: 3.05 screen heights back and 0.21
            // up, which is where the tripod stood. These assertions test the
            // MODEL against the video, so they must use the video's viewpoint —
            // the shipped default is a seated viewer and looks nothing like it.
            let cameraDistance = 3.05, cameraHeight = 0.21
            func cameraCorners(_ angle: Double) -> [(x: Double, y: Double)] {
                FoldGeometry.textureCorners(lidAngle: angle,
                                            eyeDistance: cameraDistance,
                                            eyeHeight: cameraHeight)
            }
            func visibleWidth(_ angle: Double) -> Double {
                let c = cameraCorners(angle)
                return 1.0 / (c[2].x - c[3].x)
            }
            func topCrop(_ angle: Double) -> Double {
                max(0, 1 - cameraCorners(angle)[2].y)
            }

            TestKit.test("width taper matches the reference video") {
                let unit = visibleWidth(85.0)
                let measured: [(angle: Double, width: Double)] = [
                    (85.0, 1.000), (69.3, 0.921), (48.1, 0.806), (31.9, 0.737),
                ]
                for (angle, width) in measured {
                    TestKit.expectEqual(visibleWidth(angle) / unit, width, accuracy: 0.02,
                                        "visible width at \(angle) degrees")
                }
            }

            TestKit.test("top crop matches the reference video") {
                let measured: [(angle: Double, crop: Double)] = [
                    (85.0, 0.00), (69.3, 0.00), (48.1, 0.11), (31.9, 0.35),
                ]
                for (angle, crop) in measured {
                    TestKit.expectEqual(topCrop(angle), crop, accuracy: 0.03,
                                        "top crop at \(angle) degrees")
                }
            }

            // Below the angle at which the viewer lies in the plane of the panel
            // the panel is edge-on and there is nothing left to show. Past it the
            // arithmetic keeps going and turns the picture inside out, so the
            // geometry has to stop there. A shut lid reaches 0 degrees every
            // time, and the eye position is an environment override, so this is
            // reachable in normal use rather than a theoretical corner.
            TestKit.test("mapping never inverts, at any lid angle") {
                var angle = 0.0
                while angle <= 180.0 {
                    let c = FoldGeometry.textureCorners(lidAngle: angle)
                    TestKit.expectTrue(c[2].y >= c[1].y - 1e-9,
                                       "top edge must stay above the hinge at \(angle)")
                    TestKit.expectTrue(c[2].x > c[3].x,
                                       "picture must keep a positive width at \(angle)")
                    angle += 0.5
                }
            }

            // Measured in the reference video: at 30% and 70% across the panel,
            // in every frame, the picture is bright within 6 pixels of the top of
            // the glass. There is never a black band above it.
            //
            // Pure ray projection does predict one — just after the effect
            // starts, the top of the panel is tipped far enough forward that the
            // sight line clears the top of the desktop, with nothing beyond it.
            // The footage does not do that, and neither should this: the picture
            // stays in contact with the top edge until the crop reaches it.
            TestKit.test("picture always reaches the top edge of the panel") {
                var angle = 0.0
                while angle <= 180.0 {
                    let c = FoldGeometry.textureCorners(lidAngle: angle)
                    TestKit.expectLessThanOrEqual(c[2].y, 1.0,
                                                  "top-right must not look above the desktop at \(angle)")
                    TestKit.expectLessThanOrEqual(c[3].y, 1.0,
                                                  "top-left must not look above the desktop at \(angle)")
                    angle += 0.5
                }
            }

            // The height rule, stated directly.
            //
            // A panel of height h tipped to theta stands h*sin(theta) tall. An
            // upright snapshot is therefore covered up to exactly sin(theta) of
            // its height and no further, so that is the fraction shown: half the
            // picture at 30 degrees. Nothing else needs to happen to it.
            //
            // This is what bounds the stretch. Filling the panel with sin(theta)
            // of the picture costs 1/sin(theta) of vertical magnification, which
            // the panel's own foreshortening gives straight back — 1.4x at 45
            // degrees, 2x at 30. The previous version assumed a fixed seated eye
            // and needed 5x at 45, which looked exactly as bad as it sounds.
            TestKit.test("the height rule is exact with the eye at the top edge") {
                for angle in [90.0, 75.0, 60.0, 45.0, 30.0] {
                    let radians = angle * .pi / 180
                    let c = FoldGeometry.textureCorners(lidAngle: angle,
                                                        eyeDistance: FoldGeometry.eyeDistance,
                                                        eyeHeight: sin(radians))
                    TestKit.expectEqual(c[2].y, sin(radians), accuracy: 1e-9,
                                        "visible height at \(angle) degrees")
                }
            }

            // The reference video crops less than the pure rule: 35% at 32
            // degrees where sin(theta) would take 47%. SLANT_EYE_LEVEL is the
            // dial between them — 1 is the rule, and the footage measures 0.37.
            TestKit.test("eye level dials between the video and the height rule") {
                let radians = 31.9 * .pi / 180
                func crop(_ level: Double) -> Double {
                    let c = FoldGeometry.textureCorners(
                        lidAngle: 31.9,
                        eyeDistance: 2.9,          // the video's own camera
                        eyeHeight: level * sin(radians))
                    return max(0, 1 - c[2].y)
                }
                TestKit.expectEqual(crop(1.0), 1 - sin(radians), accuracy: 1e-9, "the rule")
                TestKit.expectEqual(crop(0.37), 0.35, accuracy: 0.02, "the video")
                TestKit.expectTrue(crop(0.37) < crop(1.0), "the video crops less")
            }

            TestKit.test("no geometry at all before the onset, when easing is on") {
                setenv("SLANT_ONSET_EASE", "1", 1)
                defer { unsetenv("SLANT_ONSET_EASE") }
                for angle in [90.0, 85.0, 80.0, 76.0, 75.0] {
                    let c = FoldGeometry.pinnedCorners(lidAngle: angle, progress: 0)
                    TestKit.expectEqual(c[0].x, 0, accuracy: 1e-9, "bottom-left x at \(angle)")
                    TestKit.expectEqual(c[1].x, 1, accuracy: 1e-9, "bottom-right x at \(angle)")
                    TestKit.expectEqual(c[2].x, 1, accuracy: 1e-9, "top-right x at \(angle)")
                    TestKit.expectEqual(c[2].y, 1, accuracy: 1e-9, "top-right y at \(angle)")
                    TestKit.expectEqual(c[3].x, 0, accuracy: 1e-9, "top-left x at \(angle)")
                }
            }

            // Easing changes only where the fold starts, never where it ends.
            TestKit.test("easing leaves full fold untouched") {
                for angle in [60.0, 45.0, 30.0] {
                    let raw = FoldGeometry.pinnedCorners(lidAngle: angle, progress: 1)
                    setenv("SLANT_ONSET_EASE", "1", 1)
                    let eased = FoldGeometry.pinnedCorners(lidAngle: angle, progress: 1)
                    unsetenv("SLANT_ONSET_EASE")
                    TestKit.expectEqual(eased[2].y, raw[2].y, accuracy: 1e-9,
                                        "full-fold height at \(angle) degrees")
                }
            }

            TestKit.test("the blend only ever advances the crop") {
                setenv("SLANT_ONSET_EASE", "1", 1)
                defer { unsetenv("SLANT_ONSET_EASE") }
                var previous = 1.01
                for step in 0...20 {
                    let p = Double(step) / 20
                    let top = FoldGeometry.pinnedCorners(lidAngle: 45, progress: p)[2].y
                    TestKit.expectTrue(top <= previous + 1e-9,
                                       "crop went backwards at progress \(p)")
                    previous = top
                }
            }

            // ----------------------------------------------------------------
            // The warp model, from noveum/hinge (MIT), Fold.metal:34-36:
            //
            //     float taper = p.taper * p.progress;
            //     float q = (1.0 + taper) / (1.0 + taper * in.uv.y);
            //     float2 uv = float2((in.uv.x - 0.5) * q + 0.5, in.uv.y * q);
            //
            // with taper 0.30 and uv.y = 0 at the top. Rearranged into our
            // corner convention that is: hinge row identity, top row sampled
            // taper/2 wider on each side, top texture row still exactly 1.
            //
            // It is a homography — u and v are both linear in (x, y, 1) over
            // w = 1 + t*y — so the existing machinery takes it unchanged.
            //
            // No eye position, no trigonometry, and no crop: the whole desktop
            // is always on screen, compressed toward the top. That last part is
            // the handoff's rejected attempt #1, which is the point of keeping
            // both models switchable rather than replacing one with the other.
            // ----------------------------------------------------------------

            TestKit.test("warp keeps the hinge row one to one") {
                for p in [0.25, 0.5, 1.0] {
                    let c = FoldGeometry.warpCorners(progress: p)
                    TestKit.expectEqual(c[0].x, 0, accuracy: 1e-9, "bottom-left x at \(p)")
                    TestKit.expectEqual(c[0].y, 0, accuracy: 1e-9, "bottom-left y at \(p)")
                    TestKit.expectEqual(c[1].x, 1, accuracy: 1e-9, "bottom-right x at \(p)")
                    TestKit.expectEqual(c[1].y, 0, accuracy: 1e-9, "bottom-right y at \(p)")
                }
            }

            // The whole point of the model, and the thing the user rejected
            // once: nothing is ever cut away.
            TestKit.test("warp never crops the desktop") {
                for p in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let c = FoldGeometry.warpCorners(progress: p)
                    TestKit.expectEqual(c[2].y, 1, accuracy: 1e-9, "top-right y at \(p)")
                    TestKit.expectEqual(c[3].y, 1, accuracy: 1e-9, "top-left y at \(p)")
                }
            }

            TestKit.test("warp widens the top by the taper") {
                let taper = FoldGeometry.warpTaper
                let c = FoldGeometry.warpCorners(progress: 1)
                TestKit.expectEqual(c[2].x, 1 + taper / 2, accuracy: 1e-9, "top-right x")
                TestKit.expectEqual(c[3].x, -taper / 2, accuracy: 1e-9, "top-left x")
                // hinge's shipping constant leaves the desktop's top edge at
                // 1/(1+taper) of the panel width: 77% at taper 0.30.
                TestKit.expectEqual(1 / (c[2].x - c[3].x), 1 / (1 + taper), accuracy: 1e-9,
                                    "visible width at the top")
            }

            TestKit.test("warp is the identity before the effect starts") {
                let c = FoldGeometry.warpCorners(progress: 0)
                TestKit.expectEqual(c[2].x, 1, accuracy: 1e-9, "top-right x")
                TestKit.expectEqual(c[3].x, 0, accuracy: 1e-9, "top-left x")
            }

            TestKit.test("the model is switchable without a rebuild") {
                TestKit.expectEqual(FoldGeometry.model, .pinned, "default model")
                setenv("SLANT_MODEL", "warp", 1)
                let dispatched = FoldGeometry.textureCorners(lidAngle: 45, progress: 1)
                unsetenv("SLANT_MODEL")
                let warp = FoldGeometry.warpCorners(progress: 1)
                TestKit.expectEqual(dispatched[2].y, warp[2].y, accuracy: 1e-9, "switches to warp")
            }

            // The shipping defaults, against the reference video itself.
            //
            // 24 frames of the closing phase were measured. Two quantities come
            // straight off the pixels with no model in between: how far the
            // panel's top edge splays, and how much of the picture the panel has
            // stopped covering. The angle is not measured — it is recovered from
            // the splay through the shipped eye distance — so this pins the pair
            // (eyeDistance, eyeLevel) together rather than either alone.
            //
            // An earlier version of this test carried crop figures eyeballed
            // from five stills (11% at 48 degrees, 35% at 32). The frame-accurate
            // measurement overturned them: the crop is 1 - sin(theta), which is
            // exactly eyeLevel 1 — the rule the user gave in the first place.
            // The shipped eye distance is 3.8, deliberately gentler than the
            // 2.9 the footage fits, because the taper at 2.9 read as triangular
            // from where the user actually sits. So this evaluates the model at
            // the video's own distance: it holds the MODEL to the footage while
            // leaving the taper free to be chosen.
            TestKit.test("the model reproduces the reference video") {
                let videoDistance = 2.9
                let measured: [(splay: Double, crop: Double)] = [
                    (1.162, 0.103),
                    (1.212, 0.145),
                    (1.243, 0.183),
                ]
                for (splay, crop) in measured {
                    let cosine = videoDistance * (1 - 1 / splay)
                    let angle = acos(min(max(cosine, -1), 1)) * 180 / .pi
                    let c = FoldGeometry.textureCorners(
                        lidAngle: angle,
                        eyeDistance: videoDistance,
                        eyeHeight: FoldGeometry.eyeLevel * sin(angle * .pi / 180))
                    TestKit.expectEqual(max(0, 1 - c[2].y), crop, accuracy: 0.025,
                                        "crop at splay \(splay) (angle \(angle))")
                    // and the taper that recovered the angle must come back out
                    TestKit.expectEqual(1.0 / (c[2].x - c[3].x), 1 / splay, accuracy: 0.005,
                                        "taper at splay \(splay)")
                }
            }

            // The flat model: no reprojection at all.
            //
            // The desktop is left exactly where it is, one texel to one pixel,
            // and the panel simply stops showing the part above sin(theta) of
            // its height. Nothing is magnified, so nothing can look stretched —
            // at the cost that the picture is then glued to the glass and
            // foreshortens with it, rather than standing still in the room.
            TestKit.test("flat leaves the desktop untouched") {
                for angle in [90.0, 60.0, 45.0, 30.0] {
                    let c = FoldGeometry.flatCorners()
                    TestKit.expectEqual(c[0].x, 0, accuracy: 1e-9, "bottom-left x at \(angle)")
                    TestKit.expectEqual(c[1].x, 1, accuracy: 1e-9, "bottom-right x at \(angle)")
                    TestKit.expectEqual(c[2].x, 1, accuracy: 1e-9, "top-right x at \(angle)")
                    TestKit.expectEqual(c[2].y, 1, accuracy: 1e-9, "top-right y at \(angle)")
                    TestKit.expectEqual(c[3].y, 1, accuracy: 1e-9, "top-left y at \(angle)")
                }
            }

            TestKit.test("flat shows sin of the lid angle and hides the rest") {
                for angle in [90.0, 75.0, 60.0, 45.0, 30.0] {
                    TestKit.expectEqual(FoldGeometry.visibleHeight(lidAngle: angle, model: .flat),
                                        sin(angle * .pi / 180), accuracy: 1e-9,
                                        "visible height at \(angle) degrees")
                }
            }

            TestKit.test("the other models show the whole picture height") {
                for model in [FoldGeometry.Model.pinned, .warp] {
                    TestKit.expectEqual(FoldGeometry.visibleHeight(lidAngle: 40, model: model),
                                        1, accuracy: 1e-9, "\(model) hides nothing")
                }
            }

            // Past full fold the effect is finished by definition, but the
            // geometry was still following the lid all the way to nought — and
            // the magnification it needs runs away down there: 2.9x at 20
            // degrees, 5.8x at 10, 11.5x at 5. Every lid shuts through that
            // range, so every close ended in a smear nobody asked for.
            TestKit.test("the geometry holds still below full fold") {
                let atFull = FoldGeometry.textureCorners(lidAngle: FoldProgress.fullFoldAngle,
                                                         progress: 1)
                for angle in [FoldProgress.fullFoldAngle - 1, 20.0, 10.0, 5.0, 0.0] {
                    let c = FoldGeometry.textureCorners(lidAngle: angle, progress: 1)
                    TestKit.expectEqual(c[2].y, atFull[2].y, accuracy: 1e-9,
                                        "height at \(angle) degrees")
                    TestKit.expectEqual(c[2].x, atFull[2].x, accuracy: 1e-9,
                                        "width at \(angle) degrees")
                }
            }

            TestKit.test("stays symmetric about the centre") {
                let c = FoldGeometry.textureCorners(lidAngle: 50)
                TestKit.expectEqual(c[2].x - 0.5, 0.5 - c[3].x, accuracy: 1e-9, "symmetry")
                TestKit.expectEqual(c[2].y, c[3].y, accuracy: 1e-9, "top edge level")
            }
        }
    }
}
