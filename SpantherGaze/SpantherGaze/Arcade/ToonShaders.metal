// The blink arcades' 3D toon stage (skill `metal-anime-stage`, the world layer): cel shading in three tone bands
// with cast shadows from the sun, a hard rim, ink outlines by inverted hull, a see-through pond surface, fog.
//
// Inputs
// - buffer(0) `ToonVertex` array: position and normal in the mesh's own space (metres), colour in linear RGB.
//   All of a scene's meshes share one buffer; their index ranges are offset already (base vertex 0).
// - buffer(1) `ToonInstance` array, one per draw, read with [[instance_id]] (which includes the base instance):
//   the model matrix, the inverse transpose of its 3x3 for normals (three columns), the tint (linear RGB, alpha the
//   opacity of blended styles) and params: x the ink outline width in points, y the style (0 toon, 1 flat,
//   2 water, 3 ghost).
// - buffer(2) / fragment buffer(0) `ToonFrame`: world to clip (Metal clip space, right-handed world, y up), world
//   to the sun's shadow map clip space, the unit vector towards the sun, the eye (world), sky colours, the shadow
//   tone (w: shadow strength, 0 when the shadow pass is off), misc (x stage time s, y and z the viewport in pixels,
//   w pixels per point), fog (x start, y end, metres from the eye), ink.
// - fragment texture(0): the sun's depth map (Depth32Float, 0 near the sun).
// Output: premultiplied linear colour into a .bgra8Unorm_srgb target, 4x MSAA resolved into the drawable.
//
// The Swift side of these structs is in ToonRenderer.swift (`ToonInstance`, `ToonFrameUniforms`) and GazeCore
// (`ToonVertex`): same fields, same order, same sizes (48, 144 and 256 bytes).

#include <metal_stdlib>
using namespace metal;

struct ToonVertex {
    float3 position;
    float3 normal;
    float3 color;
};

struct ToonInstance {
    float4 m0;
    float4 m1;
    float4 m2;
    float4 m3;
    float4 n0;
    float4 n1;
    float4 n2;
    float4 tint;
    float4 params;
};

struct ToonFrame {
    float4x4 viewProjection;
    float4x4 sun;
    float4 toward;
    float4 eye;
    float4 skyTop;
    float4 skyHorizon;
    float4 shade;
    float4 misc;
    float4 fog;
    float4 ink;
};

struct ToonOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 color;
    float4 sunPos;
    float alpha;
    float style [[flat]];
};

struct InkOut {
    float4 position [[position]];
    float3 world;
};

struct SunOut {
    float4 position [[position]];
};

constexpr sampler sunSampler(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);

static float4 worldOf(ToonVertex v, ToonInstance inst) {
    float4x4 model = float4x4(inst.m0, inst.m1, inst.m2, inst.m3);
    return model * float4(v.position, 1.0);
}

static float3 normalOf(ToonVertex v, ToonInstance inst) {
    float3x3 nm = float3x3(inst.n0.xyz, inst.n1.xyz, inst.n2.xyz);
    float3 n = nm * v.normal;
    float l = length(n);
    return l > 1e-6 ? n / l : float3(0.0, 1.0, 0.0);
}

vertex ToonOut toon_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device ToonVertex *vertices [[buffer(0)]],
                           const device ToonInstance *instances [[buffer(1)]],
                           constant ToonFrame &frame [[buffer(2)]]) {
    ToonVertex v = vertices[vid];
    ToonInstance inst = instances[iid];
    float4 world = worldOf(v, inst);
    float3 n = normalOf(v, inst);
    ToonOut out;
    out.position = frame.viewProjection * world;
    out.world = world.xyz;
    out.normal = n;
    out.color = v.color * inst.tint.rgb;
    out.alpha = inst.tint.a;
    // Looked up a little off the surface, along its normal: no shadow acne on curved toon surfaces.
    out.sunPos = frame.sun * float4(world.xyz + n * 0.04, 1.0);
    out.style = inst.params.y;
    return out;
}

/// 1 in full sun, 0 in shadow: nine filtered taps of the sun's map, faded by the shadow strength.
static float sunlight(float4 sunPos, depth2d<float> map, float strength) {
    if (strength <= 0.0) {
        return 1.0;
    }
    float3 p = sunPos.xyz / sunPos.w;
    float2 uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || p.z > 1.0) {
        return 1.0;
    }
    float texel = 1.0 / float(map.get_width());
    float lit = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            lit += map.sample_compare(sunSampler, uv + float2(float(x), float(y)) * texel * 1.25, p.z - 0.0012);
        }
    }
    return mix(1.0, lit / 9.0, strength);
}

