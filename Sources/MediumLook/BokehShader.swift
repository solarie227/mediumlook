/// Metal シェーダーのソース。Swift Package でも確実に使えるよう、実行時にコンパイルする。
enum BokehShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// Swift 側の BokehParams と同じ並び（すべて4バイト、合計28バイト）
struct BokehParams {
    float k;               // 無限遠に対するボケ半径（px）
    float focusDisparity;  // ピント面の視差 Ds
    float maxRadius;       // 探索半径の上限（px）
    uint  sampleCount;     // 1画素あたりのサンプル数
    float highlightBoost;  // 明るい画素をボケの中でどれだけ強く効かせるか
    uint  originY;         // 帯状に分割して処理するときの開始行
    float nearScale;       // 前ボケ（ピント面より手前）の量の倍率
};

inline float cocRadius(float disparity, constant BokehParams &p) {
    float rel = 1.0 - disparity / max(p.focusDisparity, 1e-4);
    float r = p.k * fabs(rel);
    if (rel < 0.0) { r *= p.nearScale; }   // 視差がピント面より大きい＝手前
    return min(r, p.maxRadius);
}

// ボケの円がその点を覆う割合。縁は大きさに応じて少しやわらかくする（硬いコインのように見えないように）
inline float softCoverage(float r, float dist) {
    float edge = max(1.0, 0.12 * r);
    return saturate((r - dist) / edge + 0.5);
}

// 逆変換できる曲線の組。広げる: E(x) = x / (1 - kx)、戻す: C(y) = y / (1 + ky)、k = boost / (1 + boost)
// ボケない部分や一様に明るい空は元に戻り、小さな光だけがボケの中で玉として残る。
inline float highlightK(float boost) { return boost / (1.0 + boost); }

inline float3 expandHighlights(float3 c, float boost) {
    float m = clamp(max(c.r, max(c.g, c.b)), 0.0, 1.0);
    return c / (1.0 - highlightK(boost) * m);
}

inline float3 compressHighlights(float3 c, float boost) {
    float m = max(max(c.r, max(c.g, c.b)), 0.0);
    return c / (1.0 + highlightK(boost) * m);
}

