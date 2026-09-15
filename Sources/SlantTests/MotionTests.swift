import TestKit
import FoldRenderer
import LidMotion

enum StillnessTests {
    static func run() {
        TestKit.suite("LidStillness") {

            TestKit.test("seeds at the given angle") {
                TestKit.expectEqual(LidStillness(seed: 100).anchor, 100, accuracy: 0)
            }

            TestKit.test("anchor moves after a long settled dwell") {
                var stillness = LidStillness(seed: 100)
                for _ in 0..<360 { stillness.update(angle: 125, dt: 1.0 / 60.0) } // 6s
                TestKit.expectEqual(stillness.anchor, 125, accuracy: 0.001)
            }

            // The real failure seen on device: pausing briefly part-way through
            // a close made the calibrator adopt that angle as "open", after
            // which the effect stopped triggering above it.
            TestKit.test("a brief pause mid-close does not become the new open angle") {
                var stillness = LidStillness(seed: 106)
                for _ in 0..<60 { stillness.update(angle: 94, dt: 1.0 / 60.0) } // 1s pause
                TestKit.expectEqual(stillness.anchor, 106, accuracy: 0.001)
            }

            TestKit.test("a two second pause is still not enough") {
                var stillness = LidStillness(seed: 106)
                for _ in 0..<120 { stillness.update(angle: 94, dt: 1.0 / 60.0) } // 2s
                TestKit.expectEqual(stillness.anchor, 106, accuracy: 0.001)
            }

            // Nobody rests a lid at 30 degrees; adopting it would disable the
            // effect for the whole usable range.
            TestKit.test("never anchors below the resting floor") {
                var stillness = LidStillness(seed: 106)
                for _ in 0..<600 { stillness.update(angle: 30, dt: 1.0 / 60.0) } // 10s
                TestKit.expectEqual(stillness.anchor, 106, accuracy: 0.001)
            }

            TestKit.test("anchor ignores brief excursions") {
                var stillness = LidStillness(seed: 100)
                for _ in 0..<12 { stillness.update(angle: 40, dt: 1.0 / 60.0) }
                TestKit.expectEqual(stillness.anchor, 100, accuracy: 0.001)
            }

            TestKit.test("anchor ignores sub-threshold jitter") {
                var stillness = LidStillness(seed: 100)
                for i in 0..<600 {
                    stillness.update(angle: 100 + (i % 2 == 0 ? 0.8 : -0.8), dt: 1.0 / 60.0)
                }
                TestKit.expectEqual(stillness.anchor, 100, accuracy: 1.0)
            }

            TestKit.test("a genuinely new resting position is eventually adopted") {
                var stillness = LidStillness(seed: 106)
                for _ in 0..<600 { stillness.update(angle: 90, dt: 1.0 / 60.0) } // 10s settled
                TestKit.expectEqual(stillness.anchor, 90, accuracy: 0.001)
            }
        }
    }
}

