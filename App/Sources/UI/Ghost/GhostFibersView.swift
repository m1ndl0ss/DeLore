import MetalKit
import SwiftUI

/// Native port of React Bits GhostFibers (ogl fullscreen fiber shader).
struct GhostFibersView: UIViewRepresentable {
    var paused = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = true
        view.isPaused = paused
        view.enableSetNeedsDisplay = paused
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0.063, green: 0.043, blue: 0.125, alpha: 1)
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        context.coordinator.setup(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        view.isPaused = paused
        view.enableSetNeedsDisplay = paused
        context.coordinator.paused = paused
        if paused { view.draw() }
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var paused = false
        private var pipeline: MTLRenderPipelineState?
        private var queue: MTLCommandQueue?
        private var start = CACurrentMediaTime()
        private var uniforms = Uniforms()

        func setup(_ view: MTKView) {
            guard let device = view.device,
                  let library = device.makeDefaultLibrary(),
                  let vertex = library.makeFunction(name: "ghost_fibers_vertex"),
                  let fragment = library.makeFunction(name: "ghost_fibers_fragment")
            else { return }
            queue = device.makeCommandQueue()
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex
            desc.fragmentFunction = fragment
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
            uniforms = .deloreDefaults
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            uniforms.resolution = SIMD2(Float(size.width), Float(size.height))
        }

        func draw(in view: MTKView) {
            guard let pipeline,
                  let queue,
                  let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor
            else { return }
            uniforms.resolution = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
            if !paused {
                uniforms.time = Float(CACurrentMediaTime() - start)
            }
            let command = queue.makeCommandBuffer()
            let encoder = command?.makeRenderCommandEncoder(descriptor: pass)
            encoder?.setRenderPipelineState(pipeline)
            encoder?.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder?.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder?.endEncoding()
            command?.present(drawable)
            command?.commit()
        }
    }
}

private struct Uniforms {
    var resolution = SIMD2<Float>(1, 1)
    var time: Float = 0
    var speed: Float = 0.18
    var scale: Float = 1.85
    var rotation: Float = 0
    var rotationSpeed: Float = 0.16
    var layers: Float = 4
    var waveAmplitude: Float = 0.015
    var waveFrequency: Float = 3
    var waveSpeed: Float = 0.15
    var layerSpeed: Float = 0.08
    var twist: Float = 0.1
    var twistFrequency: Float = 5
    var twistSpeed: Float = 1.2
    var lineFrequency: Float = 5
    var lineSpacing: Float = 2
    var lineSharpness: Float = 16
    var glowFalloff: Float = 10
    var glowIntensity: Float = 0.58
    var brightness: Float = 0.82
    var blueBoost: Float = 1.05
    var vignette: Float = 0.9
    var grain: Float = 0.04
    var lightMode: Float = 0
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
    var lineColor = SIMD4<Float>(0.42, 0.34, 0.78, 1)
    var glowColor = SIMD4<Float>(0.16, 0.10, 0.38, 1)

    static let deloreDefaults = Uniforms()
}
