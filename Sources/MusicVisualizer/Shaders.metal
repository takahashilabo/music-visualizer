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
    float sceneWeightLines;
    float sceneWeightParticles;
    float sceneWeightBoxes;
    float sceneWeightSplines;
};

// ---- "lines" scene: concentric warped rings + radial spokes ----
constant uint kRingCount = 12;
constant uint kRingSegments = 56;
constant uint kSpokeCount = 28;
constant uint kVertsPerSegment = 6;
constant uint kRingVertexCount = kRingCount * kRingSegments * kVertsPerSegment;
constant uint kSpokeVertexCount = kSpokeCount * kVertsPerSegment;
constant uint kLineVertexCount = kRingVertexCount + kSpokeVertexCount;

// ---- "particles" scene: soft radial sparks scattered over a disc ----
constant uint kParticleCount = 900;
constant uint kVertsPerQuad = 6;
constant uint kParticleVertexCount = kParticleCount * kVertsPerQuad;

// ---- "boxes" scene: an equalizer-like grid of pulsing square outlines ----
constant uint kBoxCols = 10;
constant uint kBoxRows = 6;
constant uint kBoxCount = kBoxCols * kBoxRows;
constant uint kEdgesPerBox = 4;
constant uint kBoxVertexCount = kBoxCount * kEdgesPerBox * kVertsPerSegment;

// ---- "splines" scene: flowing sine ribbons across the screen ----
constant uint kSplineCount = 10;
constant uint kSplineSamples = 40;
constant uint kSplineSegmentCount = kSplineCount * (kSplineSamples - 1);
constant uint kSplineVertexCount = kSplineSegmentCount * kVertsPerSegment;

constant uint kParticleStart = kLineVertexCount;
constant uint kParticleEnd = kParticleStart + kParticleVertexCount;
constant uint kBoxStart = kParticleEnd;
constant uint kBoxEnd = kBoxStart + kBoxVertexCount;
constant uint kSplineStart = kBoxEnd;
constant uint kSplineEnd = kSplineStart + kSplineVertexCount;

struct GeoVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

inline float hash11(uint n) {
    n = (n << 13u) ^ n;
    n = n * (n * n * 15731u + 789221u) + 1376312589u;
    return float(n & 0x7fffffffu) / float(0x7fffffff);
}

inline float2 lineQuadCorner(float2 p0, float2 p1, float lineWidth, uint cornerIndex) {
    float2 dir = p1 - p0;
    float dirLen = max(length(dir), 1e-4);
    float2 n = float2(-dir.y, dir.x) / dirLen;
    float2 corners[6] = {
        p0 - n * lineWidth, p0 + n * lineWidth, p1 - n * lineWidth,
        p0 + n * lineWidth, p1 + n * lineWidth, p1 - n * lineWidth
    };
    return corners[cornerIndex];
}

inline float2 splineSample(uint curveIndex, uint sampleIndex, constant AudioUniforms &u, float time) {
    float h1 = hash11(curveIndex * 11u + 3u);
    float h2 = hash11(curveIndex * 17u + 5u);
    float h3 = hash11(curveIndex * 23u + 9u);
    float freq = 1.5 + h1 * 2.5;
    float phase = h2 * 6.2831853;
    float speed = 0.25 + h3 * 0.6;
    float baseY = (float(curveIndex) + 0.5) / float(kSplineCount) * u.viewHeight - u.viewHeight * 0.5;
    baseY *= 0.82;
    float xSpan = u.viewWidth * 0.92;
    float t = float(sampleIndex) / float(kSplineSamples - 1);
    float x = (t - 0.5) * xSpan;
    float amp = (u.viewHeight / float(kSplineCount)) * 0.42 * (0.5 + u.mid * 1.3 + u.bass * 0.6);
    float y = baseY
        + amp * sin(freq * (t * 6.2831853) + phase + time * speed)
        + amp * 0.35 * sin(freq * 2.3 * (t * 6.2831853) + phase * 1.7 + time * speed * 1.6) * u.treble;
    return float2(x, y);
}

