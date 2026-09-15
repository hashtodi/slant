import Foundation
import TestKit
import FoldRenderer
import Metal
import QuartzCore

/// Renders through the real shader and checks it against the geometry.
///
/// `FoldGeometryTests` proves the arithmetic matches the reference video, but
/// the arithmetic is only half the fold — the shader has to use it. The two
/// have disagreed before: the projection was computed correctly and then used
/// only as a visibility mask, so the picture stayed glued to the panel and all
/// that moved was a shrinking black aperture.
///
/// `renderToImage` takes any texture, so this drives the whole path headless
/// from a synthetic one: no screen capture, no permission, no install.
enum ShaderTests {
    static func run() {
        TestKit.suite("Shader") {

            guard let device = MTLCreateSystemDefaultDevice() else {
                print("  (no Metal device — shader tests skipped)")
                return
            }
            // This suite checks that the shader uses the geometry it is given.
            // Dim and the corner vignette both darken the picture near its
            // edges, which moves where a brightness threshold finds them — so
            // neutralise them and measure geometry alone. Restored below;
            // ShaderTests runs last, but not by anything that enforces it.
            // Blur belongs off too, and for a more interesting reason: at a 90
            // pixel radius the mip pyramid's edge taps reach past the texture
            // and pull in black, so the picture fades out over roughly 3% of its
            // own width. Mac-Duo relies on exactly that — "the texture already
            // holds the picture on black, so the two blur together and the
            // picture edge needs no special handling" — but it puts the
            // brightness half-crossing well inside the geometric edge, so no
            // threshold can measure geometry while it is on.
            setenv("SLANT_DIM", "0", 1)
            setenv("SLANT_VIGNETTE", "0", 1)
            setenv("SLANT_BLUR", "0", 1)
            defer {
                unsetenv("SLANT_DIM")
                unsetenv("SLANT_VIGNETTE")
                unsetenv("SLANT_BLUR")
            }

            let layer = CAMetalLayer()
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            guard let renderer = FoldRenderer(device: device, layer: layer),
                  let source = whiteTexture(device: device, width: 800, height: 500) else {
                TestKit.expectTrue(false, "could not build the renderer or its source texture")
                return
            }

            let width = 600, height = 375

            // The void is painted magenta by the diagnostic path, so anything
            // with green in it is picture and anything without is void.
            // The edge is feathered across the blur, so a fixed threshold moves
            // with the blur radius and measures the feather rather than the
            // geometry. Half the row's own peak is where coverage crosses 0.5,
            // which is where the geometry actually puts the edge.
            func pictureSpan(_ image: CGImage, row: Int) -> Double? {
                guard let data = image.dataProvider?.data,
                      let bytes = CFDataGetBytePtr(data) else { return nil }
                let stride = image.bytesPerRow
                var peak = 0
                for x in 0..<image.width {
                    peak = max(peak, Int(bytes[row * stride + x * 4 + 1]))
                }
                guard peak > 40 else { return 0 }
                let half = peak / 2
                var first = -1, last = -1
                for x in 0..<image.width where Int(bytes[row * stride + x * 4 + 1]) >= half {
                    if first < 0 { first = x }
                    last = x
                }
                return first < 0 ? 0 : Double(last - first + 1) / Double(image.width)
            }

            // Angles are spaced across the shipped viewpoint's usable range —
            // above full fold, and well clear of the angle at which the panel
            // goes edge-on to the assumed eye, where the picture has nothing
            // left to show and a width reading means nothing.
            //
            // One edge of the panel is the hinge and keeps the picture at full
            // width; the other is the top and narrows to the projected fraction.
            // Which is which depends on the output flip, so compare the pair.
            TestKit.test("rendered width matches the geometry at the reference angles") {
                for angle in [85.0, 60.0, 45.0, 30.0] {
                    let corners = FoldGeometry.textureCorners(
                        lidAngle: angle,
                        progress: FoldProgressBridge.progress(forLidAngle: angle))
                    let expectedNarrow = 1.0 / (corners[2].x - corners[3].x)
                    guard let image = renderer.renderToImage(
                            texture: source, lidAngle: angle,
                            progress: FoldProgressBridge.progress(forLidAngle: angle),
                            width: width, height: height),
                          let near = pictureSpan(image, row: 1),
                          let far = pictureSpan(image, row: height - 2) else {
                        TestKit.expectTrue(false, "no image at \(angle) degrees")
                        continue
                    }
                    TestKit.expectEqual(max(near, far), 1.0, accuracy: 0.02,
                                        "hinge edge stays full width at \(angle) degrees")
                    TestKit.expectEqual(min(near, far), expectedNarrow, accuracy: 0.03,
                                        "top edge narrows as projected at \(angle) degrees")
                }
            }

            // "At the hinge in Duo the image remains intact" — stated twice, and
            // the one thing the blur must not take. It was quietly broken by
            // raising the radius to the field's magnitude while leaving a hinge
            // floor of 0.12: at full fold that put 10.8 source pixels of blur on
            // the crease, which erased fine detail there and turned the whole
            // picture to mush. Mac-Duo runs a far larger radius with a hinge
            // floor of exactly zero.
            TestKit.test("full fold leaves the hinge sharp and blurs the top") {
                setenv("SLANT_BLUR", "90", 1)
                defer { setenv("SLANT_BLUR", "0", 1) }
                guard let checks = checkerTexture(device: device, width: 800, height: 500,
                                                  cell: 8) else {
                    TestKit.expectTrue(false, "could not build the checkerboard")
                    return
                }
                guard let image = renderer.renderToImage(texture: checks, lidAngle: 30,
                                                         progress: 1,
                                                         width: width, height: height) else {
                    TestKit.expectTrue(false, "no image")
                    return
                }
                let near = detail(image, row: height - 6)
                let far = detail(image, row: 6)
                let hinge = max(near, far), top = min(near, far)
                TestKit.expectTrue(hinge > 8,
                                   "the hinge must keep its detail, got \(hinge)")
                TestKit.expectTrue(hinge > 5 * top,
                                   "the top must be far softer than the hinge, "
                                   + "got hinge \(hinge) against top \(top)")
            }

            // The blur must not eat the picture's own edges.
            //
            // MPS image kernels default to an edge mode of .zero: samples that
            // fall outside the texture read as black. A large blur radius near
            // the picture's left or right edge therefore mixes black inward and
            // darkens a band along it — and unevenly, because the pyramid's odd
            // mip dimensions round the two sides differently. On a uniform grey
            // source it measured 50 on the left against 96 on the right, with
            // the centre at 117.
            //
            // The user saw it as "a dark spot on the left edge" and was right.
            TestKit.test("blur does not darken the picture's own edges") {
                setenv("SLANT_BLUR", "90", 1)
                defer { setenv("SLANT_BLUR", "0", 1) }
                guard let flat = uniformTexture(device: device, width: 1440, height: 900,
                                                level: 180),
                      let image = renderer.renderToImage(texture: flat, lidAngle: 45,
                                                         progress: 1,
                                                         width: width, height: height) else {
                    TestKit.expectTrue(false, "no image"); return
                }
                guard let data = image.dataProvider?.data,
                      let bytes = CFDataGetBytePtr(data) else {
                    TestKit.expectTrue(false, "no pixels"); return
                }
                let stride = image.bytesPerRow
                let row = height / 6
                func green(_ x: Int) -> Int { Int(bytes[row * stride + x * 4 + 1]) }
                let lit = (0..<image.width).filter { green($0) > 25 }
                guard let first = lit.first, let last = lit.last, last - first > 80 else {
                    TestKit.expectTrue(false, "no picture on this row"); return
                }
                let inset = 12
                let left = Double(green(first + inset))
                let right = Double(green(last - inset))
                let centre = Double(green((first + last) / 2))
                TestKit.expectTrue(abs(left - right) < 0.10 * centre,
                                   "edges must darken alike: left \(left), right \(right)")
                TestKit.expectTrue(left > 0.70 * centre,
                                   "left edge lost too much to the blur: "
                                   + "\(left) against a centre of \(centre)")
            }

            // Blur has to be under way well before the geometry is obvious.
            //
            // In the reference video the top band has lost almost all its
            // detail (0.04-0.07 of the hinge band's) by about 88 degrees, while
            // the panel has barely begun to splay. Slant held blur at exactly
            // zero until the 75 degree onset, so the first 15 degrees carried a
            // visible crop and taper with a perfectly sharp picture — which is
            // what made it read as a geometric cut rather than a fold.
            TestKit.test("the top is already softening at 80 degrees") {
                setenv("SLANT_BLUR", "90", 1)
                defer { setenv("SLANT_BLUR", "0", 1) }
                guard let checks = checkerTexture(device: device, width: 800, height: 500,
                                                  cell: 8),
                      let image = renderer.renderToImage(
                        texture: checks, lidAngle: 80,
                        progress: FoldProgressBridge.progress(forLidAngle: 80),
                        width: width, height: height) else {
                    TestKit.expectTrue(false, "no image"); return
                }
                let near = detail(image, row: height - 6)
                let far = detail(image, row: 6)
                let hinge = max(near, far), top = min(near, far)
                TestKit.expectTrue(top < 0.6 * hinge,
                                   "at 80 degrees the top should already be softer than "
                                   + "the hinge, got top \(top) against hinge \(hinge)")
            }

            // The optional soft rim along the exposed sides.
            //
            // Chased because the reference video shows a grey band there of
            // exactly 0.18 of the local wedge width, at every deep-fold frame
            // and height. That measurement was real; the explanation was not —
            // it is the aluminium base reflecting in the glossy screen, which is
            // why it scales so cleanly with the wedge. So this now defaults OFF
            // and the test selects it.
            //
            // Kept because if it is ever wanted it must be a function of the
            // geometry, not of the blur radius. Tied to blur, as it first was,
            // turning blur down removed it silently.
            TestKit.test("the side rim scales with the wedge, not the blur") {
                setenv("SLANT_RIM", "0.18", 1)
                defer { unsetenv("SLANT_RIM") }
                guard let image = renderer.renderToImage(texture: source, lidAngle: 30,
                                                         progress: 1,
                                                         width: width, height: height) else {
                    TestKit.expectTrue(false, "no image"); return
                }
                guard let data = image.dataProvider?.data,
                      let bytes = CFDataGetBytePtr(data) else {
                    TestKit.expectTrue(false, "no pixels"); return
                }
                let stride = image.bytesPerRow
                let row = height / 5          // well up the panel, where the wedge is wide
                func green(_ x: Int) -> Int { Int(bytes[row * stride + x * 4 + 1]) }
                var peak = 0
                for x in 0..<image.width { peak = max(peak, green(x)) }
                guard peak > 40 else { TestKit.expectTrue(false, "nothing rendered"); return }
                // wedge: void runs from the panel edge in to where coverage starts
                let lowMark = peak / 10, highMark = peak * 9 / 10
                let rampStart = (0..<image.width).first { green($0) >= lowMark } ?? 0
                let rampEnd = (0..<image.width).first { green($0) >= highMark } ?? 0
                let rim = Double(rampEnd - rampStart)
                let wedge = Double(rampStart) + rim / 2
                TestKit.expectTrue(wedge > 10, "expected a wedge to measure, got \(wedge)")
                TestKit.expectTrue(rim / wedge > 0.10 && rim / wedge < 0.30,
                                   "rim should be about 0.18 of the wedge, got "
                                   + "\(rim / wedge)  (rim \(rim), wedge \(wedge))")
            }

            // The failure this suite exists for: if the shader samples at the
            // pixel's own coordinate instead of where its sight line lands, the
            // rendered width stops depending on the projection entirely.
            TestKit.test("the picture actually narrows as the lid closes") {
                var previous = 2.0
                for angle in [85.0, 60.0, 45.0, 30.0] {
                    guard let image = renderer.renderToImage(
                            texture: source, lidAngle: angle,
                            progress: FoldProgressBridge.progress(forLidAngle: angle),
                            width: width, height: height),
                          let near = pictureSpan(image, row: 1),
                          let far = pictureSpan(image, row: height - 2) else { continue }
                    let narrow = min(near, far)
                    TestKit.expectTrue(narrow < previous - 0.005,
                                       "top must keep narrowing at \(angle) degrees, "
                                       + "got \(narrow) after \(previous)")
                    previous = narrow
                }
            }
        }
    }

    /// Mean absolute neighbour difference along one row: how much fine detail
    /// survived the blur there.
    private static func detail(_ image: CGImage, row: Int) -> Double {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return 0 }
        let stride = image.bytesPerRow
        var total = 0.0, count = 0
        // Skip the outer fifth so the feathered side edges are not counted.
        let from = image.width / 5, upto = image.width * 4 / 5
        for x in from..<(upto - 1) {
            let a = Int(bytes[row * stride + x * 4 + 1])
            let b = Int(bytes[row * stride + (x + 1) * 4 + 1])
            total += Double(abs(a - b))
            count += 1
        }
        return count == 0 ? 0 : total / Double(count)
    }

    private static func checkerTexture(device: MTLDevice, width: Int, height: Int,
                                       cell: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                let value: UInt8 = on ? 255 : 0
                let i = (y * width + x) * 4
                pixels[i] = value; pixels[i+1] = value; pixels[i+2] = value; pixels[i+3] = 255
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }

    private static func uniformTexture(device: MTLDevice, width: Int, height: Int,
                                       level: UInt8) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixels = [UInt8](repeating: level, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }

    private static func whiteTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pixels = [UInt8](repeating: 255, count: width * height * 4)
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: width * 4)
        return texture
    }
}
