import AppKit

/// 不用长按的入口：快捷键（为访达里选中的文件打开轮盘）、右键「服务 › 用 Peel 处理」
enum WheelEntry {

    /// 快捷键：读访达选中的文件，在鼠标处弹出轮盘（点选操作）
    static func openForFinderSelection() {
        let wheel = WheelController.shared
        if wheel.isVisible { wheel.hide(); return }      // 再按一次关闭
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderBridge.finderID else {
            HUD.shared.show(t("先在访达里选中文件，再按 \(Settings.wheelShortcut.label)",
                              "Select files in Finder, then press \(Settings.wheelShortcut.label)"),
                            symbol: "hand.point.up.left.fill", duration: 3)
            return
        }
        FinderBridge.fetchSelection(timeout: 3) { result in
            switch result {
            case .success(let urls) where !urls.isEmpty:
                Log.write("hotkey wheel: \(urls.map(\.lastPathComponent))")
                open(urls)
            case .success:
                HUD.shared.show(t("先在访达里选中文件", "Select files in Finder first"), symbol: "hand.point.up.left.fill")
            case .failure(.notAuthorized):
                HUD.shared.show(t("请在“系统设置 › 隐私与安全性 › 自动化”里允许 Peel 控制访达",
                                  "Allow Peel to control Finder in System Settings › Privacy & Security › Automation"),
                                symbol: "lock.fill", duration: 4)
                FinderBridge.openAutomationSettings()
            case .failure:
                HUD.shared.show(t("没能读取访达选中的文件，请再试一次", "Couldn't read Finder's selection — try again"),
                                symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// 在鼠标处为这些文件打开轮盘
    static func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        WheelController.shared.show(at: NSEvent.mouseLocation, files: urls, mode: .click)
    }
}

/// 右键「服务 › 用 Peel 处理」（Info.plist 里的 NSServices 指向这里）
final class ServiceProvider: NSObject {
    @objc func peelFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        Log.write("service: \(urls.map(\.lastPathComponent))")
        guard !urls.isEmpty else {
            error.pointee = "No files" as NSString
            return
        }
        DispatchQueue.main.async { WheelEntry.open(urls) }
    }
}
