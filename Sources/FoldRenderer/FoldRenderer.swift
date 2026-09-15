import Foundation
import Metal
import MetalPerformanceShaders
import QuartzCore
import simd
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders the folded desktop.
///
/// Perspective comes from an inverse homography evaluated per pixel; blur comes
/// from sampling a Gaussian mip pyramid at a continuous level, so there is no
/// separate blur pass at all. Approach from sumimakito's Mac-Duo. See NOTICE.
public final class FoldRenderer {

    struct Uniforms {
        var screenToTexture: simd_float3x3
        var progress: Float
        var maxMipLevel: Float
        var maxBlurRadius: Float
        var maxDim: Float
        var blurCurve: Float
        var dimCurve: Float
        var blurSpread: Float
        var dimSpread: Float
        var hingeBlurFloor: Float
        var hingeDimFloor: Float
        var flipTexture: Float
        var flipOutput: Float
        var voidColour: SIMD4<Float>
        var vignette: Float
        var reduceMotion: Float
        var rimShare: Float
        var visibleHeight: Float
    }

    /// Blur radius at full fold, in source pixels.
    ///
    /// Mac-Duo ships 135 and the Duo reverse-engineering quotes 72, but both
    /// pair large radii with gentler ramps. With the corrected pacing below the
    /// picture stays legible, so this sits between our over-cautious 9 and
    /// their very soft look.
    public static var maximumBlurRadius: Float {
        Float(FoldGeometry.tunable("SLANT_BLUR", default: 90))
    }
    /// How dark the panel goes at full fold. Override with SLANT_DIM.
    public static var maximumDim: Float {
        Float(FoldGeometry.tunable("SLANT_DIM", default: 0.5))
    }

    /// Blur and dim ramp on separate curves rather than moving in lockstep.
    /// Mac-Duo uses 1.6 and 0.7 for exactly this: darkening arrives early and
    /// blur builds late, which stops the two reading as one flat filter.
    public static var blurCurve: Float {
        Float(FoldGeometry.tunable("SLANT_BLUR_CURVE", default: 0.5))
    }
    public static var dimCurve: Float {
        Float(FoldGeometry.tunable("SLANT_DIM_CURVE", default: 0.7))
    }

    /// How sharply blur and dim concentrate away from the hinge.
    public static var blurSpread: Float {
        Float(FoldGeometry.tunable("SLANT_BLUR_SPREAD", default: 2.2))
    }
    public static var dimSpread: Float {
        Float(FoldGeometry.tunable("SLANT_DIM_SPREAD", default: 1.1))
    }

    /// How much blur and dim survive at the hinge edge. These floors are what
    /// keep the picture intact at the crease.
    public static var hingeBlurFloor: Float {
        Float(FoldGeometry.tunable("SLANT_HINGE_BLUR", default: 0.02))
    }
    public static var hingeDimFloor: Float {
        Float(FoldGeometry.tunable("SLANT_HINGE_DIM", default: 0.10))
    }

    /// Orientation toggles, resolved empirically on device.
    public static var flipTexture: Float {
        Float(FoldGeometry.tunable("SLANT_FLIP_TEX", default: 1))
    }
    public static var flipOutput: Float {
        Float(FoldGeometry.tunable("SLANT_FLIP_OUT", default: 0))
    }
    /// Brightness of the void behind the panel. 0 is black.
    public static var voidBrightness: Float {
        Float(FoldGeometry.tunable("SLANT_VOID", default: 0))
    }
    /// Corner falloff at full fold.
    public static var vignette: Float {
        Float(FoldGeometry.tunable("SLANT_VIGNETTE", default: 0.18))
    }

    /// Width of the soft rim along the exposed sides, as a share of the wedge
    /// beside it. Measured at 0.18 across the reference video.
    public static var rimShare: Float {
        Float(FoldGeometry.tunable("SLANT_RIM", default: 0))
    }

    /// Honour the system Reduce Motion setting: fade instead of folding.
    /// MacDuo is the only competitor that does this.
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let layer: CAMetalLayer
    private let pipeline: MTLRenderPipelineState
    private let pyramid: MPSImageGaussianPyramid

    private var mip: MTLTexture?
    /// The pyramid only needs rebuilding when the source picture changes.
    /// During a fold it never does, so this skips a blit and a full pyramid
    /// pass on every one of the ~60 frames a fold takes.
    ///
    /// Keyed on a caller-supplied generation number, NOT on the texture's
    /// object identity: CVMetalTextureCache recycles MTLTexture objects, so a
    /// brand new frame can arrive wearing the identity of an old one. Keying on
    /// identity meant a changed desktop could be skipped entirely and the fold
    /// would show a stale picture.
    private var pyramidGeneration: UInt64 = .max

