import Foundation

/// 再現したい中判フォーマットとレンズの組み合わせ
struct FormatPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// 画面の短辺・長辺（mm）
    let shortMM: Double
    let longMM: Double
    /// 焦点距離（mm）
    let focalMM: Double
    let defaultFNumber: Double

    var diagonalMM: Double { (shortMM * shortMM + longMM * longMM).squareRoot() }
    /// 短辺 / 長辺
    var aspect: Double { shortMM / longMM }
    /// 35mm判（対角43.27mm）に換算した焦点距離
    var equivalentFocal35: Double { focalMM * 43.27 / diagonalMM }
    var aspectLabel: String {
        let gcdValue = Self.gcd(Int(shortMM.rounded()), Int(longMM.rounded()))
        guard gcdValue > 0 else { return "" }
        return "\(Int(shortMM.rounded()) / gcdValue):\(Int(longMM.rounded()) / gcdValue)"
    }

    static let all: [FormatPreset] = [
        FormatPreset(id: "67", name: "6×7 80mm（マキナ67）", shortMM: 56, longMM: 70, focalMM: 80, defaultFNumber: 2.8),
        FormatPreset(id: "645", name: "6×4.5 75mm", shortMM: 41.5, longMM: 56, focalMM: 75, defaultFNumber: 2.8),
        FormatPreset(id: "66", name: "6×6 80mm", shortMM: 56, longMM: 56, focalMM: 80, defaultFNumber: 2.8),
        FormatPreset(id: "ff", name: "35mm判 50mm（比較用）", shortMM: 24, longMM: 36, focalMM: 50, defaultFNumber: 1.4),
    ]

    static func preset(id: String) -> FormatPreset {
        all.first { $0.id == id } ?? all[0]
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }
}

enum Optics {
    static let fStops: [Double] = [1.4, 2, 2.8, 4, 5.6, 8, 11, 16]

    /// ボケの半径（ピクセル）の係数 K を返す。
    ///
    /// 錯乱円の直径（フィルム上）は
    ///   b = f² / (N(s − f)) × |d − s| / d
    /// 視差 D = 1/d、ピント面の視差 Ds = 1/s とすると
    ///   b = b∞ × |1 − D / Ds|,  b∞ = f² / (N(s − f))
    /// これをフォーマットの対角長に対する比率に直し、画像の対角ピクセル数を掛けて半径にする。
    /// シェーダー側では r = K × |1 − D / Ds| を計算する。
    static func cocScale(preset: FormatPreset, fNumber: Double, focusDistanceM: Double, imageDiagonalPx: Double) -> Double {
        let f = preset.focalMM / 1000
        let s = max(focusDistanceM, f + 0.05)
        let blurDiameterAtInfinity = f * f / (fNumber * (s - f))
        let fractionOfDiagonal = blurDiameterAtInfinity / (preset.diagonalMM / 1000)
        return 0.5 * fractionOfDiagonal * imageDiagonalPx
    }
}
