// nanoui's one shader: instanced quads that are rounded rectangles with
// borders (kind 0), glyph runs and icons sampled from the atlas (kind 1),
// shadows (kind 2): Gaussian blurs of rounded boxes, as GPUI draws them, or
// pictures sampled from the image atlas (kind 3), their corners rounded.
// Panes of glass (kind 4) have their own fragment function (glass.metal).
// Each is clipped to its clip rectangle, some of whose corners may be
// rounded (a box with rounded corners that clips its children).
#include <metal_stdlib>
using namespace metal;

struct Instance {
    float4 rect;         // x, y, w, h in points
    float4 color;        // straight alpha
    float4 border_color;
    float4 uv;           // atlas u0, v0, u1, v1
    float4 clip;         // x0, y0, x1, y1
    float radius;
    float border_width;  // blur radius for shadows
    float kind;
    float clip_round;    // corners * 4096 + radius (gpu.zig's clipRound)
};

struct VOut {
    float4 pos [[position]];
    float2 local;
    float2 world;
    float2 uv;
    uint inst [[flat]];
};

vertex VOut vs(uint vid [[vertex_id]], uint iid [[instance_id]],
               constant Instance *instances [[buffer(0)]],
               constant float2 &viewport [[buffer(1)]]) {
    Instance i = instances[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    // Shadows reach three standard deviations past their box.
    float grow = i.kind == 2 ? i.border_width * 3.0 : 0.0;
    float2 p = i.rect.xy - grow + corner * (i.rect.zw + 2.0 * grow);
    VOut o;
    o.pos = float4(p / viewport * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.local = p - i.rect.xy;
    o.world = p;
    o.uv = mix(i.uv.xy, i.uv.zw, corner);
    o.inst = iid;
    return o;
}

// Shadows as GPUI draws them (after Evan Wallace's "fast rounded rectangle
// shadows"): the box's coverage blurred by a Gaussian, exact along x with
// erf, sampled four times along y.
static float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * M_PI_F) * sigma);
}

static float2 erf2(float2 x) {
    float2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

static float blur_along_x(float x, float y, float sigma, float corner, float2 half_size) {
    float delta = min(half_size.y - corner - abs(y), 0.0);
    float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    float2 integral = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

static float shadow_alpha(float2 p, float2 half_size, float corner, float sigma) {
    float low = p.y - half_size.y;
    float high = p.y + half_size.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end = clamp(3.0 * sigma, low, high);
    float step = (end - start) / 4.0;
    float y = start + step * 0.5;
    float alpha = 0.0;
    for (int k = 0; k < 4; k++) {
        alpha += blur_along_x(p.x, p.y - y, sigma, corner, half_size) * gaussian(y, sigma) * step;
        y += step;
    }
    return alpha;
}

static float rounded_box(float2 p, float2 half_size, float r) {
    float2 q = abs(p) - half_size + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float4 shade(VOut in, Instance i, texture2d<float> atlas, texture2d<float> images);

// How much of the fragment the instance's clip lets through: discarded
// outside it, cut in its rounded corners.
static float clip_coverage(VOut in, Instance i) {
    if (in.world.x < i.clip.x || in.world.y < i.clip.y || in.world.x > i.clip.z || in.world.y > i.clip.w)
        discard_fragment();
    float clip_cover = 1.0;
    if (i.clip_round > 0.0) {
        float corners = floor(i.clip_round / 4096.0);
        float rad = i.clip_round - corners * 4096.0;
        float2 ch = (i.clip.zw - i.clip.xy) * 0.5;
        float2 q = in.world - i.clip.xy - ch;
        // Derivatives outside the branch on the corner: it differs by pixel.
        float cd = rounded_box(q, ch, min(rad, min(ch.x, ch.y)));
        float caa = max(fwidth(cd), 0.0001) * 0.5;
        uint bit = q.y < 0.0 ? (q.x < 0.0 ? 1u : 2u) : (q.x < 0.0 ? 8u : 4u);
        if ((uint(corners) & bit) != 0u) clip_cover = 1.0 - smoothstep(-caa, caa, cd);
        if (clip_cover <= 0.0) discard_fragment();
    }
    return clip_cover;
}

fragment float4 fs(VOut in [[stage_in]],
                   constant Instance *instances [[buffer(0)]],
                   texture2d<float> atlas [[texture(0)]],
                   texture2d<float> images [[texture(1)]]) {
    Instance i = instances[in.inst];
    float clip_cover = clip_coverage(in, i);
    return shade(in, i, atlas, images) * clip_cover;
}

static float4 shade(VOut in, Instance i, texture2d<float> atlas, texture2d<float> images) {
    if (i.kind == 1.0) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float a = atlas.sample(s, in.uv).r * i.color.a;
        return float4(i.color.rgb * a, a);
    }

    float2 half_size = i.rect.zw * 0.5;
    float2 p = in.local - half_size;
    float r = min(i.radius, min(half_size.x, half_size.y));
    float d = rounded_box(p, half_size, r);

    if (i.kind == 3.0) {
        // Premultiplied already: scaled by the corners' coverage and opacity.
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float aa = max(fwidth(d), 0.0001) * 0.5;
        float coverage = 1.0 - smoothstep(-aa, aa, d);
        float4 px = images.sample(s, in.uv);
        // Tinted: the picture's shape in one color (a mark following the theme).
        if (i.border_color.a > 0.0) {
            float a = px.a * i.border_color.a * coverage * i.color.a;
            return float4(i.border_color.rgb * a, a);
        }
        return px * (coverage * i.color.a);
    }

    if (i.kind == 2.0) {
        float sigma = max(i.border_width, 0.25);
        float a = shadow_alpha(p, half_size, r, sigma) * i.color.a;
        return float4(i.color.rgb * a, a);
    }

    float aa = max(fwidth(d), 0.0001) * 0.5;
    float coverage = 1.0 - smoothstep(-aa, aa, d);
    float4 c = i.color;
    if (i.border_width > 0.0 && i.border_color.a > 0.0) {
        float inner = smoothstep(-i.border_width - aa, -i.border_width + aa, d);
        c = mix(c, i.border_color, inner);
    }
    float a = c.a * coverage;
    return float4(c.rgb * a, a);
}