vertex GeoVertexOut geo_vertex(constant AudioUniforms &u [[buffer(1)]],
                                uint vid [[vertex_id]]) {
    float minDim = min(u.viewWidth, u.viewHeight);
    float maxRadius = minDim * 0.46;
    float time = u.time;
    float halfW = max(u.viewWidth, 1.0) * 0.5;
    float halfH = max(u.viewHeight, 1.0) * 0.5;

    GeoVertexOut out;
    out.uv = float2(0.0);

    if (vid < kRingVertexCount) {
        // --- ring segment ---
        uint elementIndex = vid / kVertsPerSegment;
        uint cornerIndex = vid % kVertsPerSegment;

        uint ringIndex = elementIndex / kRingSegments;
        uint segIndex = elementIndex % kRingSegments;
        float ringT = float(ringIndex + 1) / float(kRingCount);
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

        float2 p0 = float2(cos(a0), sin(a0)) * r0;
        float2 p1 = float2(cos(a1), sin(a1)) * r1;
        float lineWidth = minDim * (0.0012 + u.loudness * 0.0022 + u.beatPulse * 0.0026);
        float2 pos = lineQuadCorner(p0, p1, lineWidth, cornerIndex);

        out.position = float4(pos.x / halfW, pos.y / halfH, 0.0, 1.0);

        float3 coolColor = float3(0.18, 0.85, 1.0);
        float3 hotColor = float3(1.0, 1.0, 1.0);
        float3 baseColor = mix(coolColor, hotColor, saturate(u.treble * 0.7 + ringT * 0.15));
        float brightness = 0.28 + u.loudness * 0.85 + u.beatPulse * 1.1;
        out.color = float4(baseColor * brightness * u.sceneWeightLines, 1.0);
        return out;

    } else if (vid < kLineVertexCount) {
        // --- spoke segment ---
        uint localId = vid - kRingVertexCount;
        uint spokeIndex = localId / kVertsPerSegment;
        uint cornerIndex = localId % kVertsPerSegment;

        float a = (float(spokeIndex) / float(kSpokeCount)) * 6.2831853 + time * 0.04;
        float jitter = sin(a * 9.0 + time * 7.0) * u.treble * 0.12;
        float len = maxRadius * (0.9 + u.loudness * 0.12 + jitter);
        float2 p0 = float2(0.0, 0.0);
        float2 p1 = float2(cos(a), sin(a)) * len;
        float lineWidth = minDim * (0.0012 + u.loudness * 0.0022 + u.beatPulse * 0.0026);
        float2 pos = lineQuadCorner(p0, p1, lineWidth, cornerIndex);

        out.position = float4(pos.x / halfW, pos.y / halfH, 0.0, 1.0);

        float3 coolColor = float3(0.18, 0.85, 1.0);
        float3 hotColor = float3(1.0, 1.0, 1.0);
        float3 baseColor = mix(coolColor, hotColor, saturate(u.treble * 0.7 + 0.15));
        float brightness = 0.28 + u.loudness * 0.85 + u.beatPulse * 1.1;
        out.color = float4(baseColor * brightness * u.sceneWeightLines, 1.0);
        return out;

    } else if (vid < kParticleEnd) {
        // --- particle spark ---
        uint localId = vid - kParticleStart;
        uint particleIndex = localId / kVertsPerQuad;
        uint cornerIndex = localId % kVertsPerQuad;

        float h1 = hash11(particleIndex * 2u + 1u);
        float h2 = hash11(particleIndex * 2u + 2u);
        float h3 = hash11(particleIndex * 3u + 7u);
        float h4 = hash11(particleIndex * 5u + 13u);
        float h5 = hash11(particleIndex * 7u + 29u);

        float angle0 = h1 * 6.2831853;
        float radiusFrac = sqrt(h2);
        float phase = h3 * 6.2831853;
        float speed = 0.3 + h4 * 1.0;
        float sizeRand = h5;

        float spin = (particleIndex % 2u == 0u) ? 1.0 : -1.0;
        float angle = angle0 + time * (0.04 + u.mid * 0.3) * spin;
        float radius = radiusFrac * maxRadius * 1.05;
        radius *= 1.0 + 0.035 * sin(time * speed + phase);
        radius *= 1.0 + u.bass * 0.22 + u.beatPulse * 0.14;

        float2 center = float2(cos(angle), sin(angle)) * radius;

        float twinkle = 0.5 + 0.5 * sin(time * (2.0 + speed * 3.0) + phase * 2.0);
        float sizeBase = minDim * (0.0020 + sizeRand * 0.0035);
        float size = sizeBase * (0.55 + u.loudness * 0.9 + u.beatPulse * 0.5) * (0.5 + twinkle * 0.8);

        float2 uvCorners[6] = {
            float2(-1.0, -1.0), float2(-1.0, 1.0), float2(1.0, -1.0),
            float2(-1.0, 1.0),  float2(1.0, 1.0),  float2(1.0, -1.0)
        };
        float2 uv = uvCorners[cornerIndex];
        float2 pos = center + uv * size;

        out.position = float4(pos.x / halfW, pos.y / halfH, 0.0, 1.0);
        out.uv = uv;

        float3 warmColor = mix(float3(1.0, 0.5, 0.15), float3(1.0, 0.95, 0.85),
                                saturate(u.treble * 0.8 + twinkle * 0.3));
        float brightness = (0.35 + u.loudness * 1.1 + u.beatPulse * 0.9) * (0.4 + twinkle * 0.9);
        out.color = float4(warmColor * brightness * u.sceneWeightParticles, 1.0);
        return out;

    } else if (vid < kBoxEnd) {
        // --- equalizer box ---
        uint localId = vid - kBoxStart;
        uint elementIndex = localId / kVertsPerSegment;
        uint cornerIndex = localId % kVertsPerSegment;
        uint boxIndex = elementIndex / kEdgesPerBox;
        uint edge = elementIndex % kEdgesPerBox;

        uint col = boxIndex % kBoxCols;
        uint row = boxIndex / kBoxCols;
        float cellW = u.viewWidth / float(kBoxCols);
        float cellH = u.viewHeight / float(kBoxRows);
        float centerX = (float(col) + 0.5) * cellW - halfW;
        float centerY = (float(row) + 0.5) * cellH - halfH;

        float bandT = float(col) / float(max(kBoxCols, 2u) - 1u);
        float low = saturate(bandT * 2.0);
        float high = saturate(bandT * 2.0 - 1.0);
        float bandEnergy = mix(mix(u.bass, u.mid, low), u.treble, high);

        float cellSize = min(cellW, cellH);
        float halfSize = cellSize * 0.5 * (0.42 + bandEnergy * 0.95 + u.beatPulse * 0.35);

        float2 boxCorners[4] = {
            float2(-1.0, 1.0), float2(1.0, 1.0), float2(1.0, -1.0), float2(-1.0, -1.0)
        };
        float2 p0 = boxCorners[edge] * halfSize + float2(centerX, centerY);
        float2 p1 = boxCorners[(edge + 1u) % 4u] * halfSize + float2(centerX, centerY);

        float lineWidth = minDim * (0.0014 + u.loudness * 0.0018 + u.beatPulse * 0.0024);
        float2 pos = lineQuadCorner(p0, p1, lineWidth, cornerIndex);

        out.position = float4(pos.x / halfW, pos.y / halfH, 0.0, 1.0);

        float3 coolColor = float3(0.85, 0.2, 0.9);
        float3 hotColor = float3(1.0, 0.9, 1.0);
        float3 baseColor = mix(coolColor, hotColor, saturate(bandEnergy * 0.8));
        float brightness = 0.3 + u.loudness * 0.85 + u.beatPulse * 1.0;
        out.color = float4(baseColor * brightness * u.sceneWeightBoxes, 1.0);
        return out;

    } else {
        // --- flowing spline ---
        uint localId = vid - kSplineStart;
        uint segGlobalIndex = localId / kVertsPerSegment;
        uint cornerIndex = localId % kVertsPerSegment;
        uint curveIndex = segGlobalIndex / (kSplineSamples - 1);
        uint sampleIndex = segGlobalIndex % (kSplineSamples - 1);

        float2 p0 = splineSample(curveIndex, sampleIndex, u, time);
        float2 p1 = splineSample(curveIndex, sampleIndex + 1, u, time);

        float lineWidth = minDim * (0.0014 + u.loudness * 0.0022 + u.beatPulse * 0.0026);
        float2 pos = lineQuadCorner(p0, p1, lineWidth, cornerIndex);

        out.position = float4(pos.x / halfW, pos.y / halfH, 0.0, 1.0);

        float t = float(sampleIndex) / float(kSplineSamples - 1);
        float3 coolColor = float3(0.3, 1.0, 0.55);
        float3 hotColor = float3(1.0, 1.0, 0.9);
        float3 baseColor = mix(coolColor, hotColor, saturate(u.treble * 0.6 + t * 0.2));
        float brightness = 0.3 + u.loudness * 0.85 + u.beatPulse * 1.0;
        out.color = float4(baseColor * brightness * u.sceneWeightSplines, 1.0);
        return out;
    }
}