    public init?(device: MTLDevice, layer: CAMetalLayer) {
        guard let queue = device.makeCommandQueue() else { return nil }

        // Xcode is not required: the Metal framework compiles the shader at
        // runtime from source shipped as a bundle resource.
        let library: MTLLibrary
        do {
            guard let url = Bundle.module.url(forResource: "Fold", withExtension: "metal") else {
                NSLog("Slant: Fold.metal missing from bundle")
                return nil
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            NSLog("Slant: could not compile Metal library: \(error)")
            return nil
        }

        guard let vertexFunction = library.makeFunction(name: "foldVertex"),
              let fragmentFunction = library.makeFunction(name: "foldFragment")
        else {
            NSLog("Slant: shader functions missing")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            NSLog("Slant: could not build render pipeline")
            return nil
        }

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        self.device = device
        self.layer = layer
        self.commandQueue = queue
        self.pipeline = state
        self.pyramid = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
        // MPS defaults to an edge mode of .zero, so samples falling outside the
        // texture read as black. At a 90 pixel radius that bleeds a dark band
        // into the picture's own left and right edges — unevenly, because the
        // pyramid's odd mip dimensions round the two sides differently, which is
        // why it showed up as a dark patch down one side only. Clamping repeats
        // the edge texel instead, so a uniform picture stays uniform.
        self.pyramid.edgeMode = .clamp
    }

    // MARK: - Live path

    @discardableResult
    public func render(texture: MTLTexture, lidAngle: Double,
                       progress: Double, generation: UInt64) -> Bool {
        guard let drawable = layer.nextDrawable() else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        buildPyramid(into: commandBuffer, from: texture, generation: generation)
        encodeFold(into: commandBuffer, target: drawable.texture,
                   lidAngle: lidAngle, progress: progress,
                   clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    // MARK: - Shared encoding

    func buildPyramid(into commandBuffer: MTLCommandBuffer, from texture: MTLTexture,
                      generation: UInt64) {
        let pyramidTexture = mipTexture(matching: texture)
        guard pyramidGeneration != generation else { return }
        pyramidGeneration = generation

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: texture,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: min(texture.width, pyramidTexture.width),
                                          height: min(texture.height, pyramidTexture.height),
                                          depth: 1),
                      to: pyramidTexture,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        var inPlace: MTLTexture = pyramidTexture
        pyramid.encode(commandBuffer: commandBuffer, inPlaceTexture: &inPlace,
                       fallbackCopyAllocator: nil)
    }

    func encodeFold(into commandBuffer: MTLCommandBuffer, target: MTLTexture,
                    lidAngle: Double, progress: Double, clear: MTLClearColor,
                    voidColour: SIMD4<Float> = SIMD4(FoldRenderer.voidBrightness,
                                                     FoldRenderer.voidBrightness,
                                                     FoldRenderer.voidBrightness, 1)) {
        guard let source = mip else { return }

        // Screen corners -> where each one looks onto the pinned desktop.
        let corners = FoldGeometry.textureCorners(lidAngle: lidAngle, progress: progress)
        let columns = Homography.squareToQuad(corners).floatColumns
        var uniforms = Uniforms(
            screenToTexture: simd_float3x3(
                SIMD3(columns[0], columns[1], columns[2]),
                SIMD3(columns[3], columns[4], columns[5]),
                SIMD3(columns[6], columns[7], columns[8])
            ),
            progress: Float(progress),
            maxMipLevel: Float(max(source.mipmapLevelCount - 1, 0)),
            maxBlurRadius: Self.maximumBlurRadius,
            maxDim: Self.maximumDim,
            blurCurve: Self.blurCurve,
            dimCurve: Self.dimCurve,
            blurSpread: Self.blurSpread,
            dimSpread: Self.dimSpread,
            hingeBlurFloor: Self.hingeBlurFloor,
            hingeDimFloor: Self.hingeDimFloor,
            flipTexture: Self.flipTexture,
            flipOutput: Self.flipOutput,
            voidColour: voidColour,
            vignette: Self.vignette * Float(progress),
            reduceMotion: Self.reduceMotion ? 1 : 0,
            rimShare: Self.rimShare,
            visibleHeight: Float(FoldGeometry.visibleHeight(lidAngle: lidAngle,
                                                            model: FoldGeometry.model))
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clear

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func mipTexture(matching source: MTLTexture) -> MTLTexture {
        if let existing = mip,
           existing.width == source.width, existing.height == source.height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let created = device.makeTexture(descriptor: descriptor)!
        mip = created
        pyramidGeneration = .max
        return created
    }

    // MARK: - Diagnostics

    /// Renders one frame offscreen and returns it as an image.
    ///
    /// A drawable is `framebufferOnly` and cannot be read back, so this renders
    /// through the same encoding path into a readable texture. Areas outside the
    /// folded panel come out magenta, making the panel's extent and orientation
    /// unmistakable.
    public func renderToImage(texture: MTLTexture, lidAngle: Double, progress: Double,
                              width: Int, height: Int) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // Always rebuild for a diagnostic dump.
        pyramidGeneration = .max
        buildPyramid(into: commandBuffer, from: texture, generation: 0)
        encodeFold(into: commandBuffer, target: target,
                   lidAngle: lidAngle, progress: progress,
                   clear: MTLClearColor(red: 1, green: 0, blue: 1, alpha: 1),
                   voidColour: SIMD4(1, 0, 1, 1))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        target.getBytes(&bytes, bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    /// Writes a set of fold stages to PNG files for inspection.
    public func dumpStages(texture: MTLTexture, to directory: String) -> [String] {
        let width = min(texture.width, 1400)
        let height = max(1, Int(Double(width) * Double(texture.height) / Double(texture.width)))
        var written: [String] = []
        // Spread over the fold's travel, 75 down to 30 degrees.
        for angle in [85.0, 70.0, 55.0, 45.0, 30.0] {
            let progress = FoldProgressBridge.progress(forLidAngle: angle)
            guard let image = renderToImage(texture: texture, lidAngle: angle,
                                            progress: progress,
                                            width: width, height: height) else { continue }
            let path = "\(directory)/slant-\(Int(angle))deg.png"
            guard let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL,
                UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { written.append(path) }
        }
        return written
    }
}
