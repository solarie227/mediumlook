import SwiftUI
import AppKit

@main
struct MediumLookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = EditorViewModel()

    init() {
        // `swift run` で起動したときも通常のアプリとしてDockに出す
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("中判ルック") {
            ContentView(vm: vm)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("開く…") { vm.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("書き出し…") { vm.showExportPanel() }
                    .keyboardShortcut("e")
                    .disabled(!vm.hasPhoto)
            }
            CommandGroup(after: .toolbar) {
                Button("仕上がり") { vm.settings.mode = .result }
                    .keyboardShortcut("1")
                Button("元画像") { vm.settings.mode = .original }
                    .keyboardShortcut("2")
                Button("深度") { vm.settings.mode = .depth }
                    .keyboardShortcut("3")
                Divider()
            }
        }
    }
}

/// ウインドウを閉じたらアプリも終了する（ウインドウなしで動き続け、開き直しても何も出ない状態を防ぐ）
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
