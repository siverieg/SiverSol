/// The Living Sky, as one Metal fragment shader. Original work, written for SiverSol: every scene is drawn from
/// noise and simple shapes, with no images.
///
/// It is kept as source text and compiled when the app starts, so building SiverSol needs no extra Metal tools.
/// All distances are in points; the vertex stage passes pixels and the fragment stage divides by the scale.
/// `weather()` switches on `SkyWeather.index`: keep the two in the same order.
enum SkyShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct U {
    float4 sizeTime;   // width px, height px, time s, mix 0..1 (previous sky -> current sky)
    float4 topA; float4 botA; float4 topB; float4 botB;
    float4 accA; float4 accB; float4 parA; float4 parB;
    float4 misc;       // weatherA, weatherB, night 0..1, motion 0/1
    float4 arc;        // centre x, centre y, radius, half angle (points; radius <= 0 hides the arc)
    float4 body;       // progress 0..1, kind (0 none, 1 sun, 2 moon, 3 marker), radius, rare 0/1
    float4 fx;         // shockwave 0..1 (below 0: none), scale (px per point), unused, unused
    float4 ink;        // colour of the arc line
    // Rare sky surprises. All zero (and star, fireworks below 0) draws exactly the ordinary sky.
    float4 eggA;       // shooting star 0..1 (below 0: none), rainbow 0..1, aurora 0..1, retro frame 0..1
    float4 eggB;       // golden sun 0..1, twin moon 0..1, bats 0..1, fireworks seconds (below 0: none)
};

struct VOut { float4 pos [[position]]; };

vertex VOut sky_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;
}

static float hash11(float n) { return fract(sin(n * 127.1 + 1.7) * 43758.5453123); }
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y);
}
static float2 hash22(float2 p) { float n = hash21(p); return float2(n, hash21(p + n + 17.17)); }
static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * vnoise(p); p = p * 2.03 + float2(17.3, 9.1); a *= 0.5; }
    return v;
}

static float stars(float2 p, float t, float density) {
    float2 g = p / 46.0; float2 id = floor(g); float2 f = fract(g);
    float h = hash21(id);
    if (h > density) return 0.0;
    float2 c = 0.15 + 0.7 * hash22(id + 3.1);
    float d = length((f - c) * 46.0);
    float tw = 0.65 + 0.35 * sin(t * (0.6 + h * 5.0) + h * 40.0);
    float r = 0.7 + 1.0 * hash21(id + 9.7);
    return smoothstep(r, 0.0, d) * tw;
}

// A field of soft dots, one per cell at most. `stretch` below 1 on an axis draws them longer on that axis.
static float dots(float2 p, float cell, float rmin, float rmax, float keep, float seed, float2 stretch) {
    float2 g = p / cell; float2 id = floor(g); float2 f = fract(g);
    float h = hash21(id + seed);
    if (h > keep) return 0.0;
    float2 c = 0.25 + 0.5 * hash22(id + seed + 5.5);
    float2 dv = (f - c) * cell * stretch;
    float r = mix(rmin, rmax, hash21(id + seed + 1.3));
    return smoothstep(r, r * 0.25, length(dv));
}

static float bat(float2 q, float flap) {
    float x = abs(q.x);
    if (x > 2.1 || abs(q.y) > 1.7) return 0.0;
    float yt = -0.10 - 0.42 * sin(min(x, 2.0) * 0.72) - flap * 0.36 * x;          // top edge of the wing
    float thick = 0.72 * (1.0 - x / 2.0);
    float yb = yt + thick + 0.13 * abs(sin(x * 4.712)) * step(0.25, x);            // scalloped lower edge
    float wing = smoothstep(yt - 0.05, yt + 0.05, q.y) * smoothstep(yb + 0.05, yb - 0.05, q.y) * step(x, 2.0);
    float body = smoothstep(1.05, 0.9, length(float2(q.x / 0.24, (q.y - 0.12) / 0.5)));
    float ear = step(-0.66 + abs(x - 0.14) * 3.2, q.y) * step(q.y, -0.25) * step(x, 0.3);
    return max(wing, max(body, ear));
}

// 4x4 ordered dither threshold in 0..1, for the retro frame.
static float bayer4(float2 c) {
    int x = int(fmod(c.x, 4.0)), y = int(fmod(c.y, 4.0));
    const float mtx[16] = { 0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0 };
    return (mtx[y * 4 + x] + 0.5) / 16.0;
}

// A spectrum band: 0 = red (outside of a rainbow) to 1 = violet.
static float3 spectrum(float h) {
    return clamp(float3(1.6 - 3.2 * abs(h - 0.12), 1.5 - 3.4 * abs(h - 0.45), 1.6 - 3.4 * abs(h - 0.82)), 0.0, 1.0);
}

