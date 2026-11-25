/// Metal シェーダーのソース。Swift Package でも確実に使えるよう、実行時にコンパイルする。
enum BokehShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// Swift 側の BokehParams と同じ並び（すべて4バイト、合計24バイト）
struct BokehParams {
    float k;               // 無限遠に対するボケ半径（px）
    float focusDisparity;  // ピント面の視差 Ds
    float maxRadius;       // 探索半径の上限（px）
    uint  sampleCount;     // 1画素あたりのサンプル数
    float highlightBoost;  // 明るい画素をボケの中でどれだけ強く効かせるか
    uint  originY;         // 帯状に分割して処理するときの開始行
};

inline float cocRadius(float disparity, constant BokehParams &p) {
    float r = p.k * fabs(1.0 - disparity / max(p.focusDisparity, 1e-4));
    return min(r, p.maxRadius);
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

    float rEffC = max(rC, 0.5);
    float wC = 1.0 / (rEffC * rEffC);
    float3 acc = cC * wC;
    float wSum = wC;

    // 画素ごとに螺旋を回転させて、規則的な模様を崩す
    float rot = fract(sin(dot(pos, float2(12.9898, 78.233))) * 43758.5453) * 6.2831853;
    const float golden = 2.39996323;
    float n = float(p.sampleCount);

    for (uint i = 1; i < p.sampleCount; i++) {
        float fi = float(i);
        float dist = p.maxRadius * sqrt(fi / n);
        float ang = fi * golden + rot;
        float2 sp = pos + float2(cos(ang), sin(ang)) * dist;

        float dS = disparityTex.sample(smp, sp).r;
        float rS = cocRadius(dS, p);

        // 奥の画素（視差が小さい）は、手前のピントが合った画素の上には広がれない
        float rEff = (dS < dC) ? min(rS, rC) : rS;
        rEff = max(rEff, 0.5);

        float coverage = saturate(rEff - dist + 0.5);
        if (coverage <= 0.0) { continue; }

        float wgt = coverage / (rEff * rEff);
        float3 cS = expandHighlights(colorTex.sample(smp, sp).rgb, p.highlightBoost);
        acc += cS * wgt;
        wSum += wgt;
    }

    float3 result = compressHighlights(acc / max(wSum, 1e-6), p.highlightBoost);
    outTex.write(float4(result, 1.0), gid);
}
"""#
}
