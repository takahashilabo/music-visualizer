import MetalKit
import QuartzCore

struct AudioUniforms {
    var time: Float = 0
    var deltaTime: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var loudness: Float = 0
    var beatPulse: Float = 0
    var viewWidth: Float = 0
    var viewHeight: Float = 0
    var sceneWeightLines: Float = 0
    var sceneWeightParticles: Float = 0
    var sceneWeightBoxes: Float = 0
    var sceneWeightSplines: Float = 0
}

/// Cycles through four distinct procedural "scenes" (lines, particles,
/// boxes, splines) over time, crossfading between the outgoing and
/// incoming scene so the pattern never just sits static — echoing how a
/// Rhizomatiks-style visual set moves between distinct segments rather
/// than running one look forever.
private final class SceneManager {
    private var order: [Int] = SceneManager.freshOrder(avoiding: nil)
    private var pos: Int = 0
    private var timeInScene: Float = 0
    private var sceneDuration: Float = Float.random(in: 9...14)
    private let crossfadeDuration: Float = 1.4

    private var current: Int { order[pos] }
    private var next: Int {
        let nextPos = pos + 1
        if nextPos < order.count { return order[nextPos] }
        return SceneManager.freshOrder(avoiding: order[pos]).first!
    }

    /// Returns (lines, particles, boxes, splines) weights, each in [0, 1].
    func update(dt: Float) -> (Float, Float, Float, Float) {
        timeInScene += dt
        let fadeStart = max(sceneDuration - crossfadeDuration, 0)
        var weights: [Float] = [0, 0, 0, 0]

        if timeInScene >= sceneDuration {
            let upcoming = next
            pos += 1
            if pos >= order.count {
                order = SceneManager.freshOrder(avoiding: order.last)
                pos = 0
            }
            timeInScene = 0
            sceneDuration = Float.random(in: 9...14)
            weights[upcoming] = 1
        } else if timeInScene >= fadeStart {
            let t = (timeInScene - fadeStart) / crossfadeDuration
            let s = t * t * (3 - 2 * t)
            weights[current] = 1 - s
            weights[next] = s
        } else {
            weights[current] = 1
        }
        return (weights[0], weights[1], weights[2], weights[3])
    }

    private static func freshOrder(avoiding last: Int?) -> [Int] {
        var o = [0, 1, 2, 3].shuffled()
        if let last, o.first == last {
            o.swapAt(0, 1)
        }
        return o
    }
}

