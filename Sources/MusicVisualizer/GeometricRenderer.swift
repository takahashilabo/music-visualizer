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
}

/// Renders a procedurally-generated polar grid (concentric warped rings +
/// radial spokes) entirely in the vertex shader from `vertex_id` — no
/// vertex/particle buffer at all. Bass breathes/warps the rings, mid spins
/// them, treble jitters the spokes, and beats flash the whole thing.
final class GeometricRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let renderPipelineState: MTLRenderPipelineState

    private var uniforms = AudioUniforms()
    private var lastTime: CFTimeInterval = CACurrentMediaTime()

    private static let ringCount = 12
    private static let ringSegments = 56
    private static let spokeCount = 28
    private static let vertsPerSegment = 6
    private static let totalVertexCount =
        (ringCount * ringSegments + spokeCount) * vertsPerSegment

    let analyzer: AudioAnalyzer

    init?(mtkView: MTKView, analyzer: AudioAnalyzer) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.analyzer = analyzer

        guard let queue = device.makeCommandQueue() else { return nil }
        commandQueue = queue

        guard let library = try? device.makeDefaultLibrary(bundle: .module) else {
            print("[GeometricRenderer] could not load Metal library from Bundle.module")
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "geo_vertex"),
              let fragmentFn = library.makeFunction(name: "geo_fragment")
        else {
            print("[GeometricRenderer] missing expected Metal functions in library")
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFn
        pipelineDescriptor.fragmentFunction = fragmentFn
        pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
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

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 0), 1.0 / 15.0))
        lastTime = now

        analyzer.analyze(deltaTime: dt)
        let features = analyzer.features.snapshot()

        uniforms.time = Float(now.truncatingRemainder(dividingBy: 100_000))
        uniforms.deltaTime = dt
        uniforms.bass = features.bass
        uniforms.mid = features.mid
        uniforms.treble = features.treble
        uniforms.loudness = features.loudness
        uniforms.beatPulse = features.beatPulse
        uniforms.viewWidth = Float(view.drawableSize.width)
        uniforms.viewHeight = Float(view.drawableSize.height)

        guard uniforms.viewWidth > 0, uniforms.viewHeight > 0 else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<AudioUniforms>.stride, index: 1)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Self.totalVertexCount)
        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
