import Foundation
import CoreML
import Vision
import CoreImage

/// 深度データがない写真のための単眼深度推定（Apple の Core ML 版 Depth Anything V2 Small、Apache-2.0）
final class DepthEstimator: @unchecked Sendable {
    static let modelName = "DepthAnythingV2SmallF16"
    private static let baseURL = URL(string: "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage/")!
    private static let files = [
        "Manifest.json",
        "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin",
    ]

    private let lock = NSLock()
    private var model: VNCoreMLModel?

    var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediumLook", isDirectory: true)
    }

    var compiledURL: URL {
        supportDirectory.appendingPathComponent("\(Self.modelName).mlmodelc", isDirectory: true)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: compiledURL.path)
    }

    /// モデル（約50MB）をダウンロードしてコンパイルし、Application Support に置く
    func install(progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let package = supportDirectory.appendingPathComponent("\(Self.modelName).mlpackage", isDirectory: true)
        try? fm.removeItem(at: package)
        try fm.createDirectory(at: package.appendingPathComponent("Data/com.apple.CoreML/weights"),
                               withIntermediateDirectories: true)

        for (index, file) in Self.files.enumerated() {
            progress("モデルをダウンロード中（\(index + 1)/\(Self.files.count)）")
            let (temp, response) = try await URLSession.shared.download(from: Self.baseURL.appendingPathComponent(file))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw EstimatorError.download(file)
            }
            let destination = package.appendingPathComponent(file)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temp, to: destination)
        }

        progress("モデルを準備中")
        let compiled = try await MLModel.compileModel(at: package)
        try? fm.removeItem(at: compiledURL)
        try fm.copyItem(at: compiled, to: compiledURL)
        try? fm.removeItem(at: compiled)
        try? fm.removeItem(at: package)

        lock.lock()
        model = nil
        lock.unlock()
    }

    /// 相対的な視差（手前ほど大きい値）を、入力と同じ向きの低解像度画像で返す
    func estimate(_ image: CGImage) throws -> CIImage {
        let request = VNCoreMLRequest(model: try loadModel())
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        if let observation = request.results?.first as? VNPixelBufferObservation {
            return CIImage(cvPixelBuffer: observation.pixelBuffer, options: [.colorSpace: NSNull()])
        }
        // 出力が画像ではなく配列で返る場合
        if let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
           let array = observation.featureValue.multiArrayValue,
           let image = Self.image(from: array) {
            return image
        }
        throw EstimatorError.noResult
    }

    /// [1, H, W] や [H, W] の配列を、上端が0行目のグレー画像にする
    private static func image(from array: MLMultiArray) -> CIImage? {
        let shape = array.shape.map { $0.intValue }
        guard shape.count >= 2 else { return nil }
        let height = shape[shape.count - 2]
        let width = shape[shape.count - 1]
        var values = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            values[i] = array[i].floatValue
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearGray)
        else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                                | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cgImage = CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider,
                                    decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private func loadModel() throws -> VNCoreMLModel {
        lock.lock()
        defer { lock.unlock() }
        if let model { return model }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
        let vnModel = try VNCoreMLModel(for: mlModel)
        model = vnModel
        return vnModel
    }

    enum EstimatorError: LocalizedError {
        case download(String)
        case noResult

        var errorDescription: String? {
            switch self {
            case .download(let file): return "モデルのダウンロードに失敗しました（\(file)）"
            case .noResult: return "深度を推定できませんでした"
            }
        }
    }
}
