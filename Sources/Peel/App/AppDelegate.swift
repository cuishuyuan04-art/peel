import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let longPress = LongPressMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Jobs.setUp()
        if DebugRender.runIfRequested() { return }
        Output.cleanTemp()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = IconRenderer.menuBarImage()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // 提示气泡从菜单栏图标下方弹出
        HUD.shared.anchor = { [weak self] in self?.statusItem.button?.window?.frame }
        if CommandLine.arguments.contains("--hud-test") {   // 开发用：检查气泡位置
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let args = CommandLine.arguments
                let text = args.firstIndex(of: "--hud-test").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                HUD.shared.show(text ?? "已生成「photo_压缩.jpg」：5.8 MB → 1.2 MB（-80%）", duration: 3)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let v = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible })?.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "peel-hud.png"))
                }
                let icon = self.statusItem.button?.window?.frame ?? .zero
                for w in NSApp.windows where w.isVisible { print(type(of: w), w.level.rawValue, w.frame) }
                print("icon", icon)
                exit(0)
            }
        }

        longPress.onTrigger = { Trigger.fire(at: $0) }
        longPress.start()

        // 快捷键：截图、为选中的文件打开轮盘
        HotKey.shared.register(.snap, Settings.snapShortcut) { SnapController.shared.start() }
        HotKey.shared.register(.wheel, Settings.wheelShortcut) { WheelEntry.openForFinderSelection() }

        // 右键「服务 › 用 Peel 处理」
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()

        if CommandLine.arguments.contains("--settings") { SettingsWindow.open() }   // 开发用：启动即打开设置
        // 开发用：启动即打开涂黑编辑器（--redact-editor 文件）
        if let i = CommandLine.arguments.firstIndex(of: "--redact-editor"), CommandLine.arguments.indices.contains(i + 1) {
            let f = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            EditorWindow.open(.redact, file: f, title: LText("涂黑", "Redact"))
        }

        if !Settings.didPromptPermissions {
            Settings.didPromptPermissions = true
            requestPermissions()
        } else if !Settings.didOfferComponents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Setup.offerInstallAll(silentIfComplete: true) }
        }
    }

    /// 首次启动：说明用法，再请求辅助功能 + Finder 自动化权限
    private func requestPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("欢迎使用 Peel 🍊", "Welcome to Peel 🍊")
        alert.informativeText = t("""
            Peel 在屏幕右上角的菜单栏里运行，没有窗口。

            用法：在访达里按住一个文件不动 \(holdLabel(Settings.holdDuration))，旁边会弹出轮盘；继续把文件拖到扇区上松手，就会在原文件旁边生成转换或压缩后的副本。

            不想长按的话：在访达里选中文件后按 \(Settings.wheelShortcut.label)，或右键 › 服务 › 用 Peel 处理。

            截图：按 \(Settings.snapShortcut.label) 框选，截好后弹出轮盘，可以保存、复制、识别文字、钉在屏幕上。

            第一次使用需要两项权限：
            • 辅助功能：判断你按住的是不是文件
            • 控制“访达”：读取你选中的文件

            点“开始设置”后，在打开的设置里勾选 Peel 即可。
            """, """
            Peel lives in the menu bar — it has no window.

            How to use: in Finder, press and hold a file for \(holdLabel(Settings.holdDuration)) to open the wheel, then drag the file onto a sector and release. The result is saved next to the original.

            No long-press? Select files in Finder and press \(Settings.wheelShortcut.label), or right-click › Services › 用 Peel 处理.

            Screenshots: press \(Settings.snapShortcut.label), select an area, then save, copy, extract text or pin it from the wheel.

            Peel needs two permissions:
            • Accessibility: to tell whether you're holding a file
            • Control Finder: to read the selected files

            Click “Set Up” and enable Peel in the settings that open.
            """)
        alert.addButton(withTitle: t("开始设置", "Set Up"))
        alert.addButton(withTitle: t("稍后", "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            Setup.offerInstallAll(silentIfComplete: true)
            return
        }
        if !AXIsProcessTrusted() { FinderBridge.openAccessibilitySettings() }
        FinderBridge.fetchSelection(timeout: 60) { _ in }
        // 权限设置完，接着问要不要一键安装转换组件
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Setup.offerInstallAll(silentIfComplete: true)
        }
    }

    // MARK: - 菜单栏菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: t("Peel · 长按文件 \(holdLabel(Settings.holdDuration)) 弹出轮盘",
                                         "Peel · hold a file \(holdLabel(Settings.holdDuration)) for the wheel"),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        // 版本号（构建号 = 编译时间），用来确认正在用的是哪一版
        let info = Bundle.main.infoDictionary
        let version = NSMenuItem(title: t("版本", "Version") + " \(info?["CFBundleShortVersionString"] as? String ?? "?")"
                                    + "（\(info?["CFBundleVersion"] as? String ?? "?")）",
                                 action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(header)
        menu.addItem(version)
        // 彩蛋：按住 Option 打开菜单才看得到
        if NSEvent.modifierFlags.contains(.option) {
            menu.addItem(item("🍊 \(Self.credit)") {
                HUD.shared.show(Self.credit, symbol: "heart.fill", duration: 4)
            })
        }
        if let job = Jobs.label {
            menu.addItem(item(t("停止：\(job.zh)", "Stop: \(job.en)")) { Jobs.cancel() })
        }
        menu.addItem(.separator())

        menu.addItem(item(t("截图    \(Settings.snapShortcut.label)", "Screenshot    \(Settings.snapShortcut.label)")) {
            // 等菜单收起再开始框选
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { SnapController.shared.start() }
        })
        menu.addItem(item(t("选择文件打开轮盘…", "Open wheel with files…")) { [weak self] in
            self?.openWheelWithPicker()
        })
        menu.addItem(.separator())
        menu.addItem(item(t("启用长按触发", "Enable long-press"), checked: Settings.longPressEnabled) {
            Settings.longPressEnabled.toggle()
        })
        let settings = item(t("设置…", "Settings…")) { SettingsWindow.open() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(item(Setup.isInstalling ? t("组件（正在安装…）", "Components (installing…)")
                                              : t("组件…", "Components…")) { Setup.showStatus() })
        menu.addItem(item(t("使用说明…", "How to Use…")) { [weak self] in self?.requestPermissions() })
        menu.addItem(item(t("关于 Peel", "About Peel")) { Self.showAbout() })
        menu.addItem(item(t("退出 Peel", "Quit Peel")) { NSApp.terminate(nil) })
    }

    static let credit = "Produced by Shuyuan and his best friend - Claude :)"

    private static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        // 手动断成两行，避免 “Claude :)” 被单独挤到第二行
        let text = "Produced by Shuyuan\nand his best friend — Claude :)"
        let credits = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "Peel",
        ])
    }

    private func holdLabel(_ s: Double) -> String {
        let r = (s * 10).rounded() / 10
        let n = r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
        return t("\(n) 秒", "\(n)s")
    }

    private func openWheelWithPicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        WheelController.shared.show(at: NSPoint(x: screen.midX, y: screen.midY), files: panel.urls, mode: .click)
    }

    private func item(_ title: String, checked: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = BlockMenuItem(title: title, block: action)
        i.state = checked ? .on : .off
        return i
    }
}

/// 用闭包响应的菜单项
final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void

    init(title: String, block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() { block() }
}
