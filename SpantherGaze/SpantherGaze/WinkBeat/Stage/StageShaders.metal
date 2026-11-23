// Wink Beat's play layer (skill `metal-anime-stage`, section 2): instanced quads, each shaded by a signed distance.
//
// Inputs
// - buffer(0) `StageInstance` array, one per shape. Positions and sizes are in screen points (pt), origin top left,
//   y down, the same space as the judge's positions in GazeCore. Colours are linear RGB with straight alpha.
// - buffer(1) `StageUniforms`: the view's size in pt.
// Output: premultiplied linear colour into a .bgra8Unorm_srgb target over a clear background; blending is
// one / one-minus-source-alpha. Anti-aliasing comes from the distance field (fwidth), so there is no MSAA.
//
// Shapes (StageInstance.kind)
// 0 disc: a capsule from `a` to `b` (a dot when a == b) of `radius`, filled with `color`, with an outline of
//   `width` pt in `color2` inside its edge.
// 1 ring: a band of `width` pt centred on `radius` around the capsule.
// 2 glow: soft light of `color`, strongest on the capsule's spine and gone at `radius`.
// 3 corners: lock brackets on a square of half size `radius`, stroke `width`, arms of `color2.x` pt.
// 4 petal: a leaf `radius` long from its root `a` pointing to `b`, filled with `color`, outline `width` in `color2`.
//
// The Swift side of these structs is `StageInstance` / `StageUniforms` in StageRenderer.swift: same fields, same
// order, same sizes (64 and 16 bytes).

#include <metal_stdlib>
using namespace metal;

struct StageInstance {
    float2 a;
    float2 b;
    float radius;
    float width;
    float kind;
    float pad;
    float4 color;
    float4 color2;
};

struct StageUniforms {
    float2 viewSize;
    float2 pad;
};

struct StageVaryings {
    float4 position [[position]];
    float2 p;
    uint iid [[flat]];
};

vertex StageVaryings stage_vertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  const device StageInstance *shapes [[buffer(0)]],
                                  constant StageUniforms &u [[buffer(1)]]) {
    StageInstance s = shapes[iid];
    float2 d = s.b - s.a;
    float len = length(d);
    float2 x = len > 0.001 ? d / len : float2(1.0, 0.0);
    float2 y = float2(-x.y, x.x);
    // Room for the shape, its outline or ring band, and the anti-aliased edge.
    float e = s.radius + s.width + 3.0;
    if (s.kind > 2.5 && s.kind < 3.5) { e = e * 1.42; }
    float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
    float2 p = (corner.x > 0.0 ? s.b + x * e : s.a - x * e) + y * (e * corner.y);
    StageVaryings o;
    o.p = p;
    o.iid = iid;
    o.position = float4(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0, 0.0, 1.0);
    return o;
}

static inline float len2(float2 v) { return dot(v, v); }

static float coverage(float sd, float aa) {
    return clamp(0.5 - sd / aa, 0.0, 1.0);
}

fragment half4 stage_fragment(StageVaryings in [[stage_in]],
                              const device StageInstance *shapes [[buffer(0)]]) {
    StageInstance s = shapes[in.iid];
    float2 ab = s.b - s.a;
    float2 ap = in.p - s.a;
    float h = clamp(dot(ap, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    float dist = length(ap - ab * h);
    float aa = max(fwidth(dist), 0.0005);

    float4 c = float4(0.0);
    if (s.kind < 0.5) {
        float shape = coverage(dist - s.radius, aa);
        float fill = coverage(dist - (s.radius - s.width), aa);
        c = mix(s.color2, s.color, fill);
        c.a *= shape;
    } else if (s.kind < 1.5) {
        c = s.color;
        c.a *= coverage(fabs(dist - s.radius) - s.width * 0.5, aa);
    } else if (s.kind < 2.5) {
        float k = clamp(1.0 - dist / max(s.radius, 0.001), 0.0, 1.0);
        c = s.color;
        c.a *= k * k;
    } else if (s.kind < 3.5) {
        float2 q = fabs(in.p - s.a) - float2(s.radius);
        float box = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        float stroke = coverage(fabs(box) - s.width * 0.5, max(fwidth(box), 0.0005));
        float2 r = fabs(in.p - s.a);
        float arm = s.radius - s.color2.x;
        float inCorner = step(arm, r.x) * step(arm, r.y);
        c = s.color;
        c.a *= stroke * inCorner;
    } else {
        // A leaf along the axis a -> b: two circle arcs meeting at the root and the tip.
        float2 axis = len2(ab) > 1e-6 ? normalize(ab) : float2(0.0, -1.0);
        float2 side = float2(-axis.y, axis.x);
        float along = dot(ap, axis);
        float across = dot(ap, side);
        float L = s.radius;
        float w = 0.36 * L;
        // The circle through the root, the tip and the widest point (along L/2, across w).
        float R = (L * L * 0.25 + w * w) / (2.0 * w);
        float2 local = float2(along - L * 0.5, fabs(across));
        float leaf = length(local - float2(0.0, w - R)) - R;
        float shape = coverage(leaf, aa);
        float fill = coverage(leaf + s.width, aa);
        c = mix(s.color2, s.color, fill);
        c.a *= shape;
    }
    return half4(half3(c.rgb * c.a), half(c.a));
}