/// Renders four procedurally-generated scenes — a warped polar grid of
/// rings + spokes, a field of soft particle sparks, a pulsing grid of
/// equalizer-style boxes, and flowing sine ribbons — entirely in the
/// vertex shader from `vertex_id` (no vertex/particle buffer at all), and
/// crossfades between them over time via `SceneManager`. Bass/mid/treble/
/// beat each drive motion, color, and brightness differently per scene.
final class GeometricRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderPipelineState: MTLRenderPipelineState
    private let tonemapPipelineState: MTLRenderPipelineState
    private var hdrTexture: MTLTexture?

    private var uniforms = AudioUniforms()
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private let sceneManager = SceneManager()

    private static let ringCount = 12
    private static let ringSegments = 56
    private static let spokeCount = 28
    private static let vertsPerSegment = 6
    private static let lineVertexCount =
        (ringCount * ringSegments + spokeCount) * vertsPerSegment

    private static let particleCount = 900
    private static let vertsPerQuad = 6
    private static let particleVertexCount = particleCount * vertsPerQuad

    private static let boxCols = 10
    private static let boxRows = 6
    private static let edgesPerBox = 4
    private static let boxVertexCount =
        boxCols * boxRows * edgesPerBox * vertsPerSegment

    private static let splineCount = 10
    private static let splineSamples = 40
    private static let splineVertexCount =
        splineCount * (splineSamples - 1) * vertsPerSegment

    private static let totalVertexCount =
        lineVertexCount + particleVertexCount + boxVertexCount + splineVertexCount

    let analyzer: AudioAnalyzer

    init?(mtkView: MTKView, analyzer: AudioAnalyzer) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        self.analyzer = analyzer

        guard let queue = device.makeCommandQueue() else { return nil }
        commandQueue = queue

        guard let library = try? device.makeDefaultLibrary(bundle: .module) else {
            print("[GeometricRenderer] could not load Metal library from Bundle.module")
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "geo_vertex"),
              let fragmentFn = library.makeFunction(name: "geo_fragment"),
              let fullscreenVertexFn = library.makeFunction(name: "fullscreen_vertex"),
              let tonemapFragmentFn = library.makeFunction(name: "tonemap_fragment")
        else {
            print("[GeometricRenderer] missing expected Metal functions in library")
            return nil
        }

        // Pass 1: render all scene geometry additively into an HDR
        // (floating point) offscreen texture, so overlapping bright lines
        // and sustained-loud passages can accumulate past 1.0 without
        // clipping to flat white.
        let hdrPipelineDescriptor = MTLRenderPipelineDescriptor()
        hdrPipelineDescriptor.vertexFunction = vertexFn
        hdrPipelineDescriptor.fragmentFunction = fragmentFn
        hdrPipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        hdrPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        hdrPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        hdrPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        hdrPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        hdrPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        hdrPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        hdrPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        // Pass 2: a fullscreen triangle that tonemaps the HDR texture down
        // into the view's displayable (8-bit) drawable.
        let tonemapPipelineDescriptor = MTLRenderPipelineDescriptor()
        tonemapPipelineDescriptor.vertexFunction = fullscreenVertexFn
        tonemapPipelineDescriptor.fragmentFunction = tonemapFragmentFn
        tonemapPipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        tonemapPipelineDescriptor.colorAttachments[0].isBlendingEnabled = false

        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: hdrPipelineDescriptor)
            tonemapPipelineState = try device.makeRenderPipelineState(descriptor: tonemapPipelineDescriptor)
        } catch {
            print("[GeometricRenderer] pipeline creation failed: \(error)")
            return nil
        }

        super.init()

        mtkView.device = device
        mtkView.delegate = self
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 30
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.layer?.isOpaque = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func ensureHDRTexture(width: Int, height: Int) -> MTLTexture? {
        if let tex = hdrTexture, tex.width == width, tex.height == height {
            return tex
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        hdrTexture = texture
        return texture
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 0), 1.0 / 15.0))
        lastTime = now

        analyzer.analyze(deltaTime: dt)
        let features = analyzer.features.snapshot()
        let (lines, particles, boxes, splines) = sceneManager.update(dt: dt)

        uniforms.time = Float(now.truncatingRemainder(dividingBy: 100_000))
        uniforms.deltaTime = dt
        uniforms.bass = features.bass
        uniforms.mid = features.mid
        uniforms.treble = features.treble
        uniforms.loudness = features.loudness
        uniforms.beatPulse = features.beatPulse
        uniforms.viewWidth = Float(view.drawableSize.width)
        uniforms.viewHeight = Float(view.drawableSize.height)
        uniforms.sceneWeightLines = lines
        uniforms.sceneWeightParticles = particles
        uniforms.sceneWeightBoxes = boxes
        uniforms.sceneWeightSplines = splines

        guard uniforms.viewWidth > 0, uniforms.viewHeight > 0 else { return }
        guard let hdrTexture = ensureHDRTexture(width: Int(uniforms.viewWidth), height: Int(uniforms.viewHeight))
        else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let viewDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable
        else { return }

        let hdrDescriptor = MTLRenderPassDescriptor()
        hdrDescriptor.colorAttachments[0].texture = hdrTexture
        hdrDescriptor.colorAttachments[0].loadAction = .clear
        hdrDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        hdrDescriptor.colorAttachments[0].storeAction = .store

        if let geoEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: hdrDescriptor) {
            geoEncoder.setRenderPipelineState(renderPipelineState)
            geoEncoder.setVertexBytes(&uniforms, length: MemoryLayout<AudioUniforms>.stride, index: 1)
            geoEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Self.totalVertexCount)
            geoEncoder.endEncoding()
        }

        if let tonemapEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: viewDescriptor) {
            tonemapEncoder.setRenderPipelineState(tonemapPipelineState)
            tonemapEncoder.setFragmentTexture(hdrTexture, index: 0)
            tonemapEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<AudioUniforms>.stride, index: 1)
            tonemapEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            tonemapEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
