import MetalKit
import SwiftUI
import UIKit

final class GhostFibersMTKView: MTKView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            contentScaleFactor = window.screen.scale
        }
        isHidden = false
        isOpaque = true
        layer.isOpaque = true
        syncDrawableSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncDrawableSize()
    }

    func syncDrawableSize() {
        let scale = window?.screen.scale ?? max(contentScaleFactor, UIScreen.main.scale)
        let width = bounds.width * scale
        let height = bounds.height * scale
        guard width >= 2, height >= 2 else { return }
        let size = CGSize(width: width, height: height)
        if abs(drawableSize.width - size.width) > 0.5 || abs(drawableSize.height - size.height) > 0.5 {
            drawableSize = size
        }
    }
}

/// Native port of React Bits GhostFibers (ogl fullscreen fiber shader).
struct GhostFibersView: UIViewRepresentable {
    var paused = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = GhostFibersMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.isPaused = paused
        view.enableSetNeedsDisplay = paused
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0.063, green: 0.043, blue: 0.125, alpha: 1)
        view.isOpaque = true
        view.layer.isOpaque = true
        view.isHidden = false
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
            guard let device = view.device else { return }
            let library = (try? device.makeLibrary(source: Self.metalSource, options: nil))
                ?? device.makeDefaultLibrary()
            guard let library,
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
            view.isHidden = false
            view.isOpaque = true
            view.layer.isOpaque = true
            (view as? GhostFibersMTKView)?.syncDrawableSize()
        }

        private static let metalSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float2 resolution;
            float time;
            float speed;
            float scale;
            float rotation;
            float rotationSpeed;
            float layers;
            float waveAmplitude;
            float waveFrequency;
            float waveSpeed;
            float layerSpeed;
            float twist;
            float twistFrequency;
            float twistSpeed;
            float lineFrequency;
            float lineSpacing;
            float lineSharpness;
            float glowFalloff;
            float glowIntensity;
            float brightness;
            float blueBoost;
            float vignette;
            float grain;
            float lightMode;
            float pad0;
            float pad1;
            float pad2;
            float4 lineColor;
            float4 glowColor;
        };

        struct VertexOut {
            float4 position [[position]];
        };

        vertex VertexOut ghost_fibers_vertex(uint vid [[vertex_id]]) {
            float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            VertexOut out;
            out.position = float4(positions[vid], 0.0, 1.0);
            return out;
        }

        float2x2 rotate2d(float angle) {
            float sine = sin(angle);
            float cosine = cos(angle);
            return float2x2(float2(cosine, sine), float2(-sine, cosine));
        }

        float grainHash(float2 point) {
            point = floor(point);
            float hash = 52.9829189 * fract(dot(point, float2(0.065, 0.005)));
            return fract(hash);
        }

        float layeredGrain(float2 fragmentPixel, float time) {
            float2 point = fmod(fragmentPixel + float2(time * 30.0, -time * 21.0), 1024.0);
            float2 rotated = float2x2(float2(0.8, 0.5), float2(-0.5, 0.8)) * point;
            float grain = 0.0;
            grain += 0.40 * grainHash(rotated);
            grain += 0.25 * grainHash(rotated * 2.0 + 17.0);
            grain += 0.20 * grainHash(rotated * 4.0 + 47.0);
            grain += 0.10 * grainHash(rotated * 8.0 + 113.0);
            grain += 0.05 * grainHash(rotated * 16.0 + 191.0);
            return grain;
        }

        fragment float4 ghost_fibers_fragment(VertexOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
            float2 resolution = max(u.resolution, float2(1.0));
            float2 uv = (2.0 * in.position.xy - resolution) / resolution.y;
            uv.y = -uv.y;
            float time = u.time * u.speed;
            float3 backdrop = mix(float3(0.063, 0.043, 0.125), float3(1.0), step(0.5, u.lightMode));
            float3 lineColor = u.lineColor.rgb;
            float3 glowColor = u.glowColor.rgb;
            float3 centerTone = max(lineColor * 0.85567 - glowColor * 0.06186, float3(0.0));
            float3 cloudTone = lineColor * 0.19588 + glowColor * 0.2268;
            float2 p = uv;
            p /= max(u.scale, 0.05);
            p = rotate2d(u.rotation * 0.0174532925 + time * u.rotationSpeed) * p;
            float3 color = float3(0.0);
            float pulse = 0.82 + 0.18 * sin(time * 1.35);

            for (int index = 0; index < 10; index++) {
                float fi = float(index) + 1.0;
                if (fi > u.layers) break;

                p += u.waveAmplitude * sin(p.yx * fi * u.waveFrequency + time * (u.waveSpeed + fi * u.layerSpeed));

                float radius = length(p);
                float polarAngle = atan2(p.y, p.x);
                polarAngle += sin(radius * u.twistFrequency - time * u.twistSpeed + fi) * u.twist;
                p = float2(cos(polarAngle), sin(polarAngle)) * radius;

                float lines = abs(sin(p.x * (u.lineFrequency + fi * u.lineSpacing) + sin(p.y * 3.0 + time)));
                lines = pow(max(0.0, 1.0 - lines), u.lineSharpness);
                color += lineColor * lines / fi;

                float glow = exp(-u.glowFalloff * abs(sin(p.x * 3.0 + time + fi)));
                color += glowColor * glow * u.glowIntensity * pulse / (fi * 2.0);
            }

            float center = exp(-2.2 * dot(uv, uv));
            color += centerTone * center;

            float cloud = exp(-1.5 * length(uv + float2(sin(time * 0.3) * 0.25, cos(time * 0.25) * 0.18)));
            color += cloudTone * cloud;

            float vignette = 1.0 - smoothstep(0.35, 1.45, length(uv));
            color *= mix(1.0 - u.vignette, 1.0, vignette);
            color = 1.0 - exp(-color * u.brightness);
            color.b *= u.blueBoost;

            float3 outputColor = backdrop + color;
            float noise = (layeredGrain(in.position.xy, u.time) - 0.5) * u.grain;
            outputColor = clamp(outputColor + noise, 0.0, 1.0);
            return float4(outputColor, 1.0);
        }
        """

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            uniforms.resolution = SIMD2(Float(size.width), Float(size.height))
        }

        func draw(in view: MTKView) {
            (view as? GhostFibersMTKView)?.syncDrawableSize()
            guard view.drawableSize.width >= 2, view.drawableSize.height >= 2 else { return }
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
    var speed: Float = 0.28
    var scale: Float = 1.85
    var rotation: Float = 0
    var rotationSpeed: Float = 0.22
    var layers: Float = 5
    var waveAmplitude: Float = 0.028
    var waveFrequency: Float = 3
    var waveSpeed: Float = 0.15
    var layerSpeed: Float = 0.08
    var twist: Float = 0.18
    var twistFrequency: Float = 5
    var twistSpeed: Float = 1.2
    var lineFrequency: Float = 5
    var lineSpacing: Float = 2
    var lineSharpness: Float = 16
    var glowFalloff: Float = 10
    var glowIntensity: Float = 0.78
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

struct GhostFibersFallback: View {
    var paused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: paused ? 1 : 1.0 / 30.0, paused: paused)) { timeline in
            let time = paused ? 1.4 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .color(Color(red: 0.063, green: 0.043, blue: 0.125)))
                let glow = CGPoint(
                    x: size.width * (0.50 + 0.14 * sin(time * 0.33)),
                    y: size.height * (0.38 + 0.10 * cos(time * 0.27))
                )
                let glowRect = CGRect(
                    x: glow.x - size.width * 0.55,
                    y: glow.y - size.height * 0.45,
                    width: size.width * 1.1,
                    height: size.height * 0.9
                )
                context.fill(
                    Path(ellipseIn: glowRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 0.25, green: 0.17, blue: 0.53).opacity(0.42),
                            Color.clear
                        ]),
                        center: glow,
                        startRadius: 0,
                        endRadius: min(size.width, size.height) * 0.72
                    )
                )
                for i in 0..<8 {
                    var path = Path()
                    let amp = size.height * (0.035 + CGFloat(i) * 0.011)
                    let y0 = size.height * (0.12 + CGFloat(i) * 0.105)
                    let freq = 1.55 + Double(i) * 0.21
                    let phase = time * (0.55 + Double(i) * 0.07) + Double(i) * 0.9
                    path.move(to: CGPoint(x: -48, y: y0))
                    var x: CGFloat = -48
                    while x <= size.width + 48 {
                        let u = Double(x / max(size.width, 1))
                        let y = y0 +
                            sin(u * freq * 6.2832 + phase) * amp +
                            sin(u * 2.15 + phase * 0.71) * amp * 0.38
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += 14
                    }
                    context.stroke(
                        path,
                        with: .color(Palette.accent.opacity(0.10 + Double(i % 4) * 0.035)),
                        style: StrokeStyle(lineWidth: 2 + CGFloat(i) * 0.42, lineCap: .round)
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}
