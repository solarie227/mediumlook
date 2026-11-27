import Foundation

/// フィルムの質感と色合いのプリセット。
/// 実在のフィルムを測ったものではなく、スキャンでよく見る傾向を目で合わせた近似。
struct FilmStock: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let note: String
    /// 色の出方（リニアのRGBに掛ける3×3行列、行優先。各行の和がほぼ1なら無彩色は変わらない）
    let matrix: [Float]
    /// S字カーブの強さ（中間の傾きが 1+curve になる。0で直線）
    let curve: Float
    /// 黒の浮き・白の上限（知覚的な明るさ 0〜1）
    let black: Float
    let white: Float
    let saturation: Float
    /// 暗部・明部の色味（掛け算）
    let shadowTint: SIMD3<Float>
    let highlightTint: SIMD3<Float>
    /// 粒子の大きさ（フィルム上のμm）。画面上の大きさはフォーマットの対角長で変わる
    let grainMicrons: Double
    /// 粒子の強さ（粒子が1画素以上の大きさのときの、知覚的な明るさでの標準偏差）
    let grainAmount: Float
    /// ハレーション（明るい部分のまわりの赤いにじみ）の強さ
    let halation: Float
    let mono: Bool
    let monoWeights: SIMD3<Float>

    var isNone: Bool { id == Self.none.id }

    static let none = FilmStock(
        id: "none", name: "なし", note: "色と階調は変えません（周辺減光だけかけられます）。",
        matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
        curve: 0, black: 0, white: 1, saturation: 1,
        shadowTint: SIMD3(1, 1, 1), highlightTint: SIMD3(1, 1, 1),
        grainMicrons: 0, grainAmount: 0, halation: 0,
        mono: false, monoWeights: SIMD3(0.2126, 0.7152, 0.0722))

    static let all: [FilmStock] = [
        none,
        FilmStock(
            id: "portra", name: "カラーネガ・やわらか（Portra 400風）",
            note: "低めのコントラスト、暖かい肌色、浮いた黒と粘るハイライト。",
            matrix: [1.05, -0.04, -0.01,
                     0.02, 0.96, 0.02,
                     -0.01, 0.06, 0.95],
            curve: 0.15, black: 0.035, white: 0.975, saturation: 0.92,
            shadowTint: SIMD3(0.98, 1.0, 1.02), highlightTint: SIMD3(1.03, 1.0, 0.95),
            grainMicrons: 12, grainAmount: 0.05, halation: 0.3,
            mono: false, monoWeights: SIMD3(0.2126, 0.7152, 0.0722)),
        FilmStock(
            id: "ektar", name: "カラーネガ・鮮やか（Ektar 100風）",
            note: "高い彩度とコントラスト、澄んだ青、細かい粒子。",
            matrix: [1.10, -0.08, -0.02,
                     -0.03, 1.07, -0.04,
                     -0.02, -0.06, 1.08],
            curve: 0.35, black: 0.01, white: 1.0, saturation: 1.2,
            shadowTint: SIMD3(0.98, 0.99, 1.03), highlightTint: SIMD3(1.02, 1.0, 0.97),
            grainMicrons: 8, grainAmount: 0.035, halation: 0.3,
            mono: false, monoWeights: SIMD3(0.2126, 0.7152, 0.0722)),
        FilmStock(
            id: "pro400h", name: "カラーネガ・パステル（Pro 400H風）",
            note: "淡い色、緑がかった暗部、明るく軽い仕上がり。",
            matrix: [0.97, 0.04, -0.01,
                     0.0, 1.0, 0.0,
                     0.0, 0.04, 0.96],
            curve: 0.08, black: 0.05, white: 0.97, saturation: 0.85,
            shadowTint: SIMD3(0.96, 1.02, 1.03), highlightTint: SIMD3(1.0, 1.0, 0.99),
            grainMicrons: 12, grainAmount: 0.05, halation: 0.3,
            mono: false, monoWeights: SIMD3(0.2126, 0.7152, 0.0722)),
        FilmStock(
            id: "velvia", name: "リバーサル・鮮烈（Velvia 50風）",
            note: "締まった黒、強い彩度とコントラスト、ほとんど見えない粒子。",
            matrix: [1.15, -0.12, -0.03,
                     -0.05, 1.12, -0.07,
                     -0.03, -0.09, 1.12],
            curve: 0.5, black: 0.0, white: 1.0, saturation: 1.35,
            shadowTint: SIMD3(1.0, 0.99, 1.02), highlightTint: SIMD3(1.0, 1.0, 1.0),
            grainMicrons: 7, grainAmount: 0.025, halation: 0.2,
            mono: false, monoWeights: SIMD3(0.2126, 0.7152, 0.0722)),
        FilmStock(
            id: "trix", name: "モノクロ（Tri-X 400風）",
            note: "しっかりしたコントラストと、はっきりした粒子。",
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            curve: 0.4, black: 0.02, white: 0.98, saturation: 0,
            shadowTint: SIMD3(1, 1, 1), highlightTint: SIMD3(1, 1, 1),
            grainMicrons: 18, grainAmount: 0.08, halation: 0.15,
            mono: true, monoWeights: SIMD3(0.33, 0.52, 0.15)),
    ]

    static func stock(id: String) -> FilmStock {
        all.first { $0.id == id } ?? none
    }
}