fragment float4 toon_fragment(ToonOut in [[stage_in]],
                              constant ToonFrame &frame [[buffer(0)]],
                              depth2d<float> sunMap [[texture(0)]]) {
    int style = int(in.style + 0.5);
    float3 toEye = frame.eye.xyz - in.world;
    float dist = length(toEye);
    float3 V = toEye / max(dist, 1e-4);
    float fogK = smoothstep(frame.fog.x, frame.fog.y, dist) * 0.85;
    float3 base = in.color;

    if (style == 1) {
        float3 c = mix(base, frame.skyHorizon.rgb, fogK);
        return float4(c * in.alpha, in.alpha);
    }

    float3 N = normalize(in.normal);
    float lit = sunlight(in.sunPos, sunMap, frame.shade.w);

    if (style == 2) {
        // The pond: drifting light bands over the water's own colour, the sky in it at a slant, shadows on it.
        float t = frame.misc.x;
        float2 p = in.world.xz;
        float wave = 0.5 * sin(p.x * 1.6 + t * 0.8) + 0.5 * sin(p.y * 2.1 - t * 0.6 + p.x * 0.5);
        float wave2 = sin((p.x - p.y) * 2.9 + t * 1.4);
        float w = wave * 0.6 + wave2 * 0.4;
        float e = max(fwidth(w), 0.01);
        float band = smoothstep(0.62 - e, 0.62 + e, w);
        float3 c = base * mix(0.72, 1.0, lit);
        c = mix(c, float3(0.93, 0.98, 1.0), band * 0.5);
        float fres = pow(1.0 - saturate(dot(float3(0.0, 1.0, 0.0), V)), 3.0);
        c = mix(c, frame.skyHorizon.rgb, fres * 0.45);
        c = mix(c, frame.skyHorizon.rgb, fogK);
        float a = clamp(in.alpha + band * 0.35 + fres * 0.3, 0.0, 1.0);
        return float4(c * a, a);
    }

    // Toon: three bands of the surface's own colour; the shadowed one leans to the cool shade tone.
    float d = saturate(dot(N, frame.toward.xyz)) * lit;
    float e = max(fwidth(d), 0.002);
    float toMid = smoothstep(0.16 - e, 0.16 + e, d);
    float toLit = smoothstep(0.5 - e, 0.5 + e, d);
    float3 shadowTone = base * mix(float3(1.0), frame.shade.rgb * 1.6, 0.45) * 0.56;
    float3 midTone = base * 0.82;
    float3 c = mix(shadowTone, midTone, toMid);
    c = mix(c, base, toLit);
    // Light from the sky into every side, and a hard rim where the surface turns away on the lit side.
    c += base * frame.skyTop.rgb * 0.07;
    float rim = pow(1.0 - saturate(dot(N, V)), 3.0);
    float rimE = max(fwidth(rim), 0.002);
    c = mix(c, frame.skyHorizon.rgb, smoothstep(0.55 - rimE, 0.55 + rimE, rim) * 0.3 * toMid);
    c = mix(c, frame.skyHorizon.rgb, fogK);
    float a = style == 3 ? in.alpha : 1.0;
    return float4(c * a, a);
}

/// The ink outline: the mesh again, pushed out along its normal by a width in pixels and drawn with its front
/// faces culled, so only the rim behind the surface shows. Draws without an outline, or fading ones, are moved
/// out of the clip volume.
vertex InkOut outline_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device ToonVertex *vertices [[buffer(0)]],
                             const device ToonInstance *instances [[buffer(1)]],
                             constant ToonFrame &frame [[buffer(2)]]) {
    ToonVertex v = vertices[vid];
    ToonInstance inst = instances[iid];
    float4 world = worldOf(v, inst);
    float3 n = normalOf(v, inst);
    float4 clip = frame.viewProjection * world;
    float4 clipN = frame.viewProjection * float4(n, 0.0);
    float2 viewport = frame.misc.yz;
    float2 dir = clipN.xy * viewport;
    float l = length(dir);
    dir = l > 1e-6 ? dir / l : float2(0.0);
    float px = inst.params.x * frame.misc.w;
    clip.xy += dir * (px * 2.0) / viewport * clip.w;
    InkOut out;
    out.position = (inst.params.x > 0.0 && inst.tint.a > 0.99) ? clip : float4(0.0, 0.0, 2.0, 1.0);
    out.world = world.xyz;
    return out;
}

fragment float4 outline_fragment(InkOut in [[stage_in]], constant ToonFrame &frame [[buffer(0)]]) {
    float dist = length(frame.eye.xyz - in.world);
    float fogK = smoothstep(frame.fog.x, frame.fog.y, dist) * 0.85;
    return float4(mix(frame.ink.rgb, frame.skyHorizon.rgb, fogK), 1.0);
}

/// The sun's depth map: depth only.
vertex SunOut sun_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device ToonVertex *vertices [[buffer(0)]],
                         const device ToonInstance *instances [[buffer(1)]],
                         constant ToonFrame &frame [[buffer(2)]]) {
    SunOut out;
    out.position = frame.sun * worldOf(vertices[vid], instances[iid]);
    return out;
}
