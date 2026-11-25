import SwiftUI
import AppKit
import PhotosUI
import UniformTypeIdentifiers

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var settings = RenderSettings() {
        didSet {
            if settings.presetID != oldValue.presetID {
                settings.fNumber = FormatPreset.preset(id: settings.presetID).defaultFNumber
            }
            if settings != oldValue { requestRender() }
        }
    }
    @Published private(set) var image: CGImage?
    @Published private(set) var output = RenderOutput()
    @Published private(set) var loadInfo: LoadInfo?
    @Published private(set) var isBusy = false
    @Published private(set) var isExporting = false
    @Published private(set) var modelInstalled = false
    @Published private(set) var modelStatus: String?
    @Published private(set) var fileName: String?
    @Published var alertMessage: String?
    /// 画面側の一時的な状態（写真ライブラリで選んだ項目、ドラッグ中かどうか）
    @Published var pickerItem: PhotosPickerItem?
    @Published var isDropTargeted = false

    let engine: RenderEngine?

    var preset: FormatPreset { FormatPreset.preset(id: settings.presetID) }
    var hasPhoto: Bool { image != nil }

    init() {
        engine = RenderEngine()
        modelInstalled = engine?.depthEstimator.isInstalled ?? false
        if engine == nil {
            modelStatus = "Metalを初期化できませんでした"
        }
    }

    // MARK: - 読み込み

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            alertMessage = "ファイルを読み込めませんでした"
            return
        }
        fileName = url.deletingPathExtension().lastPathComponent
        load(data)
    }

    func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isBusy = true
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            isBusy = false
            alertMessage = "写真のデータを取得できませんでした"
            return
        }
        fileName = "photo"
        load(data)
    }

    private func load(_ data: Data) {
        guard let engine else { return }
        isBusy = true
        // ViewModel はアプリの間ずっと生きているので強参照で問題ない
        engine.load(data: data) { info in
            Task { @MainActor in
                self.loadInfo = info
                if let message = info.message { self.alertMessage = message }
                var next = self.settings
                next.focus = info.autoFocus
                next.depthSource = info.hasEmbeddedDepth ? .embedded : .estimated
                next.mode = .result
                self.settings = next
                self.requestRender()
            }
        }
    }

    // MARK: - 操作

    /// 表示中の画像（切り出し後）の座標でクリックされた位置にピントを合わせる
    func setFocus(_ point: CGPoint) {
        let crop = output.cropRect
        let x = crop.minX + min(max(point.x, 0), 1) * crop.width
        let y = crop.minY + min(max(point.y, 0), 1) * crop.height
        var next = settings
        next.focus = CGPoint(x: x, y: y)
        next.mode = .result
        settings = next
    }

    /// 開いたときに決めたピント位置に戻す
    func resetFocus() {
        guard let info = loadInfo else { return }
        var next = settings
        next.focus = info.autoFocus
        next.mode = .result
        settings = next
    }

    /// ピント位置を表示中の画像（切り出し後）の座標にしたもの。範囲外なら nil
    var focusInView: CGPoint? {
        let crop = output.cropRect
        guard crop.width > 0, crop.height > 0 else { return nil }
        let x = (settings.focus.x - crop.minX) / crop.width
        let y = (settings.focus.y - crop.minY) / crop.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    func requestRender() {
        guard let engine, loadInfo != nil else { return }
        isBusy = true
        engine.render(settings) { result in
            Task { @MainActor in
                self.output = result
                if let image = result.image { self.image = image }
                self.isBusy = false
            }
        }
    }

    func installModel() {
        guard let engine else { return }
        modelStatus = "モデルをダウンロード中"
        Task {
            do {
                try await engine.depthEstimator.install { message in
                    Task { @MainActor in self.modelStatus = message }
                }
                modelInstalled = true
                modelStatus = nil
                requestRender()
            } catch {
                modelStatus = "導入に失敗しました：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 書き出し

    func showExportPanel() {
        guard let engine, hasPhoto else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .heic, .tiff]
        panel.nameFieldStringValue = "\(fileName ?? "photo")_\(settings.presetID)_F\(String(format: "%g", settings.fNumber)).jpg"
        panel.message = "拡張子で形式が決まります（.jpg / .heic / .tif）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        engine.export(settings, to: url) { error in
            Task { @MainActor in
                self.isExporting = false
                self.alertMessage = error ?? "書き出しました：\(url.lastPathComponent)"
            }
        }
    }
}