kernel void bokehKernel(texture2d<float, access::sample> colorTex     [[texture(0)]],
                        texture2d<float, access::sample> disparityTex [[texture(1)]],
                        texture2d<float, access::write>  outTex       [[texture(2)]],
                        constant BokehParams &p                       [[buffer(0)]],
                        uint2 tid                                     [[thread_position_in_grid]])
{
    uint2 gid = uint2(tid.x, tid.y + p.originY);
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }

    constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);

    float2 pos = float2(gid) + 0.5;
    float dC = disparityTex.sample(smp, pos).r;
    float rC = cocRadius(dC, p);
    float3 cC = expandHighlights(colorTex.sample(smp, pos).rgb, p.highlightBoost);

    // 2つの層に分けて作り、最後に重ねる（ゲームの被写界深度でよく使う、前ボケと後ろの分離）
    //  ・前ボケの層：ピント面より手前でボケている画素。どの画素の上にも、自分のボケの大きさで半透明に広がる。
    //    その点を覆っている割合を不透明度にする（手前の物の縁の内側にも、後ろが透けて見える）
    //  ・後ろの層：ピント面とその奥。奥の画素は、手前のピントが合った画素の上には広がれない
    float Ds = p.focusDisparity;
    bool centerNear = (dC > Ds * 1.01) && (rC > 0.5);
    float rEffC = max(rC, 0.5);

    float n = float(p.sampleCount);
    // 1サンプルが受け持つ面積（÷π）。前ボケの層の不透明度を「覆っている割合」として求めるのに使う
    float areaPerSample = p.maxRadius * p.maxRadius / n;

    float3 accN = 0.0;
    float wN = 0.0;
    float3 accB = 0.0;
    float wB = 0.0;
    if (centerNear) {
        float w = areaPerSample / (rEffC * rEffC);
        accN += cC * w;
        wN += w;
    } else {
        float w = 1.0 / (rEffC * rEffC);
        accB += cC * w;
        wB += w;
    }

    // 画素ごとに螺旋を回転させて、規則的な模様を崩す
    float rot = fract(sin(dot(pos, float2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
    const float golden = 2.39996323;

    for (uint i = 1; i < p.sampleCount; i++) {
        float fi = float(i);
        float dist = p.maxRadius * sqrt(fi / n);
        float ang = fi * golden + rot;
        float2 sp = pos + float2(cos(ang), sin(ang)) * dist;

        float dS = disparityTex.sample(smp, sp).r;
        float rS = cocRadius(dS, p);
        bool near = (dS > Ds * 1.01) && (rS > 0.5);

        if (near) {
            float rF = max(rS, 0.5);
            float coverage = softCoverage(rF, dist);
            if (coverage <= 0.0) { continue; }
            float wgt = coverage * areaPerSample / (rF * rF);
            accN += expandHighlights(colorTex.sample(smp, sp).rgb, p.highlightBoost) * wgt;
            wN += wgt;
        } else {
            float rEff;
            if (centerNear) {
                // 中心が前ボケのとき、後ろの層は「手前の物の陰に見えているはずの背景」。
                // 背景自身のボケが小さくても、中心のボケの範囲から集めて推し量る
                rEff = rC;
            } else {
                rEff = (dS < dC) ? min(rS, rC) : rS;
            }
            rEff = max(rEff, 0.5);
            float coverage = softCoverage(rEff, dist);
            if (coverage <= 0.0) { continue; }
            float wgt = coverage / (rEff * rEff);
            accB += expandHighlights(colorTex.sample(smp, sp).rgb, p.highlightBoost) * wgt;
            wB += wgt;
        }
    }

    float3 background = wB > 0.0 ? accB / wB : cC;
    float alphaN = saturate(wN);
    float3 nearColor = wN > 0.0 ? accN / wN : background;
    float3 result = compressHighlights(mix(background, nearColor, alphaN), p.highlightBoost);
    outTex.write(float4(result, 1.0), gid);
}
"""#
}

/// フィルムの質感（色・階調・ハレーション・周辺減光・粒状）のシェーダー。ボケのあとにかける。
enum FilmShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// Swift 側の FilmParams と同じ並び（float4 が7つ、4バイトが16個、合計176バイト）
struct FilmParams {
    float4 m0;             // 色の行列の各行（xyz を使う）
    float4 m1;
    float4 m2;
    float4 shadowTint;
    float4 highlightTint;
    float4 monoWeights;
    float4 halationColor;
    float curve;           // S字カーブの強さ
    float black;           // 黒の浮き（知覚的な明るさ）
    float white;           // 白の上限（知覚的な明るさ）
    float saturation;
    float strength;        // 色と階調のかかり具合（0〜1）
    float grainAmp;        // 粒子の強さ
    float grainSizePx;     // 粒子の大きさ（画素）
    float chromaGrain;     // 色の粒子の割合
    float halation;
    float halationRadius;  // ハレーションの広がり（画素）
    float vignette;
    uint  mono;
    uint  seed;
    uint  pad0;
    uint  pad1;
    uint  originY;         // 帯状に分割して処理するときの開始行
};

constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

// 中間（18%グレー）を固定したS字カーブ。0→0、1→1、中間の傾き 1+s、両端の傾き 1/(1+s)
inline float filmCurve(float p, float s) {
    const float pivot = 0.459;
    p = clamp(p, 0.0, 1.0);
    if (p <= pivot) {
        float a = 1.0 / (1.0 + s);
        float q = p / pivot;
        return pivot * (a * q / (1.0 + (a - 1.0) * q));
    }
    float q = (p - pivot) / (1.0 - pivot);
    return pivot + (1.0 - pivot) * (q * (1.0 + s) / (1.0 + s * q));
}

inline float hash21(uint2 p, uint seed) {
    uint h = p.x * 374761393u + p.y * 668265263u + seed * 2246822519u;
    h = (h ^ (h >> 13)) * 1274126177u;
    h = h ^ (h >> 16);
    return float(h & 0x00FFFFFFu) / 16777215.0;
}

// 平均0・分散およそ1の雑音
inline float gaussNoise(uint2 p, uint seed) {
    return (hash21(p, seed) + hash21(p, seed + 101u) + hash21(p, seed + 202u) - 1.5) * 2.0;
}

inline float valueNoise(float2 x, uint seed) {
    float2 i = floor(x);
    float2 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    uint2 b = uint2(i);
    float a = gaussNoise(b, seed);
    float c = gaussNoise(b + uint2(1, 0), seed);
    float d = gaussNoise(b + uint2(0, 1), seed);
    float e = gaussNoise(b + uint2(1, 1), seed);
    return mix(mix(a, c, f.x), mix(d, e, f.x), f.y);
}

// 粒子が1画素より小さいときは、画素の中で平均されて弱くなる（大きさに比例）
inline float grainAt(float2 pos, float sizePx, uint seed) {
    if (sizePx < 1.0) {
        return gaussNoise(uint2(pos), seed) * sizePx;
    }
    return valueNoise(pos / sizePx, seed) * 1.6;
}

kernel void filmKernel(texture2d<float, access::sample> inTex  [[texture(0)]],
                       texture2d<float, access::write>  outTex [[texture(1)]],
                       constant FilmParams &p                  [[buffer(0)]],
                       uint2 tid                               [[thread_position_in_grid]])
{
    uint2 gid = uint2(tid.x, tid.y + p.originY);
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }

    constexpr sampler smp(coord::pixel, filter::linear, address::clamp_to_edge);
    float2 pos = float2(gid) + 0.5;
    float3 c = max(inTex.sample(smp, pos).rgb, 0.0);

    // ハレーション：まわりのとても明るい部分を集めて、赤みのある光として足す
    if (p.halation > 0.0) {
        float h = 0.0;
        float wSum = 0.0;
        for (int ring = 1; ring <= 3; ring++) {
            float r = p.halationRadius * float(ring) / 3.0;
            float w = 1.0 / float(ring);
            for (int k = 0; k < 12; k++) {
                float ang = (float(k) + 0.5 * float(ring)) * 0.5235988;
                float3 s = inTex.sample(smp, pos + r * float2(cos(ang), sin(ang))).rgb;
                h += max(dot(s, kLuma) - 0.8, 0.0) * w;
                wSum += w;
            }
        }
        c += p.halationColor.rgb * (h / wSum) * p.halation * 4.0;
    }

    // 周辺減光（四隅で最大）
    float2 size = float2(outTex.get_width(), outTex.get_height());
    float r = length(pos - size * 0.5) / (0.5 * length(size));
    float falloff = 1.0 / ((1.0 + r * r) * (1.0 + r * r));
    c *= mix(1.0, falloff, p.vignette);

    // 色と階調
    float3 film;
    if (p.mono != 0) {
        film = float3(dot(c, p.monoWeights.rgb));
    } else {
        film = float3(dot(p.m0.xyz, c), dot(p.m1.xyz, c), dot(p.m2.xyz, c));
    }
    film = max(film, 0.0);
    float3 perceptual = pow(film, float3(1.0 / 2.2));
    perceptual = float3(filmCurve(perceptual.r, p.curve),
                        filmCurve(perceptual.g, p.curve),
                        filmCurve(perceptual.b, p.curve));
    perceptual = p.black + (p.white - p.black) * perceptual;
    film = pow(max(perceptual, 0.0), float3(2.2));
    float luma = dot(film, kLuma);
    film = max(luma + (film - luma) * p.saturation, 0.0);
    float t = smoothstep(0.0, 1.0, pow(saturate(luma), 1.0 / 2.2));
    film *= mix(p.shadowTint.rgb, p.highlightTint.rgb, t);

    float3 result = mix(c, film, p.strength);

    // 粒状：知覚的な明るさの上で足す。中間調で強く、暗部にも少し残す
    if (p.grainAmp > 0.0) {
        float g = grainAt(pos, p.grainSizePx, p.seed);
        float3 grain = float3(g);
        if (p.mono == 0) {
            float3 chroma = float3(grainAt(pos, p.grainSizePx, p.seed + 11u),
                                   grainAt(pos, p.grainSizePx, p.seed + 23u),
                                   grainAt(pos, p.grainSizePx, p.seed + 37u));
            grain = mix(grain, chroma, p.chromaGrain);
        }
        float3 pc = pow(max(result, 0.0), float3(1.0 / 2.2));
        float lum = saturate(dot(pc, kLuma));
        float amp = p.grainAmp * (0.35 + 2.6 * lum * (1.0 - lum));
        pc += grain * amp;
        result = pow(max(pc, 0.0), float3(2.2));
    }

    outTex.write(float4(result, 1.0), gid);
}
"""#
}
