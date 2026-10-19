import AppKit
import SwiftUI

/// 设置窗口：长按、快捷键、语言、权限。菜单栏菜单里只留常用操作
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static var current: SettingsWindow?
    private let window: NSWindow

    static func open() {
        if let current {
            NSApp.activate(ignoringOtherApps: true)
            current.window.makeKeyAndOrderFront(nil)
            return
        }
        let holder = SettingsWindow()
        current = holder
        NSApp.activate(ignoringOtherApps: true)
        holder.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = t("Peel 设置", "Peel Settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        let size = NSSize(width: 480, height: 640)
        window.contentView = NSHostingView(rootView: SettingsView().frame(width: size.width, height: size.height))
        window.setContentSize(size)
        window.center()
        // 从菜单栏切换语言后，标题跟着变
        langObserver = NotificationCenter.default.addObserver(forName: Settings.langChanged, object: nil, queue: .main) {
            [weak window] _ in window?.title = t("Peel 设置", "Peel Settings")
        }
    }

    private var langObserver: NSObjectProtocol?

    func windowWillClose(_ notification: Notification) {
        if let langObserver { NotificationCenter.default.removeObserver(langObserver) }
        if SettingsWindow.current === self { SettingsWindow.current = nil }
    }
}

private struct SettingsView: View {
    /// 语言在菜单栏里切换；切换后整页重绘
    @State private var lang = Settings.lang
    @State private var longPress = Settings.longPressEnabled
    @State private var hold = Settings.holdDuration
    @State private var dwell = Settings.dwellDuration
    @State private var snapKey = Shortcut.presets.firstIndex(of: Settings.snapShortcut) ?? 0
    @State private var wheelKey = Shortcut.wheelPresets.firstIndex(of: Settings.wheelShortcut) ?? 0
    @State private var mirror = Settings.useChinaMirror

    var body: some View {
        Form {
            Section(t("长按", "Long-press")) {
                Toggle(t("在访达里长按文件弹出轮盘", "Hold a file in Finder to open the wheel"), isOn: $longPress)
                    .onChange(of: longPress) { Settings.longPressEnabled = $0 }
                slider(t("长按时长", "Hold duration"), value: $hold, range: 0.5...3.0,
                       defaultValue: Settings.defaultHold) { Settings.holdDuration = $0 }
                    .disabled(!longPress)
                slider(t("悬停展开等待", "Hover-to-open delay"), value: $dwell, range: 0.3...1.5,
                       defaultValue: Settings.defaultDwell) { Settings.dwellDuration = $0 }
            }

            Section {
                Picker(t("截图", "Screenshot"), selection: $snapKey) {
                    ForEach(Shortcut.presets.indices, id: \.self) { Text(Shortcut.presets[$0].label).tag($0) }
                }
                .onChange(of: snapKey) { i in
                    let sc = Shortcut.presets[i]
                    Settings.snapShortcut = sc
                    HotKey.shared.register(.snap, sc) { SnapController.shared.start() }
                }
                Picker(t("打开轮盘", "Open wheel"), selection: $wheelKey) {
                    ForEach(Shortcut.wheelPresets.indices, id: \.self) { Text(Shortcut.wheelPresets[$0].label).tag($0) }
                }
                .onChange(of: wheelKey) { i in
                    let sc = Shortcut.wheelPresets[i]
                    Settings.wheelShortcut = sc
                    HotKey.shared.register(.wheel, sc) { WheelEntry.openForFinderSelection() }
                }
            } header: {
                Text(t("快捷键", "Shortcuts"))
            } footer: {
                Text(t("打开轮盘：先在访达里选中文件再按。也可以右键文件 › 服务 › 用 Peel 处理。",
                       "Open wheel: select files in Finder first. Or right-click › Services › 用 Peel 处理."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section(t("通用", "General")) {
                Toggle(t("安装组件时使用国内镜像", "Use China mirrors when installing components"), isOn: $mirror)
                    .onChange(of: mirror) { Settings.useChinaMirror = $0 }
            }

            Section(t("权限与入口", "Permissions")) {
                HStack {
                    Button(t("检查访达访问权限", "Check Finder access")) {
                        FinderBridge.fetchSelection(timeout: 60) { result in
                            if case .failure(.notAuthorized) = result { FinderBridge.openAutomationSettings() }
                            else { HUD.shared.show(t("访达访问正常", "Finder access OK")) }
                        }
                    }
                    Button(t("右键服务设置…", "Services settings…")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .id(lang)
        .onReceive(NotificationCenter.default.publisher(for: Settings.langChanged)) { _ in lang = Settings.lang }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        defaultValue: Double, save: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: t("%.1f 秒", "%.1fs"), value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
                Button(t("默认", "Default")) { value.wrappedValue = defaultValue }
                    .controlSize(.small)
                    .disabled(abs(value.wrappedValue - defaultValue) < 0.05)
            }
            Slider(value: value, in: range, step: 0.1).labelsHidden()
        }
        .onChange(of: value.wrappedValue) { save($0) }
    }
}
