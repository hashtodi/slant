import Foundation

/// A 2D projective transform mapping the unit square onto an arbitrary convex
/// quadrilateral (Heckbert's square-to-quad).
///
/// The renderer uses the inverse direction: every output pixel is mapped back
/// into picture space, so the fold needs no geometry subdivision at all. One
/// full-screen triangle and a matrix produce true perspective.
///
/// Approach follows sumimakito's Mac-Duo. See NOTICE.
public struct Homography: Equatable {

    public let a, b, c: Double
    public let d, e, f: Double
    public let g, h: Double
    // The ninth coefficient is fixed at 1.

    /// `corners` are the images of (0,0), (1,0), (1,1), (0,1) in that order.
    public static func squareToQuad(_ corners: [(x: Double, y: Double)]) -> Homography {
        precondition(corners.count == 4, "a quad needs exactly four corners")
        let (x0, y0) = corners[0]
        let (x1, y1) = corners[1]
        let (x2, y2) = corners[2]
        let (x3, y3) = corners[3]

        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3

        if dx3 == 0 && dy3 == 0 {
            // Parallelogram: the transform is affine.
            return Homography(
                a: x1 - x0, b: x2 - x1, c: x0,
                d: y1 - y0, e: y2 - y1, f: y0,
                g: 0, h: 0
            )
        }

        let denominator = dx1 * dy2 - dy1 * dx2
        guard denominator != 0 else {
            // Degenerate quad; identity beats NaNs on screen.
            return Homography(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0, g: 0, h: 0)
        }

        let g = (dx3 * dy2 - dy3 * dx2) / denominator
        let h = (dx1 * dy3 - dy1 * dx3) / denominator

        return Homography(
            a: x1 - x0 + g * x1, b: x3 - x0 + h * x3, c: x0,
            d: y1 - y0 + g * y1, e: y3 - y0 + h * y3, f: y0,
            g: g, h: h
        )
    }

    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        let denominator = g * x + h * y + 1
        guard denominator != 0 else { return (x, y) }
        return ((a * x + b * y + c) / denominator,
                (d * x + e * y + f) / denominator)
    }

    /// Column-major, for upload as a `float3x3`.
    public var floatColumns: [Float] {
        [Float(a), Float(d), Float(g),
         Float(b), Float(e), Float(h),
         Float(c), Float(f), 1]
    }

    /// The inverse transform, column-major, for upload as a `float3x3`.
    ///
    /// The shader maps each output pixel back into picture space, so it needs
    /// quad-to-square, not square-to-quad.
    public var inverseColumns: [Float] {
        let i = 1.0
        let determinant =
            a * (e * i - f * h) -
            b * (d * i - f * g) +
            c * (d * h - e * g)
        guard determinant != 0 else {
            return [1, 0, 0, 0, 1, 0, 0, 0, 1]
        }
        let inv = 1.0 / determinant

        let a2 = (e * i - f * h) * inv
        let b2 = (c * h - b * i) * inv
        let c2 = (b * f - c * e) * inv
        let d2 = (f * g - d * i) * inv
        let e2 = (a * i - c * g) * inv
        let f2 = (c * d - a * f) * inv
        let g2 = (d * h - e * g) * inv
        let h2 = (b * g - a * h) * inv
        let i2 = (a * e - b * d) * inv

        return [Float(a2), Float(d2), Float(g2),
                Float(b2), Float(e2), Float(h2),
                Float(c2), Float(f2), Float(i2)]
    }
}
