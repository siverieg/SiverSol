/// The Sol Dex card face, as one Metal fragment shader: a deep tinted ground, an emblem that is different for
/// every aura (drawn from a number made of its name, no game art), and a foil that climbs with the tier:
/// matte, satin sheen, shimmer, holographic bands, glitter, and a flowing prismatic foil that follows the pointer.
/// Original work, written for SiverSol. Like the sky it is compiled when the app starts.
enum FoilShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct FU {
    float4 sizeTime;   // width px, height px, time s, foil level 0..5
    float4 tintA;      // top colour, seen 0/1
    float4 tintB;      // bottom colour, seed 0..1
    float4 tilt;       // x, y (-1..1), scale (px per point), animated 0/1
};

struct FVOut { float4 pos [[position]]; };

vertex FVOut foil_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FVOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;
}

static float fh21(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
static float2 fh22(float2 p) { float n = fh21(p); return float2(n, fh21(p + n + 17.17)); }
static float fnoise(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(fh21(i), fh21(i + float2(1, 0)), f.x), mix(fh21(i + float2(0, 1)), fh21(i + float2(1, 1)), f.x), f.y);
}
static float ffbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * fnoise(p); p = p * 2.03 + float2(17.3, 9.1); a *= 0.5; }
    return v;
}
static float3 rainbow(float x) { return 0.5 + 0.5 * cos(6.2831853 * (x + float3(0.0, 0.33, 0.67))); }

