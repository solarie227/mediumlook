import Foundation
import Metal
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision

enum ViewMode: String, CaseIterable, Sendable {
    case result, original, depth
}

enum DepthSource: String, CaseIterable, Sendable {
    /// 写真に記録された深度（視差、単位 1/m）
    case embedded
    /// Core ML で推定した相対的な深度
    case estimated
}

struct RenderSettings: Equatable, Sendable {
    var presetID: String = "67"
    var fNumber: Double = 2.8
    var matchFOV: Bool = true
    var highlightBoost: Double = 2.0
    /// ピント位置（切り出す前の元の写真で、左上を0、右下を1とする座標）
    var focus: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var mode: ViewMode = .result
    var depthSource: DepthSource = .embedded
    /// 推定深度のときに使う、ピント位置までの距離（m）
    var subjectDistance: Double = 2.0
    /// 深度を引き伸ばすとき、写真の明暗の境目に合わせる
    var refineEdges: Bool = true
    /// 境目への合わせ方（0：なめらか 〜 1：細かく追従）
    var edgeStrength: Double = 0.5

    /// CIEdgePreserveUpsampleFilter の lumaSigma（小さいほど明暗の差に敏感）
    var edgeLumaSigma: Float { Float(0.3 * pow(0.1, edgeStrength)) }
}

struct RenderOutput: @unchecked Sendable {
    var image: CGImage?
    var focusDistanceM: Double?
    var depthUsed: DepthSource?
    var cropFactor: Double = 1
    /// 表示している範囲（元の写真で、左上を0、右下を1とする座標）
    var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var sourceFocal35: Double = 26
    var pixelSize: CGSize = .zero
    var milliseconds: Double = 0
    var message: String?
}

/// 開いたときのピント位置を何から決めたか
enum FocusSource: String, Sendable {
    /// EXIF の SubjectArea（撮影時にピントを合わせた範囲）
    case subjectArea
    /// 顔の検出
    case face
    case center

    var label: String {
        switch self {
        case .subjectArea: return "撮影時のピント位置"
        case .face: return "顔"
        case .center: return "中央"
        }
    }
}

struct LoadInfo: Sendable {
    var hasEmbeddedDepth: Bool
    var hasPortraitMatte = false
    var autoFocus = CGPoint(x: 0.5, y: 0.5)
    var focusSource: FocusSource = .center
    var sourceSize: CGSize
    var sourceFocal35: Double
    var message: String?
}

/// BokehShader の BokehParams と同じ並び
private struct BokehParams {
    var k: Float
    var focusDisparity: Float
    var maxRadius: Float
    var sampleCount: UInt32
    var highlightBoost: Float
    var originY: UInt32
}

/// 切り出し・縮小済みの画像とテクスチャ
private final class Prepared {
    let color: CIImage
    let disparity: CIImage
    let cropFactor: Double
    /// 元の写真のうち、この画像に使った範囲（左上を0、右下を1とする座標）
    var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// ポートレートの人物マスク（同じ範囲・大きさ）
    var matte: CIImage?
    var colorTexture: MTLTexture?
    var disparityTexture: MTLTexture?
    var outputTexture: MTLTexture?
    var disparityRange: (min: Float, max: Float) = (0, 1)

    init(color: CIImage, disparity: CIImage, cropFactor: Double) {
        self.color = color
        self.disparity = disparity
        self.cropFactor = cropFactor
    }
}

/// 写真の読み込み・深度の用意・ボケ処理・書き出しを専用キューで行う
final class RenderEngine: @unchecked Sendable {
    static let previewLongEdge: CGFloat = 2048
    static let defaultFocal35: Double = 26
    static let previewMaxSamples = 512
    static let exportMaxSamples = 1024

    let depthEstimator = DepthEstimator()