static float3 weather(int id, float3 col, float2 p, float2 size, float t, float m, float amt, float night,
                      float3 acc, float3 par, float2 bodyPos, float hasBody) {
    if (amt <= 0.001) return col;
    switch (id) {
    case 0: {   // clouds: the plain sky
        float n = fbm(float2(p.x * 0.0021 + t * 0.011, p.y * 0.0052 + 3.0));
        float n2 = fbm(float2(p.x * 0.0045 - t * 0.017, p.y * 0.011 + 9.0));
        float band = smoothstep(0.80 * size.y, 0.05 * size.y, p.y);
        float c = smoothstep(0.40, 0.74, n * 0.7 + n2 * 0.3) * band;
        float3 cc = mix(float3(1.0), float3(0.52, 0.60, 0.86), night);
        col += stars(p, t, 0.55) * night * amt * 0.85 * (1.0 - c);
        col = mix(col, cc, c * mix(0.62, 0.20, night) * amt);
        break;
    }
    case 1: {   // wind: fast cloud and long streaks
        float n = fbm(float2(p.x * 0.0024 + t * 0.05, p.y * 0.006 + 3.0));
        float c = smoothstep(0.5, 0.8, n) * smoothstep(0.8 * size.y, 0.0, p.y);
        col += stars(p, t, 0.4) * night * amt * 0.6 * (1.0 - c);
        col = mix(col, mix(float3(1.0), float3(0.52, 0.60, 0.86), night), c * mix(0.34, 0.14, night) * amt);
        if (m > 0.5) {
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float speed = 250.0 + 150.0 * fi;
                float2 q = float2(p.x - t * speed, p.y + sin(p.x * 0.004 + fi * 2.0 + t * 0.7) * 14.0);
                float2 cell = float2(540.0 - 90.0 * fi, 46.0 + 12.0 * fi);
                float2 cid = floor(q / cell); float2 f = fract(q / cell);
                float on = step(hash21(cid + fi * 31.0), 0.42);
                float len = smoothstep(0.0, 0.25, f.x) * smoothstep(0.98, 0.45, f.x);
                float cy = 0.25 + 0.5 * hash21(cid + 7.0);
                float thick = exp(-pow((f.y - cy) * cell.y / (0.9 + 0.4 * fi), 2.0));
                col = mix(col, par, on * len * thick * mix(0.5, 0.28, night) * amt);
            }
        }
        break;
    }
    case 2: case 16: {   // rain, and blood rain (the same fall in the biome's own colour)
        float deck = fbm(float2(p.x * 0.003 + t * 0.02, p.y * 0.006));
        col = mix(col, col * 0.74, smoothstep(0.3, 0.8, deck) * 0.7 * amt);
        if (m > 0.5) {
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float w = 15.0 + 10.0 * fi, hgt = 170.0 + 70.0 * fi;
                float qx = p.x + p.y * 0.16;
                float cid = floor(qx / w);
                float h = hash11(cid + fi * 57.0);
                float speed = 760.0 + 420.0 * h + 150.0 * fi;
                float y = (p.y - t * speed) / hgt + h * 13.0;
                float fy = fract(y);
                float on = step(hash21(float2(cid, floor(y)) + fi), 0.5);
                float fx = fract(qx / w);
                float line = exp(-pow((fx - 0.5) * w / (0.6 + 0.3 * fi), 2.0));
                float len = smoothstep(0.06, 0.44, fy) * step(fy, 0.45);
                col = mix(col, par, on * line * len * (0.55 - 0.1 * fi) * amt);
            }
        }
        break;
    }
    case 3: {   // snow
        float n = fbm(float2(p.x * 0.0022 + t * 0.006, p.y * 0.005));
        col = mix(col, mix(float3(1.0), float3(0.6, 0.68, 0.9), night), smoothstep(0.5, 0.85, n) * 0.22 * amt);
        col = mix(col, mix(float3(1.0), float3(0.6, 0.68, 0.9), night), 0.16 * amt * smoothstep(0.5 * size.y, size.y, p.y));
        if (m > 0.5) {
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float cell = 56.0 + 40.0 * fi, speed = 30.0 + 22.0 * fi;
                float2 q = float2(p.x + sin(t * 0.5 + fi * 2.0 + p.y * 0.01) * 16.0 + fi * 91.0, p.y - t * speed);
                float a = dots(q, cell, 1.1 + 0.5 * fi, 2.1 + 1.1 * fi, 0.78, fi * 13.0, float2(1.0, 1.0));
                col = mix(col, par, a * (0.92 - 0.14 * fi) * amt);
            }
        }
        break;
    }
    case 4: {   // sand storm: haze and blown grains
        float haze = fbm(float2(p.x * 0.0030 - t * 0.10, p.y * 0.0050 + t * 0.01));
        col = mix(col, par * mix(1.0, 0.5, night), smoothstep(0.3, 0.85, haze) * 0.42 * amt);
        if (m > 0.5) {
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float2 q = float2(p.x - t * (520.0 + 260.0 * fi), p.y + sin(p.x * 0.006 + t) * 10.0 - t * 12.0 + fi * 77.0);
                float a = dots(q, 42.0 + 26.0 * fi, 0.8, 1.6, 0.82, fi * 7.0, float2(0.2, 1.0));
                col = mix(col, par * mix(1.06, 0.7, night), a * 0.6 * amt);
            }
        }
        break;
    }
    case 5: {   // embers: firelight from below, sparks rising
        float glow = pow(clamp(p.y / size.y, 0.0, 1.0), 2.6);
        float fl = 0.75 + 0.25 * fbm(float2(p.x * 0.006, t * 0.5));
        col += acc * glow * fl * 0.42 * amt;
        float sh = sin(p.y * 0.045 - t * 1.6 + fbm(float2(p.x * 0.004, p.y * 0.004 + t * 0.2)) * 7.0);
        col += acc * sh * 0.035 * glow * amt;
        if (m > 0.5) {
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float cell = 64.0 + 30.0 * fi;
                float2 q = float2(p.x + sin(t * 0.9 + p.y * 0.02 + fi) * 18.0 + fi * 53.0, p.y + t * (46.0 + 30.0 * fi));
                float a = dots(q, cell, 1.0, 2.3, 0.62, fi * 5.0, float2(1.0, 1.0));
                float flick = 0.6 + 0.4 * sin(t * 7.0 + hash21(floor(q / cell)) * 40.0);
                float fade = smoothstep(0.04 * size.y, 0.6 * size.y, p.y);
                col += par * a * flick * fade * 0.95 * amt;
            }
        }
        break;
    }
    case 6: {   // starfall
        col += stars(p, t, 0.85) * amt * 0.9;
        col += stars(p * 1.7 + 40.0, t, 0.5) * amt * 0.45;
        if (m > 0.5) {
            float2 dir = normalize(float2(-0.86, 0.50));
            for (int i = 0; i < 5; i++) {
                float fi = float(i);
                float period = 2.6 + 1.7 * hash11(fi + 2.0);
                float tt = t / period + hash11(fi) * 10.0;
                float epoch = floor(tt); float ph = fract(tt) * period / 0.9;
                if (ph < 1.0) {
                    float2 start = float2(hash21(float2(epoch, fi)) * size.x * 1.1 + 0.1 * size.x,
                                          hash21(float2(fi, epoch) + 3.3) * size.y * 0.45 - 20.0);
                    float travel = 420.0 + 240.0 * hash11(epoch + fi);
                    float2 head = start + dir * travel * ph;
                    float2 d = p - head;
                    float along = dot(d, -dir);
                    float across = length(d + dir * along);
                    float a = step(0.0, along) * smoothstep(150.0, 0.0, along) * exp(-across * across / 2.2);
                    a += exp(-dot(d, d) / 14.0);
                    float fade = smoothstep(0.0, 0.15, ph) * smoothstep(1.0, 0.7, ph);
                    col += mix(par, acc, 0.25) * a * fade * amt;
                }
            }
        }
        break;
    }
    case 7: {   // heaven: slow rays of light and a bank of cloud
        float2 o = float2(size.x * 0.22, -size.y * 0.35);
        float2 d = p - o; float ang = atan2(d.y, d.x);
        float rays = vnoise(float2(ang * 14.0 + t * 0.03, 1.5)) * 0.6 + vnoise(float2(ang * 37.0 - t * 0.021, 7.5)) * 0.4;
        rays = smoothstep(0.42, 0.9, rays);
        float fall = exp(-length(d) / (size.y * 1.6));
        col += mix(float3(1.0, 0.96, 0.82), float3(0.75, 0.74, 0.62), night) * rays * fall * mix(0.42, 0.3, night) * amt;
        float n = fbm(float2(p.x * 0.0025 + t * 0.008, p.y * 0.006));
        col = mix(col, mix(float3(1.0), float3(0.72, 0.70, 0.6), night),
                  smoothstep(0.45, 0.85, n) * smoothstep(0.45 * size.y, size.y, p.y) * 0.5 * amt);
        break;
    }
    case 8: {   // corruption: pulsing veins and dark spores
        float2 vp = p * 0.0042 + float2(0.0, t * 0.004);
        float v = abs(fbm(vp + fbm(vp * 1.7) * 0.8) - 0.5);
        float vein = smoothstep(0.035, 0.0, v);
        float edge = smoothstep(0.25, 0.9, length((p - size * 0.5) / size) * 1.5);
        float pulse = 0.65 + 0.35 * sin(t * 0.8 + p.x * 0.004);
        col += acc * vein * (0.25 + 0.75 * edge) * pulse * 0.55 * amt;
        if (m > 0.5) {
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float2 q = float2(p.x + sin(t * 0.35 + fi * 1.7 + p.y * 0.008) * 22.0 + fi * 61.0, p.y + t * (10.0 + 7.0 * fi));
                float a = dots(q, 72.0 + 34.0 * fi, 1.6, 3.4 + fi, 0.7, fi * 11.0, float2(1.0, 1.0));
                col = mix(col, mix(float3(0.03, 0.0, 0.06), par, 0.22 * fi), a * 0.72 * amt);
            }
        }
        break;
    }
    case 9: {   // null: a void with sparse static
        float vig = length((p - size * 0.5) / size);
        col *= 1.0 - 0.5 * vig * amt;
        if (m > 0.5) {
            float2 cid = floor(p / 3.0);
            float h = hash21(cid + floor(t * 6.0) * 1.37);
            col += par * step(0.9972, h) * 0.5 * amt;
            float ly = fract(t * 0.07) * size.y;
            col += par * exp(-abs(p.y - ly) / 1.2) * 0.07 * hash21(float2(floor(p.x / 2.0), floor(t * 12.0))) * amt;
        }
        break;
    }
    case 10: {  // glitched: scanlines, small colour-split tears, a block that jumps. Small areas, never a flash.
        float2 gc = floor(p / float2(26.0, 14.0));
        float gh = hash21(gc + floor(t * 0.5) * 3.1);
        col += acc * step(0.93, gh) * 0.10 * amt;
        col *= 1.0 - 0.10 * amt * (0.5 + 0.5 * sin((p.y + t * 12.0 * m) * 1.5708));
        if (m > 0.5) {
            for (int i = 0; i < 4; i++) {
                float fi = float(i);
                float ep = floor(t * 1.6 + fi * 0.37);
                float life = fract(t * 1.6 + fi * 0.37);
                float on = step(hash21(float2(ep, fi)), 0.45) * step(life, 0.55);
                float by = hash21(float2(ep, fi + 5.0)) * size.y;
                float bh = 3.0 + 9.0 * hash21(float2(ep, fi + 9.0));
                float bx = hash21(float2(ep, fi + 13.0)) * size.x;
                float bw = 40.0 + 130.0 * hash21(float2(ep, fi + 17.0));
                float inBand = step(abs(p.y - by), bh) * step(abs(p.x - bx), bw);
                float sh = 7.0 + 9.0 * hash21(float2(ep, fi + 21.0));
                float pr = step(0.55, hash21(floor(float2(p.x - sh, p.y) / float2(34.0, bh * 2.0)) + ep));
                float pc = step(0.55, hash21(floor(float2(p.x + sh, p.y) / float2(34.0, bh * 2.0)) + ep));
                col = mix(col, max(par * pr, acc * pc), on * inBand * max(pr, pc) * 0.42 * amt);
            }
            float ep = floor(t * 0.9); float life = fract(t * 0.9);
            float2 bc = float2(hash21(float2(ep, 1.0)), hash21(float2(ep, 2.0))) * size;
            float2 bs = float2(24.0 + 60.0 * hash21(float2(ep, 3.0)), 8.0 + 16.0 * hash21(float2(ep, 4.0)));
            float blk = step(abs(p.x - bc.x), bs.x) * step(abs(p.y - bc.y), bs.y) * step(life, 0.35) * step(hash21(float2(ep, 5.0)), 0.6);
            col = mix(col, acc * 0.55, blk * 0.4 * amt);
        }
        break;
    }
    case 11: {  // dreamspace: slow pastel light and floating stars
        float2 q = p * 0.0016;
        float a1 = fbm(q + float2(t * 0.012, 0.0) + fbm(q * 1.6 - t * 0.006) * 0.9);
        float a2 = fbm(q * 1.3 + float2(5.0, t * 0.010));
        float3 pastel = mix(float3(1.0, 0.80, 0.93), float3(0.74, 0.95, 0.90), a2);
        pastel = mix(pastel, float3(0.80, 0.78, 1.0), smoothstep(0.4, 0.7, a1));
        col = mix(col, pastel * mix(1.0, 0.42, night), smoothstep(0.35, 0.75, a1) * 0.55 * amt);
        if (m > 0.5) {
            for (int i = 0; i < 2; i++) {
                float fi = float(i);
                float cell = 120.0 + 60.0 * fi;
                float2 q2 = float2(p.x + sin(t * 0.2 + fi) * 20.0 + fi * 47.0, p.y + t * (6.0 + 4.0 * fi));
                float2 cid = floor(q2 / cell);
                float2 f = (fract(q2 / cell) - (0.25 + 0.5 * hash22(cid + fi))) * cell;
                float h = hash21(cid + fi * 3.0);
                float tw = 0.5 + 0.5 * sin(t * (0.8 + h * 1.5) + h * 30.0);
                float s = 5.0 + 6.0 * h;
                float star = max(0.0, 1.0 - (abs(f.x) * abs(f.y)) / (s * 0.3)) * smoothstep(s * 1.6, 0.0, length(f));
                col += float3(1.0) * star * tw * step(h, 0.6) * 0.85 * amt;
            }
        } else {
            col += stars(p, t, 0.3) * 0.5 * amt;
        }
        break;
    }
    case 12: {  // cyberspace: a neon grid running to the horizon
        float hz = size.y * 0.60;
        col += stars(p, t, 0.45) * step(p.y, hz) * 0.7 * amt;
        col += par * exp(-abs(p.y - hz) / 26.0) * 0.5 * amt;
        if (p.y > hz) {
            float H = size.y - hz;
            float dy = (p.y - hz) / H;
            float z = 1.0 / max(dy, 0.02);
            float gx = (p.x - size.x * 0.5) * z * 0.012;
            float gz = z * 1.6 + t * 0.9 * m;
            float lx = abs(fract(gx) - 0.5), lz = abs(fract(gz) - 0.5);
            float line = max(smoothstep(1.4, 0.0, lx / (z * 0.012)), smoothstep(1.4, 0.0, lz * H / (1.6 * z * z)));
            float fade = smoothstep(0.05, 0.42, dy);
            col = mix(col, col * 0.5, amt * 0.6);
            col += acc * line * fade * 0.85 * amt;
        }
        break;
    }
    case 13: {  // singularity: matter winding into a dark centre
        float2 c = float2(size.x - size.y * 0.20 - 40.0, size.y * 0.30);
        float2 d = (p - c) / size.y; float r = length(d); float ang = atan2(d.y, d.x);
        float r0 = 0.085;
        float tw = ang + 0.9 / (r + 0.08) - t * 0.10 * m;
        float arms = fbm(float2(cos(tw) * 1.6 + 3.0, sin(tw) * 1.6 + 3.0) + log(r + 0.02) * 1.5 - t * 0.05 * m);
        col += stars(p, t, 0.4) * smoothstep(0.15, 0.5, r) * 0.6 * amt;
        col += mix(acc, par, smoothstep(0.3, 0.0, r)) * pow(arms, 2.0) * smoothstep(0.75, 0.0, r) * 0.9 * amt;
        float ring = exp(-pow((r - r0 * 1.25) / 0.012, 2.0));
        col += par * ring * (0.7 + 0.3 * sin(ang * 3.0 + t * 0.8)) * 0.8 * amt;
        col = mix(col, float3(0.0), smoothstep(r0 * 1.12, r0 * 0.92, r) * amt);
        break;
    }
    case 14: {  // pumpkin moon: a big orange moon, thin cloud and bats
        col += stars(p, t, 0.4) * 0.5 * amt;
        float mr = min(size.x, size.y) * 0.125;
        float2 mc = float2(size.x - mr - 34.0, size.y * 0.26);
        float md = length(p - mc);
        float crater = fbm((p - mc) / mr * 2.4 + 4.0);
        float3 mcol = mix(acc * 1.05, acc * 0.70, smoothstep(0.4, 0.75, crater));
        mcol *= 1.0 - 0.35 * smoothstep(0.2, 1.0, md / mr);
        col += acc * exp(-max(md - mr, 0.0) / (mr * 0.9)) * 0.32 * amt;
        col = mix(col, mcol, smoothstep(mr + 1.0, mr - 1.0, md) * amt);
        float n = fbm(float2(p.x * 0.003 + t * 0.015, p.y * 0.012));
        col = mix(col, float3(0.05, 0.03, 0.06), smoothstep(0.55, 0.85, n) * 0.5 * amt);
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float h = hash11(fi + 1.0);
            float2 bc = mc + float2(cos(t * (0.11 + 0.05 * h) * m + fi * 1.9) * mr * (1.2 + 0.6 * h),
                                    sin(t * (0.17 + 0.04 * h) * m + fi * 2.7) * mr * (0.8 + 0.5 * h)) + float2(-mr * 0.2, mr * 0.2);
            float s = 8.0 + 7.0 * h;
            float flap = sin(t * (9.0 + 3.0 * h) * m + fi);
            col = mix(col, float3(0.02, 0.01, 0.03), bat((p - bc) / s, flap) * amt);
        }
        break;
    }
    case 15: {  // graveyard: stones on a low hill, fog drifting over them
        col += stars(p, t, 0.25) * night * 0.4 * amt;
        float cellW = 132.0; float sid = floor(p.x / cellW); float h = hash11(sid + 4.0);
        float lx = (fract(p.x / cellW) - (0.3 + 0.4 * h)) * cellW;
        float sw = 12.0 + 8.0 * hash11(sid + 8.0), shh = 30.0 + 26.0 * hash11(sid + 12.0);
        float ground = size.y - 50.0 - 16.0 * vnoise(float2(p.x * 0.006, 2.0));
        float gy = size.y - 50.0 - 16.0 * vnoise(float2((p.x - lx) * 0.006, 2.0));
        float top = gy - shh;
        float slab = step(abs(lx), sw) * step(top + sw, p.y) * step(p.y, gy + 6.0);
        float cap = step(length(float2(lx, p.y - (top + sw))), sw);
        float vbar = step(abs(lx), 3.2) * step(top, p.y) * step(p.y, gy + 6.0);
        float hbar = step(abs(lx), sw * 0.85) * step(abs(p.y - (top + shh * 0.3)), 3.2);
        float stone = (h > 0.66 ? max(vbar, hbar) : max(slab, cap)) * step(hash11(sid + 20.0), 0.8);
        float sil = max(smoothstep(ground - 1.0, ground + 1.0, p.y), stone);
        col = mix(col, mix(col, float3(0.02, 0.025, 0.03), 0.88), sil * amt);
        float f1 = fbm(float2(p.x * 0.0026 + t * 0.018, p.y * 0.008));
        float f2 = fbm(float2(p.x * 0.004 - t * 0.012, p.y * 0.011 + 4.0));
        float fogMask = smoothstep(size.y * 0.30, size.y, p.y);
        col = mix(col, par * mix(0.9, 0.42, night), (smoothstep(0.3, 0.8, f1) * 0.5 + smoothstep(0.35, 0.85, f2) * 0.35) * fogMask * amt);
        break;
    }
    case 17: {  // aurora: curtains of light, bright at the hem and fading upward
        col += stars(p, t, 0.6) * 0.8 * amt;
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float x = p.x * (0.0016 + 0.0006 * fi) + fi * 3.7;
            float wave = fbm(float2(x + t * 0.020, fi + t * 0.012));
            float base = size.y * (0.34 + 0.10 * fi) + (wave - 0.5) * size.y * 0.34;
            float above = base - p.y;
            float band = above > 0.0 ? exp(-above / (size.y * (0.20 + 0.05 * fi))) : exp(-pow(above / 28.0, 2.0));
            float gaps = smoothstep(0.30, 0.62, fbm(float2(x * 2.3 - t * 0.015, fi * 7.0 + 2.0)));
            float stri = 0.45 + 0.55 * vnoise(float2(p.x * 0.11 + wave * 9.0 + fi * 20.0, t * 0.25));
            float3 ac = mix(acc, par, smoothstep(0.0, size.y * 0.3, above));
            col += ac * band * gaps * stri * (0.55 - 0.1 * fi) * amt;
        }
        break;
    }
    case 18: {  // forest: light through the canopy, pines, fireflies
        float2 o = float2(size.x * 0.3, -size.y * 0.3); float2 d = p - o; float ang = atan2(d.y, d.x);
        float rays = smoothstep(0.5, 0.95, vnoise(float2(ang * 18.0 + t * 0.02, 3.0)));
        col += par * rays * exp(-length(d) / (size.y * 1.4)) * 0.24 * amt * (1.0 - night * 0.7);
        for (int i = 1; i >= 0; i--) {
            float fi = float(i);
            float cw = 64.0 + 40.0 * fi;
            float tid = floor((p.x + fi * 37.0) / cw);
            float f = fract((p.x + fi * 37.0) / cw) - 0.5;
            float hgt = (80.0 + 70.0 * hash11(tid + fi * 9.0)) * (1.0 + 0.5 * fi);
            float yy = (size.y + 6.0 - p.y) / hgt;
            float tier = fract(yy * 3.0);
            float w = (1.0 - yy) * 0.5 * (0.55 + 0.45 * (1.0 - tier));
            float tree = step(0.0, yy) * step(yy, 1.0) * smoothstep(w + 0.02, w - 0.02, abs(f));
            col = mix(col, mix(float3(0.01, 0.05, 0.03), col, 0.12 + 0.3 * fi), tree * amt);
        }
        if (m > 0.5) {
            for (int i = 0; i < 2; i++) {
                float fi = float(i);
                float cell = 96.0 + 40.0 * fi;
                float2 q = float2(p.x + sin(t * 0.3 + p.y * 0.01 + fi * 2.0) * 26.0 + fi * 39.0, p.y + cos(t * 0.23 + fi) * 14.0 + t * 4.0);
                float a = dots(q, cell, 1.3, 2.4, 0.5, fi * 17.0, float2(1.0, 1.0));
                float pulse = 0.5 + 0.5 * sin(t * 1.7 + hash21(floor(q / cell)) * 30.0);
                col += par * a * pulse * 0.9 * amt;
            }
        }
        break;
    }
    case 19: {  // blazing sun: a great sun with slow rays, and heat rising
        float2 sc = hasBody > 0.5 ? bodyPos : float2(size.x - min(size.x, size.y) * 0.11 - 50.0, size.y * 0.24);
        float sr = hasBody > 0.5 ? 20.0 : min(size.x, size.y) * 0.11;
        float2 d = p - sc; float sd = length(d); float ang = atan2(d.y, d.x);
        float rays = pow(0.5 + 0.5 * sin(ang * 14.0 + t * 0.15), 3.0);
        float day = 1.0 - night * 0.85;
        col += float3(1.0, 0.95, 0.75) * rays * exp(-max(sd - sr, 0.0) / (sr * 2.4 + 60.0)) * 0.32 * amt * day;
        col += float3(1.0, 0.9, 0.6) * exp(-max(sd - sr, 0.0) / (sr * 0.8 + 30.0)) * 0.4 * amt * day;
        if (hasBody < 0.5) col = mix(col, float3(1.0, 0.98, 0.88), smoothstep(sr + 1.0, sr - 1.0, sd) * amt);
        float sh = sin(p.y * 0.05 - t * 1.4 + fbm(float2(p.x * 0.004, t * 0.15)) * 6.0);
        col += acc * sh * 0.03 * smoothstep(0.4 * size.y, size.y, p.y) * amt;
        break;
    }
    default: break;
    }
    return col;
}