fragment float4 foil_fragment(FVOut in [[stage_in]], constant FU &u [[buffer(0)]]) {
    float scale = max(u.tilt.z, 0.25);
    float2 p = in.pos.xy / scale;
    float2 size = u.sizeTime.xy / scale;
    float2 uv = p / size;
    int level = int(u.sizeTime.w + 0.5);
    float seen = u.tintA.w, seed = u.tintB.w;
    float anim = u.tilt.w;
    float t = anim > 0.5 ? u.sizeTime.z : 3.7;
    float2 tilt = u.tilt.xy;
    float3 a = u.tintA.rgb, b = u.tintB.rgb;

    // The ground: deep enough that white text reads on every tier.
    float3 col = mix(a * 0.46, b * 0.20, smoothstep(0.0, 1.0, uv.y));
    col += a * 0.10 * (1.0 - uv.y);
    float2 e = uv - 0.5;
    col *= 1.0 - 0.55 * dot(e, e);

    // The emblem: a rosette whose number of points, lean and inner cut come from the aura's own number.
    float2 c = float2(0.5, 0.40);
    float2 q = (uv - c) * float2(size.x / size.y, 1.0);
    float r = length(q); float ang = atan2(q.y, q.x);
    float n = 3.0 + floor(seed * 6.999);
    float h2 = fract(seed * 7.31), h3 = fract(seed * 13.7), h4 = fract(seed * 29.3);
    float petal = 0.150 + 0.045 * cos(n * ang + h2 * 6.2831853) + 0.018 * cos(2.0 * n * ang + h3 * 6.2831853);
    float shape = smoothstep(petal + 0.004, petal - 0.004, r);
    float inner = smoothstep(petal * (0.45 + 0.2 * h4) + 0.004, petal * (0.45 + 0.2 * h4) - 0.004, r);
    float core = smoothstep(0.034 + 0.012 * h3, 0.022 + 0.012 * h3, r);
    float ring = smoothstep(1.6 / size.y, 0.0, abs(r - 0.218));
    float emblem = clamp(shape - inner * 0.6 + core, 0.0, 1.0);

    if (seen < 0.5) {
        // Not seen yet: a dark card with the emblem as a silhouette.
        float3 dark = mix(float3(0.060, 0.066, 0.084), float3(0.030, 0.033, 0.045), uv.y);
        dark *= 1.0 - 0.5 * dot(e, e);
        dark = mix(dark, float3(0.125, 0.135, 0.165), emblem * 0.9);
        dark += float3(0.10, 0.11, 0.14) * ring * 0.5;
        float2 bq0 = abs(p - size * 0.5) - (size * 0.5 - 17.0);
        float sd0 = length(max(bq0, 0.0)) - 10.0;
        dark += float3(0.16, 0.17, 0.2) * smoothstep(1.2, 0.0, abs(sd0)) * 0.5;
        dark += (fh21(p) - 0.5) / 255.0;
        return float4(dark, 1.0);
    }

    float d = uv.x * 0.9 + uv.y * 1.15 + tilt.x * 0.35 - tilt.y * 0.20;
    // The foil is strongest around the emblem and calmer at the foot of the card, where the words go.
    float foilMask = (1.0 - emblem * 0.55) * mix(1.0, 0.38, smoothstep(0.52, 0.86, uv.y));
    float3 foil = float3(0.0);

    if (level == 0) {                       // matte: a little tooth, like card stock
        foil += (fnoise(p * 1.7) - 0.5) * 0.035;
    }
    if (level >= 1) {                       // satin: one soft band of light
        float sheen = exp(-pow((d - 0.95 - 0.22 * sin(t * 0.4) * anim) / 0.17, 2.0));
        foil += float3(1.0) * sheen * (level == 1 ? 0.16 : 0.09);
    }
    if (level >= 2) {                       // shimmer: fine sparks
        float2 cell = floor(p / 7.0);
        float h = fh21(cell + seed * 91.0);
        float2 cc = (fract(p / 7.0) - (0.25 + 0.5 * fh22(cell + 3.0))) * 7.0;
        float tw = anim > 0.5 ? 0.5 + 0.5 * sin(t * 2.5 + h * 40.0) : 0.8;
        foil += float3(1.0) * step(0.955, h) * smoothstep(2.6, 0.0, length(cc)) * 0.60 * tw;
    }
    if (level >= 3) {                       // holographic: bands of spectrum across the card
        float bands = 0.5 + 0.5 * sin(d * (level >= 4 ? 58.0 : 44.0));
        foil += rainbow(d * 2.2 + t * 0.05 * anim) * (0.05 + 0.10 * bands);
    }
    if (level >= 4) {                       // glitter: tiny facets that catch the light as it moves
        float2 cell = floor(p / 4.5);
        float2 hn = fh22(cell + seed * 17.0) * 2.0 - 1.0;
        float3 nrm = normalize(float3(hn * 0.9, 0.55));
        float3 light = normalize(float3(tilt.x * 0.9 + 0.3 * sin(t * 0.7) * anim, tilt.y * 0.9 + 0.25 * cos(t * 0.5) * anim, 1.0));
        float g = pow(max(dot(nrm, light), 0.0), 34.0);
        float round = smoothstep(2.3, 0.6, length((fract(p / 4.5) - 0.5) * 4.5));
        foil += mix(float3(1.0), rainbow(fh21(cell) + d), 0.7) * g * round * 0.95;
    }
    if (level >= 5) {                       // prismatic: the whole card flows, and a bar of light follows the pointer
        float w = ffbm(uv * 3.0 + float2(t * 0.08, -t * 0.05) + tilt * 0.4);
        foil += rainbow(w * 1.6 + d * 1.2) * 0.22;
        float bar = exp(-pow((uv.x + uv.y * 0.4 - 0.7 - tilt.x * 0.6 - 0.28 * sin(t * 0.6) * anim) / 0.075, 2.0));
        foil += float3(1.0) * bar * 0.24;
    }
    col += foil * foilMask;
    col *= mix(1.0, 0.72, smoothstep(0.60, 1.0, uv.y));

    // The emblem on top, lit from the tier colour.
    float3 emblemCol = mix(a, float3(1.0), 0.58) * (0.82 + 0.18 * cos(ang * n + h2 * 6.2831853));
    if (level >= 3) emblemCol = mix(emblemCol, rainbow(d * 1.4 + r * 2.0) * 0.6 + 0.5, 0.28);
    col += a * exp(-r / 0.13) * 0.34;
    col = mix(col, emblemCol, emblem);
    col += float3(1.0) * ring * 0.26;

    // A fine frame inside the edge; it turns from grey to gold to spectrum as the tier climbs.
    float2 bq = abs(p - size * 0.5) - (size * 0.5 - 17.0);
    float sd = length(max(bq, 0.0)) - 10.0;
    float line = smoothstep(1.2, 0.0, abs(sd));
    float3 frame = level >= 5 ? rainbow(d * 1.5 + t * 0.1 * anim) * 0.7 + 0.4 : (level >= 3 ? float3(1.0, 0.86, 0.52) : float3(0.82, 0.86, 0.92));
    col += frame * line * (0.30 + 0.07 * float(level));

    col += (fh21(p + 3.0) - 0.5) / 255.0;
    return float4(clamp(col, 0.0, 1.0), 1.0);
}
"""#
}