fragment float4 geo_fragment(GeoVertexOut in [[stage_in]]) {
    float dist = length(in.uv);
    float fall = (dist > 0.0) ? exp(-dist * dist * 2.2) : 1.0;
    float4 c = in.color;
    c.rgb *= fall;
    return c;
}

// ---- Tonemap pass: a fullscreen triangle that reads the HDR-accumulated
// geometry pass and compresses it into displayable range. Additive
// blending across many overlapping lines/particles (plus sustained loud
// passages) can easily push color values well past 1.0; writing straight
// to an 8-bit target would just hard-clip all of that to flat white,
// erasing exactly the beat-driven brightness changes this app exists to
// show. Reinhard-style compression keeps those differences visible
// instead of flattening everything bright into the same white blob.
struct FullscreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVertexOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    float2 uvs[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
    FullscreenVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 tonemap_fragment(FullscreenVertexOut in [[stage_in]],
                                  texture2d<float> hdrTex [[texture(0)]],
                                  constant AudioUniforms &u [[buffer(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float4 hdr = hdrTex.sample(s, in.uv);

    // A beat multiplies the whole frame's brightness up front, so the
    // "this just happened because of the music" flash reads clearly
    // instead of being just one more additive term buried in the mix.
    float beatFlash = 1.0 + u.beatPulse * 1.6;
    float3 mapped = (hdr.rgb * beatFlash) / (1.0 + hdr.rgb * beatFlash);
    float alpha = saturate(hdr.a);
    return float4(mapped, alpha);
}