enum FoldProgressTests {
    static func run() {
        TestKit.suite("FoldProgress") {

            // A dead zone: small lid adjustments while working must do nothing.
            // Every competitor gates activation; Slant previously started the
            // instant the angle dropped below the resting angle, which is what
            // made it feel twitchy.
            TestKit.test("resting angle produces nothing") {
                TestKit.expectEqual(FoldProgress.progress(angle: 114, openAngle: 114), 0, accuracy: 0.0001)
            }

            TestKit.test("small adjustments inside the dead zone produce nothing") {
                for angle in [113.5, 111.0, 105.0, 98.0] {
                    TestKit.expectEqual(FoldProgress.progress(angle: angle, openAngle: 114), 0,
                                        accuracy: 0.0001, "at \(angle) degrees")
                }
            }

            TestKit.test("effect begins only past the onset angle") {
                // With a 114 resting angle the onset is the 88 degree ceiling,
                // not 114 minus the dead zone.
                TestKit.expectEqual(FoldProgress.startAngle(openAngle: 114), 88, accuracy: 0.001)
                TestKit.expectEqual(FoldProgress.progress(angle: 89, openAngle: 114), 0,
                                    accuracy: 0.0001, "above the onset")
                TestKit.expectTrue(FoldProgress.progress(angle: 85, openAngle: 114) > 0,
                                   "past the onset the effect starts")
            }

            // Pacing is chosen, not measured — and it can no longer be taken
            // from the reference video. That footage was shot from a tripod
            // four centimetres above the hinge, and its fold ran usefully down
            // to 32 degrees because a low eye keeps the picture alive that far.
            // A seated viewer's panel is edge-on at 36, so the effect has to be
            // finished by 55. The video still pins the geometry (see
            // FoldGeometryTests, which evaluates it at the tripod's viewpoint);
            // it cannot pin the pacing.
            TestKit.test("pacing runs from the onset to full fold") {
                let expected: [(angle: Double, progress: Double)] = [
                    (89.0, 0.000),
                    (88.0, 0.000),
                    (73.5, 0.156),
                    (59.0, 0.500),
                    (44.5, 0.844),
                    (30.0, 1.000),
                    (20.0, 1.000),
                ]
                for (angle, want) in expected {
                    TestKit.expectEqual(FoldProgress.progress(angle: angle, openAngle: 114),
                                        want, accuracy: 0.01, "progress at \(angle) degrees")
                }
            }

            // How far the fold may go is bounded by the vertical magnification
            // it needs, not by an angle picked by taste. With the eye tracking
            // the top edge that magnification is 1/(sin(theta)*(1 - cos(theta)/d)),
            // which grows without limit only as the lid shuts: 2.8x at 30
            // degrees. This invariant was silently violated twice — once at 22
            // degrees against an 18 degree horizon, once at 45 degrees needing
            // 5x, which the user described as pathetic and was right to.
            TestKit.test("pre-distortion at full fold stays modest") {
                let angle = FoldProgress.fullFoldAngle
                let atFull = FoldGeometry.preDistortion(
                    lidAngle: angle,
                    eyeDistance: FoldGeometry.eyeDistance,
                    eyeHeight: FoldGeometry.eyeHeight(lidAngle: angle))
                TestKit.expectTrue(atFull <= 3.0,
                                   "full fold at \(angle) needs \(atFull)x pre-distortion")
            }

            TestKit.test("fully closed is one") {
                TestKit.expectEqual(FoldProgress.progress(angle: 5, openAngle: 114), 1, accuracy: 0.0001)
                TestKit.expectEqual(FoldProgress.progress(angle: 0, openAngle: 114), 1, accuracy: 0.0001)
            }

            TestKit.test("reaches full fold at the full-fold angle") {
                TestKit.expectEqual(FoldProgress.progress(angle: FoldProgress.fullFoldAngle,
                                                          openAngle: 114), 1, accuracy: 0.0001)
            }

            // Smoothstep: no abrupt onset at either end, which is what makes
            // the motion read as physical rather than mechanical.
            TestKit.test("eases in rather than starting abruptly") {
                let start = FoldProgress.startAngle(openAngle: 114)
                let justPast = FoldProgress.progress(angle: start - 1, openAngle: 114)
                TestKit.expectTrue(justPast < 0.05, "onset must be gentle, got \(justPast)")
            }

            TestKit.test("eases out rather than slamming into full") {
                let nearlyShut = FoldProgress.progress(angle: FoldProgress.fullFoldAngle + 1,
                                                       openAngle: 114)
                TestKit.expectTrue(nearlyShut > 0.95, "should be nearly complete, got \(nearlyShut)")
            }

            TestKit.test("is monotonic as the lid closes") {
                var previous = -1.0
                var angle = 120.0
                while angle >= 0 {
                    let p = FoldProgress.progress(angle: angle, openAngle: 114)
                    TestKit.expectTrue(p >= previous, "must never go backwards at \(angle)")
                    previous = p
                    angle -= 1
                }
            }

            TestKit.test("midpoint of the travel is near half folded") {
                let start = FoldProgress.startAngle(openAngle: 114)
                let middle = (start + FoldProgress.fullFoldAngle) / 2
                let p = FoldProgress.progress(angle: middle, openAngle: 114)
                TestKit.expectEqual(p, 0.5, accuracy: 0.02, "smoothstep midpoint")
            }

            // A relative dead zone alone starts the effect very high for
            // someone who rests their lid at 125 degrees. Every competitor gates
            // on roughly 90, so cap how high the onset can ever be.
            TestKit.test("never starts above the absolute ceiling") {
                for resting in [120.0, 125.0, 130.0, 140.0] {
                    let start = FoldProgress.startAngle(openAngle: resting)
                    TestKit.expectLessThanOrEqual(start, FoldProgress.highestStartAngle + 0.001,
                                                  "resting at \(resting)")
                }
            }

            TestKit.test("a high resting lid does nothing until the ceiling") {
                TestKit.expectEqual(FoldProgress.progress(angle: 92, openAngle: 130), 0,
                                    accuracy: 0.0001, "still inside the quiet zone")
                TestKit.expectTrue(FoldProgress.progress(angle: 85, openAngle: 130) > 0,
                                   "past the ceiling it starts")
            }

            // Raising the full-fold angle to clear the horizon exposed this:
            // startAngle was clamped upward to guarantee a minimum span, and
            // with full fold at 55 that floor can land ABOVE where someone rests
            // their lid. The effect is then partly on and stays on, all day,
            // with the lid untouched. Less travel is a worse effect; an effect
            // that never switches off is a broken one.
            TestKit.test("a lid resting anywhere in range is never permanently folded") {
                var resting = 55.0
                while resting <= 130.0 {
                    TestKit.expectEqual(FoldProgress.progress(angle: resting, openAngle: resting),
                                        0, accuracy: 1e-9,
                                        "resting at \(resting) must be fully open")
                    resting += 1
                }
            }

            TestKit.test("a low resting lid still uses the relative dead zone") {
                // Someone working at 80 degrees must not need to reach 95.
                let start = FoldProgress.startAngle(openAngle: 80)
                TestKit.expectEqual(start, 72, accuracy: 0.001, "80 minus the 8 degree dead zone")
            }

            TestKit.test("a low resting angle still leaves usable travel") {
                // Someone who works with the lid at 70 degrees must still get
                // an effect, not a dead zone that swallows the whole range.
                let p = FoldProgress.progress(angle: 30, openAngle: 70)
                TestKit.expectTrue(p > 0.3, "expected meaningful fold, got \(p)")
            }
        }
    }
}
