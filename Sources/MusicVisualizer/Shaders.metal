#include <metal_stdlib>
using namespace metal;

struct AudioUniforms {
    float time;
    float deltaTime;
    float bass;
    float mid;
    float treble;
    float loudness;
    float beatPulse;
    float viewWidth;
    float viewHeight;
};

constant uint kRingCount = 12;
constant uint kRingSegments = 56;
constant uint kSpokeCount = 28;
constant uint kVertsPerSegment = 6;
constant uint kRingVertexCount = kRingCount * kRingSegments * kVertsPerSegment;
constant uint kSpokeVertexCount = kSpokeCount * kVertsPerSegment;
constant uint kTotalVertexCount = kRingVertexCount + kSpokeVertexCount;

struct GeoVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex GeoVertexOut geo_vertex(constant AudioUniforms &u [[buffer(1)]],
                                uint vid [[vertex_id]]) {
    bool isSpoke = vid >= kRingVertexCount;
    uint localId = isSpoke ? (vid - kRingVertexCount) : vid;
    uint elementIndex = localId / kVertsPerSegment;
    uint cornerIndex = localId % kVertsPerSegment;

    float minDim = min(u.viewWidth, u.viewHeight);
    float maxRadius = minDim * 0.46;
    float time = u.time;

    float2 p0 = float2(0.0);
    float2 p1 = float2(0.0);
    float ringT = 1.0;

    if (!isSpoke) {
        uint ringIndex = elementIndex / kRingSegments;
        uint segIndex = elementIndex % kRingSegments;
        ringT = float(ringIndex + 1) / float(kRingCount);
        float baseRadius = ringT * maxRadius;

        float spin = (ringIndex % 2u == 0u) ? 1.0 : -1.0;
        float rotation = time * (0.05 + u.mid * 0.5) * spin;

        float a0 = (float(segIndex) / float(kRingSegments)) * 6.2831853 + rotation;
        float a1 = (float(segIndex + 1) / float(kRingSegments)) * 6.2831853 + rotation;

        float warpFreq = 3.0 + floor(ringT * 5.0);
        float warpAmount = 0.02 + u.bass * 0.5;
        float breathe = 1.0 + u.bass * 0.3 + u.beatPulse * 0.18;

        float r0 = baseRadius * breathe * (1.0 + warpAmount * sin(a0 * warpFreq + time * 1.6));
        float r1 = baseRadius * breathe * (1.0 + warpAmount * sin(a1 * warpFreq + time * 1.6));

        p0 = float2(cos(a0), sin(a0)) * r0;
        p1 = float2(cos(a1), sin(a1)) * r1;
    } else {
        uint spokeIndex = elementIndex;
        float a = (float(spokeIndex) / float(kSpokeCount)) * 6.2831853 + time * 0.04;
        float jitter = sin(a * 9.0 + time * 7.0) * u.treble * 0.12;
        float len = maxRadius * (0.9 + u.loudness * 0.12 + jitter);
        p0 = float2(0.0, 0.0);
        p1 = float2(cos(a), sin(a)) * len;
        ringT = 1.0;
    }

    float2 dir = p1 - p0;
    float dirLen = max(length(dir), 1e-4);
    float2 n = float2(-dir.y, dir.x) / dirLen;

    float lineWidth = minDim * (0.0012 + u.loudness * 0.0022 + u.beatPulse * 0.0026);

    float2 corners[6] = {
        p0 - n * lineWidth, p0 + n * lineWidth, p1 - n * lineWidth,
        p0 + n * lineWidth, p1 + n * lineWidth, p1 - n * lineWidth
    };
    float2 pos = corners[cornerIndex];

    float halfW = max(u.viewWidth, 1.0) * 0.5;
    float halfH = max(u.viewHeight, 1.0) * 0.5;

    GeoVertexOut out;
    out.position = float4(pos.x / halfW, pos.y / halfH, 0.0, 1.0);

    float3 coolColor = float3(0.18, 0.85, 1.0);
    float3 hotColor = float3(1.0, 1.0, 1.0);
    float3 baseColor = mix(coolColor, hotColor, saturate(u.treble * 0.7 + ringT * 0.15));
    float brightness = 0.28 + u.loudness * 0.85 + u.beatPulse * 1.1;

    out.color = float4(baseColor * brightness, 1.0);
    return out;
}

fragment float4 geo_fragment(GeoVertexOut in [[stage_in]]) {
    return in.color;
}
