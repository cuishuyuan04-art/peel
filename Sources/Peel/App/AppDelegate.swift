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

        // 开发用：启动即打开某个窗口，方便截图检查（--en 临时用英文界面）
        //   --settings  /  --editor redact|watermark|sign|crop|addBackground|idPhoto 文件
        let args = CommandLine.arguments
        if args.contains("--en") { Settings.langOverride = .en }
        if args.contains("--zh") { Settings.langOverride = .zh }
        if args.contains("--settings") { SettingsWindow.open() }
        if let i = args.firstIndex(of: "--onboarding") {
            OnboardingWindow.open(startAt: args.indices.contains(i + 1) ? Int(args[i + 1]) ?? 0 : 0)
        }
        if let i = args.firstIndex(of: "--editor"), args.indices.contains(i + 2) {
            let editors: [String: (PeelAction, LText)] = [
                "redact": (.redact, LText("涂黑", "Redact")), "watermark": (.watermark, LText("加水印", "Watermark")),
                "sign": (.sign, LText("签名", "Sign")), "crop": (.crop, LText("裁剪", "Crop")),
                "addBackground": (.addBackground, LText("加背景", "Add Background")),
                "idPhoto": (.idPhoto, LText("证件照", "ID Photo")),
            ]
            if let (action, title) = editors[args[i + 1]] {
                EditorWindow.open(action, file: URL(fileURLWithPath: args[i + 2]), title: title)
            }
        }

        if !Settings.didPromptPermissions {
            OnboardingWindow.open()     // 第一次启动：使用引导（选语言、权限、组件）
        } else if !Settings.didOfferComponents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Setup.offerInstallAll(silentIfComplete: true) }
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
        // 语言放在菜单里、标题中英都写：看不懂当前语言的人也能找到
        let langMenu = NSMenu()
        langMenu.addItem(item("中文", checked: Settings.lang == .zh) { Settings.lang = .zh })
        langMenu.addItem(item("English", checked: Settings.lang == .en) { Settings.lang = .en })
        let langItem = NSMenuItem(title: "语言 / Language", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)
        menu.addItem(.separator())
        menu.addItem(item(Setup.isInstalling ? t("组件（正在安装…）", "Components (installing…)")
                                              : t("组件…", "Components…")) { Setup.showStatus() })
        menu.addItem(item(t("使用引导…", "Getting Started…")) { OnboardingWindow.open() })
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
