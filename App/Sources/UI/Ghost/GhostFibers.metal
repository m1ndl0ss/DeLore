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
    float fiberField = 0.0;

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
        fiberField += lines / fi;
        color += lineColor * lines / fi;

        float glow = exp(-u.glowFalloff * abs(sin(p.x * 3.0 + time + fi)));
        color += glowColor * glow * u.glowIntensity / (fi * 2.0);
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