    private let queue = DispatchQueue(label: "MediumLook.render", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let ciContext: CIContext
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let displaySpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private var sourceColor: CIImage?
    private var embeddedDisparity: CIImage?
    private var estimatedDisparity: CIImage?
    private var portraitMatte: CIImage?
    private var sourceFocal35: Double = RenderEngine.defaultFocal35

    private var previewKey: String?
    private var preview: Prepared?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: BokehShader.source, options: nil),
              let function = library.makeFunction(name: "bokehKernel"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
        ])
    }

    // MARK: - 公開API

    func load(data: Data, completion: @escaping @Sendable (LoadInfo) -> Void) {
        queue.async { [self] in
            guard let color = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                completion(LoadInfo(hasEmbeddedDepth: false, sourceSize: .zero,
                                    sourceFocal35: Self.defaultFocal35, message: "画像を読み込めませんでした"))
                return
            }
            sourceColor = color.movedToOrigin()

            var disparity = CIImage(data: data, options: [.auxiliaryDisparity: true, .applyOrientationProperty: true])
            if disparity == nil,
               let depth = CIImage(data: data, options: [.auxiliaryDepth: true, .applyOrientationProperty: true]) {
                let filter = CIFilter.depthToDisparity()
                filter.inputImage = depth
                disparity = filter.outputImage
            }
            embeddedDisparity = disparity?.movedToOrigin()
            portraitMatte = CIImage(data: data, options: [.auxiliaryPortraitEffectsMatte: true,
                                                          .applyOrientationProperty: true])?.movedToOrigin()
            estimatedDisparity = nil
            sourceFocal35 = Self.focal35(from: data) ?? Self.defaultFocal35
            previewKey = nil
            preview = nil
            let (autoFocus, focusSource) = initialFocus(data: data)

            completion(LoadInfo(hasEmbeddedDepth: embeddedDisparity != nil,
                                hasPortraitMatte: portraitMatte != nil,
                                autoFocus: autoFocus,
                                focusSource: focusSource,
                                sourceSize: color.extent.size,
                                sourceFocal35: sourceFocal35,
                                message: nil))
        }
    }

    /// 連続して呼ばれた場合は最新の設定だけを処理する
    func render(_ settings: RenderSettings, completion: @escaping @Sendable (RenderOutput) -> Void) {
        lock.lock()
        generation += 1
        let myGeneration = generation
        lock.unlock()

        queue.async { [self] in
            lock.lock()
            let latest = generation
            lock.unlock()
            guard myGeneration == latest else { return }
            completion(renderPreview(settings))
        }
    }

    /// フル解像度で書き出す（拡張子で JPEG / HEIC / TIFF を切り替え）
    func export(_ settings: RenderSettings, to url: URL, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            let preset = FormatPreset.preset(id: settings.presetID)
            let depth = disparity(for: settings.depthSource)
            guard let depthImage = depth.image, let used = depth.used else {
                completion(depth.message ?? "深度データがありません")
                return
            }
            guard let prepared = prepare(longEdge: nil, preset: preset, matchFOV: settings.matchFOV, disparity: depthImage,
                                         edgeLumaSigma: settings.refineEdges ? settings.edgeLumaSigma : nil) else {
                completion("画像の準備に失敗しました")
                return
            }
            guard let focus = focusDisparity(at: settings.focus, in: prepared) else {
                completion("ピント位置の深度を読み取れませんでした")
                return
            }
            let (params, _) = makeParams(prepared: prepared, settings: settings, preset: preset,
                                         focusDisparity: focus, used: used, maxSamples: Self.exportMaxSamples)
            guard let result = runBokeh(prepared, params: params) else {
                completion("ボケ処理に失敗しました")
                return
            }
            do {
                try write(result, to: url)
                completion(nil)
            } catch {
                completion("書き出しに失敗しました：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - プレビュー

    private func renderPreview(_ settings: RenderSettings) -> RenderOutput {
        var out = RenderOutput()
        guard let sourceColor else {
            out.message = "写真を開いてください"
            return out
        }
        let start = CFAbsoluteTimeGetCurrent()
        let preset = FormatPreset.preset(id: settings.presetID)
        out.sourceFocal35 = sourceFocal35

        let depth = disparity(for: settings.depthSource)
        out.depthUsed = depth.used
        out.message = depth.message

        let key = "\(settings.presetID)-\(settings.matchFOV)-\(depth.used?.rawValue ?? "none")-\(settings.refineEdges)-\(settings.edgeStrength)"
        if key != previewKey {
            // 深度がなくても元画像は表示できるよう、ダミーの深度で切り出す
            let disparityForPrep = depth.image ?? CIImage(color: .white).cropped(to: sourceColor.extent)
            preview = prepare(longEdge: Self.previewLongEdge, preset: preset, matchFOV: settings.matchFOV,
                              disparity: disparityForPrep,
                              edgeLumaSigma: depth.image != nil && settings.refineEdges ? settings.edgeLumaSigma : nil)
            previewKey = key
        }
        guard let prepared = preview else {
            out.message = "画像の準備に失敗しました"
            return out
        }
        out.cropFactor = prepared.cropFactor
        out.cropRect = prepared.cropRect
        out.pixelSize = prepared.color.extent.size

        switch settings.mode {
        case .original:
            out.image = makeCGImage(prepared.color)

        case .depth:
            if depth.image != nil {
                out.image = makeCGImage(depthVisualization(prepared))
            } else {
                out.image = makeCGImage(prepared.color)
            }

        case .result:
            guard let used = depth.used else {
                out.image = makeCGImage(prepared.color)
                break
            }
            guard let focus = focusDisparity(at: settings.focus, in: prepared) else {
                out.image = makeCGImage(prepared.color)
                out.message = "その位置の深度を読み取れませんでした。別の場所をクリックしてください。"
                break
            }
            let (params, focusDistance) = makeParams(prepared: prepared, settings: settings, preset: preset,
                                                     focusDisparity: focus, used: used,
                                                     maxSamples: Self.previewMaxSamples)
            out.focusDistanceM = focusDistance
            if let result = runBokeh(prepared, params: params) {
                out.image = makeCGImage(result)
            } else {
                out.image = makeCGImage(prepared.color)
                out.message = "ボケ処理に失敗しました"
            }
        }

        out.milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return out
    }

    /// ボケのパラメーターを計算する。戻り値の2つ目はピント距離（m）
    private func makeParams(prepared: Prepared, settings: RenderSettings, preset: FormatPreset,
                            focusDisparity: Float, used: DepthSource, maxSamples: Int) -> (BokehParams, Double) {
        // 写真の深度はメートル単位なのでそのまま距離にする。推定深度は相対値なので、指定された距離を使う。
        // どちらでも D/Ds の比は同じなので、シェーダー側の計算は変わらない。
        let focusDistance = used == .embedded ? 1.0 / Double(focusDisparity) : settings.subjectDistance
        let diagonal = Double(hypot(prepared.color.extent.width, prepared.color.extent.height))
        let k = Optics.cocScale(preset: preset, fNumber: settings.fNumber,
                                focusDistanceM: focusDistance, imageDiagonalPx: diagonal)
        let relMin = abs(1 - Double(prepared.disparityRange.min) / Double(focusDisparity))
        let relMax = abs(1 - Double(prepared.disparityRange.max) / Double(focusDisparity))
        let cap = 0.04 * diagonal
        let maxRadius = min(cap, max(1, k * max(relMin, relMax)))
        let samples = UInt32(min(maxSamples, max(32, Int(Double.pi * maxRadius * maxRadius / 4))))
        let params = BokehParams(k: Float(k), focusDisparity: focusDisparity, maxRadius: Float(maxRadius),
                                 sampleCount: samples, highlightBoost: Float(settings.highlightBoost), originY: 0)
        return (params, focusDistance)
    }

    // MARK: - 深度の用意

    private func disparity(for requested: DepthSource) -> (image: CIImage?, used: DepthSource?, message: String?) {
        if requested == .embedded, let embedded = embeddedDisparity {
            return (embedded, .embedded, nil)
        }
        let note = requested == .embedded ? "写真に深度データがないため、推定した深度を使っています。" : nil
        if let estimated = estimatedDisparity {
            return (estimated, .estimated, note)
        }
        guard depthEstimator.isInstalled else {
            return (nil, nil, "この写真には深度データがありません。右の「深度」から推定モデルを導入すると、ボケをかけられます。")
        }
        guard let sourceColor else { return (nil, nil, nil) }
        do {
            // 推定は長辺1024pxの画像で行い、あとで引き伸ばす
            let scale = min(1, 1024 / max(sourceColor.extent.width, sourceColor.extent.height))
            let small = sourceColor.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cgImage = ciContext.createCGImage(small, from: small.extent, format: .RGBA8,
                                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            else { return (nil, nil, "推定用の画像を作れませんでした") }
            let raw = try depthEstimator.estimate(cgImage)
            // 負の値（空など）は0にそろえる
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = raw
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
            clamp.maxComponents = CIVector(x: 1e6, y: 1e6, z: 1e6, w: 1e6)
            let result = (clamp.outputImage ?? raw).movedToOrigin()
            estimatedDisparity = result
            return (result, .estimated, note)
        } catch {
            return (nil, nil, "深度の推定に失敗しました：\(error.localizedDescription)")
        }
    }

    // MARK: - 切り出しと縮小

    /// フォーマットの縦横比に切り出し、必要なら画角も合わせる。longEdge が nil ならフル解像度。
    /// edgeLumaSigma を渡すと、深度を写真の明暗の境目に合わせて引き伸ばす
    private func prepare(longEdge: CGFloat?, preset: FormatPreset, matchFOV: Bool, disparity: CIImage,
                         edgeLumaSigma: Float? = nil) -> Prepared? {
        guard let color = sourceColor else { return nil }
        let width = color.extent.width
        let height = color.extent.height

        // 換算焦点距離の比だけ対角を短くする（26mm → 約39mm なら約1.49倍の切り出し）
        let k = matchFOV ? max(1, preset.equivalentFocal35 / sourceFocal35) : 1
        let aspect = CGFloat(preset.aspect)
        let targetDiagonal = hypot(width, height) / CGFloat(k)
        let longSide = targetDiagonal / sqrt(1 + aspect * aspect)
        let shortSide = longSide * aspect
        var cropW = width >= height ? longSide : shortSide
        var cropH = width >= height ? shortSide : longSide
        let fit = min(1, width / cropW, height / cropH)
        cropW = floor(cropW * fit)
        cropH = floor(cropH * fit)
        let crop = CGRect(x: floor((width - cropW) / 2), y: floor((height - cropH) / 2), width: cropW, height: cropH)
        let cropFactor = Double(hypot(width, height) / hypot(cropW, cropH))

        let scale = longEdge.map { min(1, $0 / max(cropW, cropH)) } ?? 1
        let outW = floor(cropW * scale)
        let outH = floor(cropH * scale)

        let preparedColor = resample(color, crop: crop, scale: scale, width: outW, height: outH, highQuality: true)
        let preparedDisparity: CIImage
        if let edgeLumaSigma,
           let refined = edgeAwareDisparity(disparity, crop: crop, sourceSize: CGSize(width: width, height: height),
                                            guide: preparedColor, lumaSigma: edgeLumaSigma) {
            preparedDisparity = refined
        } else {
            // 深度は低解像度なので、まずカラー画像と同じ大きさに引き伸ばす
            let upscaled = disparity
                .samplingLinear()
                .transformed(by: CGAffineTransform(scaleX: width / disparity.extent.width,
                                                   y: height / disparity.extent.height))
            preparedDisparity = resample(upscaled, crop: crop, scale: scale, width: outW, height: outH, highQuality: false)
        }

        let prepared = Prepared(color: preparedColor, disparity: preparedDisparity, cropFactor: cropFactor)
        // 中央の切り出しなので、左下原点の crop をそのまま左上原点の比率に直せる
        prepared.cropRect = CGRect(x: crop.minX / width, y: (height - crop.maxY) / height,
                                   width: crop.width / width, height: crop.height / height)
        if let matte = portraitMatte {
            let upscaledMatte = matte
                .samplingLinear()
                .transformed(by: CGAffineTransform(scaleX: width / matte.extent.width,
                                                   y: height / matte.extent.height))
            prepared.matte = resample(upscaledMatte, crop: crop, scale: scale, width: outW, height: outH, highQuality: false)
        }
        prepared.colorTexture = makeTexture(from: preparedColor, colorSpace: linearSpace)
        prepared.disparityTexture = makeTexture(from: preparedDisparity, colorSpace: nil)
        prepared.outputTexture = makeTexture(width: Int(outW), height: Int(outH))
        prepared.disparityRange = minMax(of: preparedDisparity) ?? (0, 1)
        return prepared
    }

    /// 低解像度の深度を、写真（guide）の明暗の境目に沿うように引き伸ばす。
    /// 単純な引き伸ばしだと深度の境目が輪郭からずれ、被写体の縁がボケたり、縁の外の背景がボケずに残ったりする。
    private func edgeAwareDisparity(_ disparity: CIImage, crop: CGRect, sourceSize: CGSize,
                                    guide: CIImage, lumaSigma: Float) -> CIImage? {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        // 深度画像の座標で、カラー画像と同じ範囲を切り出す
        let sx = disparity.extent.width / sourceSize.width
        let sy = disparity.extent.height / sourceSize.height
        let smallCrop = CGRect(x: crop.minX * sx, y: crop.minY * sy, width: crop.width * sx, height: crop.height * sy)
        let small = disparity.cropped(to: smallCrop)
            .transformed(by: CGAffineTransform(translationX: -smallCrop.minX, y: -smallCrop.minY))
        let filter = CIFilter.edgePreserveUpsample()
        filter.inputImage = guide
        filter.smallImage = small
        filter.spatialSigma = 3
        filter.lumaSigma = lumaSigma
        guard let output = filter.outputImage else { return nil }
        return output.cropped(to: guide.extent)
    }

    private func resample(_ image: CIImage, crop: CGRect, scale: CGFloat, width: CGFloat, height: CGFloat, highQuality: Bool) -> CIImage {
        var img = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if scale < 1 {
            if highQuality {
                let filter = CIFilter.lanczosScaleTransform()
                filter.inputImage = img
                filter.scale = Float(scale)
                filter.aspectRatio = 1
                img = filter.outputImage ?? img
            } else {
                img = img.samplingLinear().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        return img.clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    // MARK: - テクスチャとボケ処理

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }

    /// CIImage を上端が0行目のビットマップに描き出してテクスチャへ転送する（上下の向きを確実にするため）
    private func makeTexture(from image: CIImage, colorSpace: CGColorSpace?) -> MTLTexture? {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        guard let texture = makeTexture(width: width, height: height) else { return nil }
        let rowBytes = width * 8
        var buffer = [UInt8](repeating: 0, count: rowBytes * height)
        buffer.withUnsafeMutableBytes { ptr in
            ciContext.render(image, toBitmap: ptr.baseAddress!, rowBytes: rowBytes,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height),
                             format: .RGBAh, colorSpace: colorSpace)
        }
        buffer.withUnsafeBytes { ptr in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: ptr.baseAddress!, bytesPerRow: rowBytes)
        }
        return texture
    }

    /// GPU のタイムアウトを避けるため、256行ずつの帯に分けて処理する
    private func runBokeh(_ prepared: Prepared, params: BokehParams) -> CIImage? {
        guard let colorTexture = prepared.colorTexture,
              let disparityTexture = prepared.disparityTexture,
              let outputTexture = prepared.outputTexture
        else { return nil }

        let width = outputTexture.width
        let height = outputTexture.height
        let tw = pipeline.threadExecutionWidth
        let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        let stripHeight = 256
        var y = 0
        while y < height {
            let rows = min(stripHeight, height - y)
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder()
            else { return nil }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(colorTexture, index: 0)
            encoder.setTexture(disparityTexture, index: 1)
            encoder.setTexture(outputTexture, index: 2)
            var p = params
            p.originY = UInt32(y)
            encoder.setBytes(&p, length: MemoryLayout<BokehParams>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: width, height: rows, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if commandBuffer.status == .error { return nil }
            y += rows
        }
        return readTexture(outputTexture)
    }

    /// テクスチャ（上端が0行目）を CGImage 経由で CIImage に戻す
    private func readTexture(_ texture: MTLTexture) -> CIImage? {
        let width = texture.width
        let height = texture.height
        let rowBytes = width * 8
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { ptr in
            texture.getBytes(ptr.baseAddress!, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: rowBytes,
                                    space: linearSpace, bitmapInfo: info, provider: provider,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - 深度の読み取り

    /// ピント位置（元の写真の座標）の周り（長辺の約1.5%）の平均視差。
    /// 人物マスクの内側を指しているときは、マスクの内側だけで平均する（髪の隙間から見える背景を拾わないため）
    private func focusDisparity(at sourcePoint: CGPoint, in prepared: Prepared) -> Float? {
        let disparity = prepared.disparity
        let crop = prepared.cropRect
        // 切り出した範囲の外なら、範囲の端に寄せる
        let px = min(max((sourcePoint.x - crop.minX) / crop.width, 0), 1)
        let py = min(max((sourcePoint.y - crop.minY) / crop.height, 0), 1)
        let w = disparity.extent.width
        let h = disparity.extent.height
        let r = max(4, 0.015 * max(w, h))
        // Core Image は左下が原点なので y を反転
        let cx = px * w
        let cy = (1 - py) * h
        let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r).intersection(disparity.extent)
        guard !rect.isEmpty else { return nil }

        if let matte = prepared.matte, let coverage = average(of: matte, in: rect), coverage > 0.5 {
            let weighted = CIFilter.multiplyCompositing()
            weighted.inputImage = disparity
            weighted.backgroundImage = matte
            if let image = weighted.outputImage,
               let sum = average(of: image, in: rect), sum.isFinite, sum > 0 {
                return sum / coverage
            }
        }
        guard let value = average(of: disparity, in: rect), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// 範囲内の平均（赤の成分）
    private func average(of image: CIImage, in rect: CGRect) -> Float? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = rect
        guard let output = filter.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 16,
                         bounds: output.extent, format: .RGBAf, colorSpace: nil)
        return pixel[0]
    }

    // MARK: - 開いたときのピント位置

    /// 1. 撮影時にピントを合わせた範囲（EXIF SubjectArea）が中央の初期値でなければ、それを使う
    /// 2. なければ顔（いちばん大きい顔の目のあたり）
    /// 3. どちらもなければ SubjectArea の中心か、画像の中央
    private func initialFocus(data: Data) -> (CGPoint, FocusSource) {
        let area = Self.subjectArea(from: data)
        if let area, area.specific {
            return (area.point, .subjectArea)
        }
        if let face = detectFace() {
            return (face, .face)
        }
        return (area?.point ?? CGPoint(x: 0.5, y: 0.5), .center)
    }

    /// EXIF の SubjectArea を、向きを直した写真の座標（左上を0、右下を1）にして返す。
    /// specific は、撮影時にタップや顔で決めた範囲らしいか（中央の広い範囲は初期値とみなす）
    private static func subjectArea(from data: Data) -> (point: CGPoint, specific: Bool)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let values = exif[kCGImagePropertyExifSubjectArea] as? [NSNumber],
              values.count >= 2
        else { return nil }
        let area = values.map { $0.doubleValue }
        // SubjectArea は記録されたままの（回転前の）画素の座標
        let width = (exif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.doubleValue
            ?? (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (exif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.doubleValue
            ?? (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { return nil }
        let x = area[0] / width
        let y = area[1] / height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }

        let offCenter = hypot(x - 0.5, y - 0.5) > 0.05
        var small = false
        if area.count >= 4 {
            small = (area[2] / width) * (area[3] / height) < 0.1
        } else if area.count == 3 {
            small = area[2] / max(width, height) < 0.3
        }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (oriented(CGPoint(x: x, y: y), orientation: orientation), offCenter || small)
    }

    /// 回転前の座標（左上原点・比率）を、EXIF の向きを適用したあとの座標に直す
    private static func oriented(_ p: CGPoint, orientation: UInt32) -> CGPoint {
        switch orientation {
        case 2: return CGPoint(x: 1 - p.x, y: p.y)      // 左右反転
        case 3: return CGPoint(x: 1 - p.x, y: 1 - p.y)  // 180度
        case 4: return CGPoint(x: p.x, y: 1 - p.y)      // 上下反転
        case 5: return CGPoint(x: p.y, y: p.x)          // 転置
        case 6: return CGPoint(x: 1 - p.y, y: p.x)      // 時計回りに90度（iPhoneの縦位置）
        case 7: return CGPoint(x: 1 - p.y, y: 1 - p.x)
        case 8: return CGPoint(x: p.y, y: 1 - p.x)      // 反時計回りに90度
        default: return p
        }
    }

    /// いちばん大きい顔の目のあたり（向きを直した写真の座標、左上を0）
    private func detectFace() -> CGPoint? {
        guard let sourceColor else { return nil }
        let scale = min(1, 1024 / max(sourceColor.extent.width, sourceColor.extent.height))
        let small = sourceColor.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(small, from: small.extent, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        else { return nil }
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let faces = (request.results ?? []).filter { $0.boundingBox.width * $0.boundingBox.height > 0.001 }
        guard let face = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }
        // Vision は左下が原点。目は顔の枠の上から約4割の高さ
        let box = face.boundingBox
        return CGPoint(x: box.midX, y: 1 - (box.maxY - 0.4 * box.height))
    }

    private func minMax(of disparity: CIImage) -> (min: Float, max: Float)? {
        let filter = CIFilter.areaMinMax()
        filter.inputImage = disparity
        filter.extent = disparity.extent
        guard let output = filter.outputImage else { return nil }
        var pixels = [Float](repeating: 0, count: 8)
        ciContext.render(output, toBitmap: &pixels, rowBytes: 32,
                         bounds: output.extent, format: .RGBAf, colorSpace: nil)
        let lo = pixels[0], hi = pixels[4]
        guard lo.isFinite, hi.isFinite, hi > lo else { return nil }
        return (lo, hi)
    }

    private func depthVisualization(_ prepared: Prepared) -> CIImage {
        let range = max(prepared.disparityRange.max - prepared.disparityRange.min, 1e-4)
        let scale = CGFloat(1 / range)
        let bias = CGFloat(-prepared.disparityRange.min) * scale
        let filter = CIFilter.colorMatrix()
        filter.inputImage = prepared.disparity
        filter.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        filter.bVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.biasVector = CIVector(x: bias, y: bias, z: bias, w: 1)
        return (filter.outputImage ?? prepared.disparity).cropped(to: prepared.disparity.extent)
    }

    // MARK: - 補助

    private func makeCGImage(_ image: CIImage) -> CGImage? {
        ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: displaySpace)
    }

    private func write(_ image: CIImage, to url: URL) throws {
        let quality = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
        switch url.pathExtension.lowercased() {
        case "heic", "heif":
            try ciContext.writeHEIFRepresentation(of: image, to: url, format: .RGBA8,
                                                  colorSpace: displaySpace, options: quality)
        case "tif", "tiff":
            try ciContext.writeTIFFRepresentation(of: image, to: url, format: .RGBA16,
                                                  colorSpace: displaySpace, options: [:])
        default:
            try ciContext.writeJPEGRepresentation(of: image, to: url,
                                                  colorSpace: displaySpace, options: quality)
        }
    }

    private static func focal35(from data: Data) -> Double? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let value = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber,
              value.doubleValue > 0
        else { return nil }
        return value.doubleValue
    }
}

private extension CIImage {
    func movedToOrigin() -> CIImage {
        transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}