fragment float4 sky_fragment(VOut in [[stage_in]], constant U &u [[buffer(0)]]) {
    float scale = max(u.fx.y, 0.25);
    float2 p = in.pos.xy / scale;
    float2 size = u.sizeTime.xy / scale;
    // Retro frame: the whole sky is drawn in big square pixels.
    float retro = u.eggA.w;
    float2 block = float2(0.0);
    if (retro > 0.5) { block = floor(p / 5.0); p = (block + 0.5) * 5.0; }
    float gold = u.eggB.x;
    float3 goldCol = float3(1.0, 0.80, 0.24);
    float m = u.misc.w;
    float t = m > 0.5 ? u.sizeTime.z : 12.34;
    float k = smoothstep(0.0, 1.0, u.sizeTime.w);
    float night = u.misc.z;

    float gy = clamp(p.y / size.y, 0.0, 1.0);
    float3 colA = mix(u.topA.rgb, u.botA.rgb, gy), colB = mix(u.topB.rgb, u.botB.rgb, gy);
    float3 col = mix(colA, colB, k);

    // The arc and where the sun or moon is on it.
    float R = u.arc.z; float phi = u.arc.w;
    float progAng = (2.0 * u.body.x - 1.0) * phi;
    float2 bodyPos = u.arc.xy + R * float2(sin(progAng), -cos(progAng));
    float hasBody = (R > 0.0 && u.body.y > 0.5) ? 1.0 : 0.0;

    // The old weather thins out and is blown along while the new one rolls in from the other side.
    col = weather(int(u.misc.x + 0.5), col, p - float2(k * size.x * 0.45, 0.0), size, t, m, 1.0 - k, night, u.accA.rgb, u.parA.rgb, bodyPos, hasBody);
    col = weather(int(u.misc.y + 0.5), col, p + float2((1.0 - k) * size.x * 0.30, 0.0), size, t, m, k, night, u.accB.rgb, u.parB.rgb, bodyPos, hasBody);

    if (R > 0.0) {
        float3 acc = mix(u.accA.rgb, u.accB.rgb, k);
        float2 d = p - u.arc.xy; float r = length(d);
        float off = atan2(d.y, d.x) + 1.5707963;
        off = off > 3.1415927 ? off - 6.2831853 : off;
        float inArc = smoothstep(phi + 0.012, phi - 0.004, abs(off));
        float line = smoothstep(1.5, 0.3, abs(r - R));
        float done = step(off, progAng);
        float3 lineCol = mix(u.ink.rgb, goldCol, gold * done);   // golden sun: the trail it has travelled goes gold
        col = mix(col, lineCol, line * inArc * mix(0.20, 0.62 + 0.25 * gold, done));
        if (u.body.w > 0.5) {   // a rare biome: the whole circle glows and breathes
            float pulse = m > 0.5 ? 0.5 + 0.5 * sin(u.sizeTime.z * 1.5) : 0.6;
            col += acc * exp(-abs(r - R) / 8.0) * (0.22 + 0.2 * pulse);
            col += acc * exp(-abs(r - R) / 1.6) * 0.35;
        }
        float bd = length(p - bodyPos); float bs = u.body.z;
        int kind = int(u.body.y + 0.5);
        if (kind == 1) {
            float3 sun = mix(mix(float3(1.0, 0.95, 0.72), acc, 0.12), goldCol, gold);
            col += sun * exp(-max(bd - bs, 0.0) / (bs * 2.6)) * 0.55;
            col += sun * exp(-max(bd - bs, 0.0) / (bs * 9.0)) * 0.14;
            col = mix(col, mix(float3(1.0, 0.97, 0.82), float3(1.0, 0.86, 0.36), gold), smoothstep(bs + 1.0, bs - 1.0, bd));
        } else if (kind == 2) {
            float3 moon = mix(float3(0.93, 0.95, 1.0), float3(1.0, 0.86, 0.42), gold);
            col += moon * exp(-max(bd - bs, 0.0) / (bs * 2.4)) * 0.30;
            float disc = smoothstep(bs + 1.0, bs - 1.0, bd);
            float shade = smoothstep(bs * 0.92 + 1.0, bs * 0.92 - 1.0, length(p - bodyPos - float2(bs * 0.48, -bs * 0.16)));
            col = mix(col, moon * 0.30, disc * 0.35);
            col = mix(col, moon, disc * (1.0 - shade));
        } else if (kind == 3) {
            col += u.ink.rgb * exp(-bd / (bs * 0.9)) * 0.7;
            col = mix(col, u.ink.rgb, smoothstep(bs * 0.45 + 1.0, bs * 0.45 - 1.0, bd));
        }
        if (gold > 0.0 && kind != 0) {   // golden sun: a few sparkles turning slowly around it
            for (int i = 0; i < 6; i++) {
                float fi = float(i);
                float a = fi * 1.0472 + (m > 0.5 ? u.sizeTime.z * 0.35 : 0.4);
                float rr = bs * (2.1 + 0.7 * sin(fi * 2.3 + (m > 0.5 ? u.sizeTime.z * 0.9 : 0.0)));
                float2 sp = bodyPos + rr * float2(cos(a), sin(a));
                float tw = m > 0.5 ? 0.55 + 0.45 * sin(u.sizeTime.z * 3.0 + fi * 1.9) : 0.8;
                float2 q = abs(p - sp);
                float spark = exp(-length(q) / 1.4) + 0.6 * exp(-(q.x * 3.0 + q.y * 0.35)) + 0.6 * exp(-(q.y * 3.0 + q.x * 0.35));
                col += goldCol * spark * tw * 0.55 * gold;
            }
        }
        if (u.fx.x >= 0.0) {   // one soft ring spreading from the body when a rare biome arrives
            float s = u.fx.x;
            float sr = s * size.x * 0.7;
            float ring = exp(-pow((bd - sr) / (12.0 + 40.0 * s), 2.0)) * (1.0 - s) * (1.0 - s);
            col += acc * ring * 0.20;
        }
    }

    // ---- rare sky surprises (every one of these is skipped when its number is zero) ----
    float tm = u.sizeTime.z;
    if (u.eggB.y > 0.0) {   // twin moons: a second, smaller moon high on the right
        float2 mp = float2(size.x * 0.80, size.y * 0.17); float ms = 9.0;
        float md = length(p - mp);
        float3 moon2 = float3(0.90, 0.92, 1.0);
        col += moon2 * exp(-max(md - ms, 0.0) / (ms * 2.2)) * 0.22 * u.eggB.y;
        float disc = smoothstep(ms + 1.0, ms - 1.0, md);
        float shade = smoothstep(ms * 0.9 + 1.0, ms * 0.9 - 1.0, length(p - mp - float2(-ms * 0.5, -ms * 0.14)));
        col = mix(col, moon2 * 0.30, disc * 0.35 * u.eggB.y);
        col = mix(col, moon2, disc * (1.0 - shade) * u.eggB.y);
    }
    if (u.eggA.y > 0.0) {   // double rainbow: two soft arcs, the outer one fainter and the other way round
        float2 c = float2(size.x * 0.5, size.y * 1.18);
        float r1 = size.x * 0.56, w1 = size.x * 0.030;
        float rr = length(p - c);
        float h1 = (r1 + w1 - rr) / (2.0 * w1);
        float b1 = smoothstep(0.0, 0.18, h1) * smoothstep(1.0, 0.82, h1);
        float r2 = r1 * 1.17, w2 = w1 * 1.25;
        float h2 = (r2 + w2 - rr) / (2.0 * w2);
        float b2 = smoothstep(0.0, 0.18, h2) * smoothstep(1.0, 0.82, h2);
        float lift = smoothstep(size.y * 1.02, size.y * 0.55, p.y);
        // Soft: the sky shows through, as it does through a real one.
        col = mix(col, mix(col, spectrum(h1), 0.55) + spectrum(h1) * 0.06, b1 * 0.50 * lift * u.eggA.y);
        col = mix(col, mix(col, spectrum(1.0 - h2), 0.55) + spectrum(1.0 - h2) * 0.04, b2 * 0.24 * lift * u.eggA.y);
    }
    if (u.eggA.z > 0.0) {   // aurora night: green and violet curtains
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float x = p.x * (0.0016 + 0.0006 * fi) + fi * 3.7;
            float wave = fbm(float2(x + t * 0.020, fi + t * 0.012));
            float base = size.y * (0.30 + 0.10 * fi) + (wave - 0.5) * size.y * 0.30;
            float above = base - p.y;
            float band = above > 0.0 ? exp(-above / (size.y * (0.20 + 0.05 * fi))) : exp(-pow(above / 28.0, 2.0));
            float gaps = smoothstep(0.30, 0.62, fbm(float2(x * 2.3 - t * 0.015, fi * 7.0 + 2.0)));
            float stri = 0.45 + 0.55 * vnoise(float2(p.x * 0.11 + wave * 9.0 + fi * 20.0, t * 0.25));
            float3 ac = mix(float3(0.22, 0.95, 0.55), float3(0.62, 0.36, 0.98), smoothstep(0.0, size.y * 0.3, above));
            col += ac * band * gaps * stri * (0.50 - 0.1 * fi) * u.eggA.z;
        }
    }
    if (u.eggB.z > 0.0) {   // a few bats drifting across
        for (int i = 0; i < 4; i++) {
            float fi = float(i);
            float sp = 16.0 + 7.0 * fi;
            float bx = fmod(t * sp + fi * size.x * 0.31, size.x + 160.0) - 80.0;
            float by = size.y * (0.16 + 0.11 * fi) + sin(t * 0.7 + fi * 2.1) * 14.0;
            float s = 9.0 + 2.5 * fi;
            float flap = m > 0.5 ? sin(t * (7.0 + fi) + fi) : 0.3;
            col = mix(col, float3(0.02, 0.01, 0.03), bat((p - float2(bx, by)) / s, flap) * 0.9 * u.eggB.z);
        }
    }
    if (u.eggB.w >= 0.0) {   // tiny fireworks over the arc: three bursts, again and again
        float cycle = fmod(u.eggB.w, 3.6);
        for (int b = 0; b < 3; b++) {
            float fb = float(b);
            float tb = cycle - fb * 0.9;
            if (tb < 0.0 || tb > 2.2) continue;
            float burst = floor(u.eggB.w / 3.6) * 3.0 + fb;
            float2 c = float2(size.x * (0.30 + 0.20 * fb + 0.08 * (hash11(burst) - 0.5)), size.y * (0.20 + 0.10 * hash11(burst + 5.0)));
            float3 fc = spectrum(fract(burst * 0.31 + 0.08));
            float grow = 1.0 - exp(-tb * 2.6);
            float fade = smoothstep(2.2, 0.9, tb);
            for (int j = 0; j < 18; j++) {
                float a = float(j) * 0.349 + hash11(burst + float(j)) * 0.2;
                float rad = (26.0 + 12.0 * hash11(burst * 3.0 + float(j))) * grow;
                float2 q = c + rad * float2(cos(a), sin(a)) + float2(0.0, 9.0 * tb * tb);
                col += (fc * 0.8 + 0.2) * exp(-length(p - q) / 1.5) * fade * 0.9;
                float2 q2 = c + rad * 0.55 * float2(cos(a + 0.17), sin(a + 0.17)) + float2(0.0, 5.0 * tb * tb);
                col += (fc * 0.5 + 0.5) * exp(-length(p - q2) / 1.1) * fade * 0.6;
            }
            col += float3(1.0, 0.95, 0.85) * exp(-length(p - c) / 5.0) * smoothstep(0.35, 0.0, tb) * 0.8;
        }
    }
    if (u.eggA.x >= 0.0) {   // shooting star: one bright streak with a tapering tail
        float s = u.eggA.x;
        float2 a = float2(size.x * 0.10, size.y * 0.08), bb = float2(size.x * 0.80, size.y * 0.40);
        float2 dir = normalize(bb - a);
        float2 head = mix(a, bb, s);
        float len = size.x * 0.17;
        float along = dot(head - p, dir);
        float side = length((head - p) - dir * along);
        float tail = step(0.0, along) * smoothstep(len, 0.0, along);
        float shine = sin(3.14159 * clamp(s, 0.0, 1.0));
        col += float3(1.0, 0.98, 0.90) * tail * exp(-side * side / (1.0 + max(along, 0.0) * 0.03)) * shine * 1.1;
        col += float3(0.85, 0.92, 1.0) * exp(-length(p - head) / 3.0) * shine;
    }

    float2 e = (p - size * 0.5) / size;
    col *= 1.0 - 0.14 * dot(e, e) * 2.0;
    if (retro > 0.5) {
        // Dithered bands: a few levels per channel, ordered dither between them.
        float levels = 11.0;
        col = floor(clamp(col, 0.0, 1.0) * levels + bayer4(block)) / levels;
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }
    col += (hash21(p + fract(u.sizeTime.z) * 61.0) - 0.5) / 255.0;
    return float4(clamp(col, 0.0, 1.0), 1.0);
}
"""#
}
