import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    // Command Line Tools だけでもビルドできるよう、@State（新しいSDKではマクロ）は使わず ViewModel に持たせる
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        HSplitView {
            CanvasView(vm: vm, isDropTargeted: vm.isDropTargeted)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            InspectorView(vm: vm)
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 360)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    vm.showOpenPanel()
                } label: {
                    Label("開く", systemImage: "folder")
                }
                .help("ファイルを開く（⌘O）")

                PhotosPicker(selection: $vm.pickerItem, matching: .images, preferredItemEncoding: .current) {
                    Label("写真ライブラリ", systemImage: "photo.on.rectangle")
                }
                .help("写真ライブラリから選ぶ")

                Button {
                    vm.showExportPanel()
                } label: {
                    Label("書き出し", systemImage: "square.and.arrow.up")
                }
                .disabled(!vm.hasPhoto || vm.isExporting)
                .help("フル解像度で書き出す（⌘E）")
            }
        }
        .navigationTitle(vm.fileName ?? "中判ルック")
        .onChange(of: vm.pickerItem) { _, item in
            Task { await vm.load(item) }
        }
        .onDrop(of: [.fileURL], isTargeted: $vm.isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in vm.open(url) }
            }
            return true
        }
        .alert(vm.alertMessage ?? "", isPresented: Binding(
            get: { vm.alertMessage != nil },
            set: { if !$0 { vm.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }
}

// MARK: - 画像の表示

struct CanvasView: View {
    @ObservedObject var vm: EditorViewModel
    var isDropTargeted: Bool

    var body: some View {
        ZStack {
            Color(white: 0.12)

            if let image = vm.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            ZStack {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture(coordinateSpace: .local) { location in
                                        vm.setFocus(CGPoint(x: location.x / geo.size.width,
                                                            y: location.y / geo.size.height))
                                    }
                                if vm.settings.mode == .result {
                                    Circle()
                                        .stroke(.yellow, lineWidth: 1.5)
                                        .frame(width: 24, height: 24)
                                        .position(x: vm.settings.focus.x * geo.size.width,
                                                  y: vm.settings.focus.y * geo.size.height)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .padding(24)
            } else {
                ContentUnavailableView {
                    Label("写真を開く", systemImage: "camera.aperture")
                } description: {
                    Text("ファイルをここにドラッグするか、⌘Oで開きます。")
                }
                .foregroundStyle(.secondary)
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if vm.isBusy || vm.isExporting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if vm.isExporting { Text("書き出し中").font(.caption) }
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
            }
        }
    }
}

// MARK: - 設定パネル

struct InspectorView: View {
    @ObservedObject var vm: EditorViewModel

    var body: some View {
        Form {
            Section {
                Picker("表示", selection: $vm.settings.mode) {
                    Text("仕上がり").tag(ViewMode.result)
                    Text("元画像").tag(ViewMode.original)
                    Text("深度").tag(ViewMode.depth)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("フォーマット") {
                Picker("フォーマット", selection: $vm.settings.presetID) {
                    ForEach(FormatPreset.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .labelsHidden()

                VStack(alignment: .leading, spacing: 4) {
                    Text("絞り F\(vm.settings.fNumber, specifier: "%g")")
                    Slider(value: fStopIndex, in: 0...Double(Optics.fStops.count - 1), step: 1)
                }

                Toggle(isOn: $vm.settings.matchFOV) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("画角を合わせる")
                        Text("換算\(Int(vm.preset.equivalentFocal35.rounded()))mm・\(vm.preset.aspectLabel)に切り出し")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("深度") {
                Picker("深度", selection: $vm.settings.depthSource) {
                    Text("写真の深度").tag(DepthSource.embedded)
                    Text("推定").tag(DepthSource.estimated)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!(vm.loadInfo?.hasEmbeddedDepth ?? false))

                if vm.output.depthUsed == .estimated || !(vm.loadInfo?.hasEmbeddedDepth ?? true) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ピント位置までの距離 約\(vm.settings.subjectDistance, specifier: "%.1f")m")
                        Slider(value: logDistance, in: log(0.5)...log(20))
                        Text("推定した深度には距離の単位がないので、ボケの量はこの距離で決まります。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $vm.settings.refineEdges) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("輪郭を写真に合わせる")
                        Text("深度の境目を写真の明暗の境目にそろえ、被写体の縁のにじみを減らします。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if vm.settings.refineEdges {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("合わせ方 \(edgeStrengthLabel)")
                        Slider(value: $vm.settings.edgeStrength, in: 0...1, step: 0.25)
                        Text("細かくするほど枝や髪に沿いますが、模様の多い場所で深度がまだらになることがあります。⌘3で深度を確認できます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !vm.modelInstalled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("深度データがない写真には、推定モデル（約50MB）が必要です。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("推定モデルを導入") { vm.installModel() }
                            .disabled(vm.modelStatus != nil && !(vm.modelStatus?.hasPrefix("導入に失敗") ?? false))
                    }
                }
                if let status = vm.modelStatus {
                    Text(status).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("仕上げ") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ハイライトの粘り \(vm.settings.highlightBoost, specifier: "%.1f")")
                    Slider(value: $vm.settings.highlightBoost, in: 0...4, step: 0.5)
                }
            }

            Section("情報") {
                if let message = vm.output.message {
                    Text(message).foregroundStyle(.orange)
                }
                if let distance = vm.output.focusDistanceM {
                    LabeledContent("ピント距離", value: String(format: "約%.1fm", distance))
                }
                if let info = vm.loadInfo {
                    LabeledContent("元の画角", value: "換算\(Int(info.sourceFocal35))mm")
                    LabeledContent("元の解像度", value: "\(Int(info.sourceSize.width))×\(Int(info.sourceSize.height))")
                }
                if vm.hasPhoto {
                    LabeledContent("切り出し", value: String(format: "×%.2f", vm.output.cropFactor))
                    LabeledContent("処理時間", value: "\(Int(vm.output.milliseconds))ms")
                }
                Text("画像をクリックするとピント位置が変わります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var edgeStrengthLabel: String {
        switch vm.settings.edgeStrength {
        case ..<0.2: return "なめらか"
        case ..<0.4: return "やや なめらか"
        case ..<0.6: return "標準"
        case ..<0.8: return "やや細かく"
        default: return "細かく"
        }
    }

    private var fStopIndex: Binding<Double> {
        Binding(
            get: { Double(Optics.fStops.firstIndex(of: vm.settings.fNumber) ?? 2) },
            set: { vm.settings.fNumber = Optics.fStops[Int($0.rounded())] }
        )
    }

    private var logDistance: Binding<Double> {
        Binding(
            get: { log(vm.settings.subjectDistance) },
            set: { vm.settings.subjectDistance = (exp($0) * 10).rounded() / 10 }
        )
    }
}
