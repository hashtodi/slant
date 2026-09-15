import TestKit
import FoldRenderer

enum HomographyTests {
    static let unitSquare: [(x: Double, y: Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]

    static func run() {
        TestKit.suite("Homography") {

            TestKit.test("unit square maps to identity") {
                let h = Homography.squareToQuad(unitSquare)
                TestKit.expectEqual(h.a, 1, accuracy: 1e-9, "a")
                TestKit.expectEqual(h.b, 0, accuracy: 1e-9, "b")
                TestKit.expectEqual(h.c, 0, accuracy: 1e-9, "c")
                TestKit.expectEqual(h.d, 0, accuracy: 1e-9, "d")
                TestKit.expectEqual(h.e, 1, accuracy: 1e-9, "e")
                TestKit.expectEqual(h.f, 0, accuracy: 1e-9, "f")
                TestKit.expectEqual(h.g, 0, accuracy: 1e-9, "g")
                TestKit.expectEqual(h.h, 0, accuracy: 1e-9, "h")
            }

            TestKit.test("translation is affine") {
                let h = Homography.squareToQuad([(2, 3), (3, 3), (3, 4), (2, 4)])
                TestKit.expectEqual(h.c, 2, accuracy: 1e-9, "c")
                TestKit.expectEqual(h.f, 3, accuracy: 1e-9, "f")
                TestKit.expectEqual(h.g, 0, accuracy: 1e-9, "g")
                TestKit.expectEqual(h.h, 0, accuracy: 1e-9, "h")
            }

            // The defining property: the matrix must map the unit square's
            // corners onto the requested quad, in order.
            TestKit.test("projective quad recovers its corners") {
                let quad: [(x: Double, y: Double)] = [(0.1, 0.2), (0.9, 0.05), (0.8, 0.95), (0.25, 0.7)]
                let h = Homography.squareToQuad(quad)
                for (index, source) in unitSquare.enumerated() {
                    let mapped = h.apply(x: source.x, y: source.y)
                    TestKit.expectEqual(mapped.x, quad[index].x, accuracy: 1e-6, "corner \(index) x")
                    TestKit.expectEqual(mapped.y, quad[index].y, accuracy: 1e-6, "corner \(index) y")
                }
            }

            // A trapezoid, which is what a hinge rotation actually produces.
            TestKit.test("trapezoid recovers its corners") {
                let quad: [(x: Double, y: Double)] = [(0, 0), (1, 0), (0.75, 1), (0.25, 1)]
                let h = Homography.squareToQuad(quad)
                for (index, source) in unitSquare.enumerated() {
                    let mapped = h.apply(x: source.x, y: source.y)
                    TestKit.expectEqual(mapped.x, quad[index].x, accuracy: 1e-6, "corner \(index) x")
                    TestKit.expectEqual(mapped.y, quad[index].y, accuracy: 1e-6, "corner \(index) y")
                }
            }

            TestKit.test("float columns is nine values") {
                TestKit.expectEqual(Homography.squareToQuad(unitSquare).floatColumns.count, 9)
            }

            // The renderer needs quad-to-square, so the inverse must undo the forward map.
            TestKit.test("inverse columns undo the forward transform") {
                let quad: [(x: Double, y: Double)] = [(0, 0), (1, 0), (0.75, 0.8), (0.25, 0.8)]
                let h = Homography.squareToQuad(quad)
                let inv = h.inverseColumns   // column-major 3x3
                for source in unitSquare {
                    let fwd = h.apply(x: source.x, y: source.y)
                    // apply the inverse matrix to fwd, expect to land back on source
                    let den = Double(inv[2]) * fwd.x + Double(inv[5]) * fwd.y + Double(inv[8])
                    let bx = (Double(inv[0]) * fwd.x + Double(inv[3]) * fwd.y + Double(inv[6])) / den
                    let by = (Double(inv[1]) * fwd.x + Double(inv[4]) * fwd.y + Double(inv[7])) / den
                    TestKit.expectEqual(bx, source.x, accuracy: 1e-5, "round trip x")
                    TestKit.expectEqual(by, source.y, accuracy: 1e-5, "round trip y")
                }
            }
        }
    }
}
