import AppKit

/// 组件一键安装：首次打开时、菜单“组件…”里、或用到某功能缺组件时调用。
/// 没有 Homebrew 时打开终端运行官方安装脚本（可选国内镜像），装好后自动继续安装组件。
enum Setup {
    /// 正在安装时，菜单里显示状态、避免重复安装
    private(set) static var isInstalling = false
    private static var brewPoll: Timer?

    // MARK: - 镜像

    /// 中国大陆网络下用中科大 Homebrew 镜像、清华 PyPI 镜像
    static var brewEnv: [String: String] {
        var env = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"]
        if Settings.useChinaMirror {
            env["HOMEBREW_BREW_GIT_REMOTE"] = "https://mirrors.ustc.edu.cn/brew.git"
            env["HOMEBREW_BOTTLE_DOMAIN"] = "https://mirrors.ustc.edu.cn/homebrew-bottles"
            env["HOMEBREW_API_DOMAIN"] = "https://mirrors.ustc.edu.cn/homebrew-bottles/api"
        }
        return env
    }

    static var pipIndexArgs: [String] {
        Settings.useChinaMirror ? ["-i", "https://pypi.tuna.tsinghua.edu.cn/simple"] : []
    }

    /// 大致下载量（给用户心里有数）
    static func approxSize(_ tools: [Tool]) -> String {
        let mb = tools.reduce(0) { sum, t in
            switch t {
            case .libreoffice: return sum + 750
            case .ffmpeg: return sum + 150
            case .ghostscript: return sum + 60
            case .pdf2docx: return sum + 60
            case .cwebp, .pngquant: return sum + 5
            }
        }
        return mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000) : "\(mb) MB"
    }

    static var missing: [Tool] { Tool.allCases.filter { !$0.isInstalled } }

    // MARK: - 首次打开 / 菜单

    /// 询问是否安装全部缺少的组件
    static func offerInstallAll(silentIfComplete: Bool = false) {
        Settings.didOfferComponents = true
        let tools = missing
        guard !tools.isEmpty else {
            if !silentIfComplete {
                HUD.shared.show(t("所有组件都已安装 ✓", "All components installed ✓"))
            }
            return
        }
        guard !isInstalling else {
            HUD.shared.show(t("组件正在安装中…", "Components are being installed…"), symbol: "hourglass")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("安装转换组件", "Install components")
        let list = tools.map { "• \($0.displayName)：\($0.purpose.text)" }.joined(separator: "\n")
        alert.informativeText = t("""
            这些功能需要额外的组件：
            \(list)

            一共大约 \(approxSize(tools))，视网速需要 5~20 分钟，装好后就不用再管了。
            照片压缩、图片转换、PDF 合并拆分等不需要组件，现在就能用。
            """, """
            These features need extra components:
            \(list)

            About \(approxSize(tools)) in total, 5–20 minutes depending on your network. Only needed once.
            Photo compression, image conversion and PDF merge/split work without them.
            """)
        alert.addButton(withTitle: t("现在安装", "Install Now"))
        alert.addButton(withTitle: t("以后再说", "Later"))
        let mirror = NSButton(checkboxWithTitle: t("使用国内镜像（中国大陆网络推荐）", "Use mirrors in mainland China"),
                              target: nil, action: nil)
        mirror.state = Settings.useChinaMirror ? .on : .off
        alert.accessoryView = mirror
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Settings.useChinaMirror = mirror.state == .on
        install(tools) { _ in }
    }

    /// 菜单“组件…”：列出每个组件的状态
    static func showStatus() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("转换组件", "Components")
        let brewLine = Deps.brew != nil ? "✓ Homebrew" : t("✗ Homebrew（安装组件需要它）", "✗ Homebrew (needed to install components)")
        let lines = Tool.allCases.map { "\($0.isInstalled ? "✓" : "✗") \($0.displayName)：\($0.purpose.text)" }
        alert.informativeText = ([brewLine] + lines).joined(separator: "\n")
            + (isInstalling ? t("\n\n正在安装中…", "\n\nInstalling…") : "")
        if !missing.isEmpty && !isInstalling {
            alert.addButton(withTitle: t("安装缺少的组件", "Install Missing"))
            alert.addButton(withTitle: t("关闭", "Close"))
            if alert.runModal() == .alertFirstButtonReturn { offerInstallAll() }
        } else {
            alert.addButton(withTitle: t("好", "OK"))
            alert.runModal()
        }
    }

    // MARK: - 安装

    /// 安装指定组件（需要时先装 Homebrew），完成后在主线程回调是否全部成功
    static func install(_ tools: [Tool], completion: @escaping (Bool) -> Void) {
        guard !isInstalling else { return completion(false) }
        let needsBrew = tools.contains { $0 != .pdf2docx }
        if needsBrew && Deps.brew == nil {
            installHomebrew { ok in
                if ok { install(tools, completion: completion) } else { completion(false) }
            }
            return
        }

        isInstalling = true
        // 小的先装，LibreOffice 最大放最后
        let order: [Tool] = [.pngquant, .cwebp, .ghostscript, .pdf2docx, .ffmpeg, .libreoffice]
        let queue = order.filter { tools.contains($0) && !$0.isInstalled }
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [String] = []
            for (i, tool) in queue.enumerated() {
                DispatchQueue.main.async {
                    HUD.shared.progress(t("正在安装 \(tool.displayName)（\(i + 1)/\(queue.count)）…",
                                          "Installing \(tool.displayName) (\(i + 1)/\(queue.count))…"))
                }
                do { try Deps.install(tool) } catch { failed.append(tool.displayName) }
            }
            DispatchQueue.main.async {
                isInstalling = false
                if failed.isEmpty {
                    HUD.shared.show(t("组件安装完成，所有功能都能用了 🍊", "All set — every feature is ready 🍊"),
                                    duration: 4)
                } else {
                    HUD.shared.show(t("\(failed.joined(separator: "、")) 安装失败，检查网络后可在菜单“组件…”里重试",
                                      "Failed: \(failed.joined(separator: ", ")). Retry from the Components… menu."),
                                    symbol: "xmark.octagon.fill", duration: 6)
                }
                completion(failed.isEmpty)
            }
        }
    }

    /// 没有 Homebrew：打开终端运行安装脚本（需要输入一次开机密码），装好后自动继续
    static func installHomebrew(then: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("需要先安装 Homebrew", "Homebrew is needed first")
        alert.informativeText = t("""
            Homebrew 是 Mac 上常用的软件安装工具，Peel 用它来安装转换组件。

            点“打开终端安装”后会弹出一个终端窗口：
            1. 按提示输入开机密码（输入时不显示字符），按回车；
            2. 再按一次回车确认；
            3. 等它跑完（可能会顺带安装苹果的命令行工具，需要几分钟）。

            装好后 Peel 会自动继续安装组件，不用回来点。
            """, """
            Homebrew is a common Mac package manager; Peel uses it to install components.

            A Terminal window will open:
            1. Enter your Mac password when asked (it won't show) and press Return;
            2. Press Return again to confirm;
            3. Wait for it to finish (it may also install Apple's Command Line Tools).

            Peel continues automatically once Homebrew is installed.
            """)
        alert.addButton(withTitle: t("打开终端安装", "Open Terminal"))
        alert.addButton(withTitle: t("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return then(false) }

        let mirror = Settings.useChinaMirror
        let exports = mirror ? brewEnv.map { "export \($0.key)=\"\($0.value)\"" }.sorted().joined(separator: "\n") : ""
        let scriptURL = mirror ? "https://mirrors.ustc.edu.cn/misc/brew-install.sh"
                               : "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
        let command = """
        #!/bin/bash
        clear
        echo "🍊 Peel：正在安装 Homebrew"
        echo "   需要时请输入开机密码（输入时不显示），然后按回车。"
        echo
        \(exports)
        /bin/bash -c "$(curl -fsSL \(scriptURL))"
        echo
        if [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ]; then
          echo "✓ Homebrew 安装完成。可以关闭这个窗口，Peel 会自动继续安装组件。"
        else
          echo "✗ 安装没有完成。请检查网络后，在 Peel 菜单“组件…”里重试。"
        fi
        """
        do {
            let file = try Output.tempDir().appendingPathComponent("Install Homebrew for Peel.command")
            try command.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            return then(false)
        }

        // 每 5 秒看一次 Homebrew 装好没有，最多等 40 分钟
        HUD.shared.progress(t("等待 Homebrew 安装完成…（在终端窗口里操作）", "Waiting for Homebrew… (see Terminal)"))
        let start = Date()
        brewPoll?.invalidate()
        brewPoll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
            if Deps.brew != nil {
                timer.invalidate()
                then(true)
            } else if Date().timeIntervalSince(start) > 40 * 60 {
                timer.invalidate()
                HUD.shared.show(t("Homebrew 还没装好，可以稍后在菜单“组件…”里重试", "Homebrew isn't ready yet — retry from Components…"),
                                symbol: "xmark.octagon.fill", duration: 5)
                then(false)
            }
        }
    }
}
