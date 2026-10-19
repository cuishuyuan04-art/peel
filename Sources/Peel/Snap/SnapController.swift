import AppKit
import Vision

/// 截图轮盘上的操作
enum SnapAction: Hashable {
    case save(URL?)     // 存到某个文件夹；nil = 弹出“选择位置”
    case copy
    case ocr
    case pin
}

/// 截图：快捷键 → 系统框选 → 复制到剪贴板 → 弹出截图轮盘。
/// 不会自动保存：只有在轮盘上选“保存”或把缩略图拖到某个文件夹，才会存成文件。
final class SnapController {
    static let shared = SnapController()

    /// 正在框选（期间不响应长按、不重复触发）
    private(set) var isCapturing = false
    /// 当前这张截图（临时文件）
    private(set) var current: URL?
    private(set) var image: NSImage?
    /// 是否已经对这张截图做过操作（关闭时没做过就提示“已复制”）
    private var handled = false

    func start() {
        guard !isCapturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            HUD.shared.show(t("截图需要“屏幕录制”权限：在系统设置里打开 Peel，然后重新打开 Peel",
                              "Screenshots need Screen Recording permission — enable Peel, then reopen it"),
                            symbol: "lock.fill", duration: 5)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            return
        }
        WheelController.shared.hide()
        isCapturing = true

        let url: URL
        do {
            url = try Output.tempDir().appendingPathComponent(Self.fileName())
        } catch {
            isCapturing = false
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // 系统自带的框选：十字光标、显示尺寸、Esc 取消
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-s", "-x", "-t", "png", url.path]
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.isCapturing = false
                guard Output.size(url) > 0, let img = NSImage(contentsOf: url) else {
                    Log.write("snap cancelled")
                    return
                }
                self.captured(url, image: img)
            }
        }
    }

    private func captured(_ url: URL, image: NSImage) {
        current = url
        self.image = image
        handled = false
        copyToClipboard(silently: true)
        let px = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()).map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? ""
        Log.write("snap captured \(px)")
        WheelController.shared.showSnapshot(at: NSEvent.mouseLocation, file: url, image: image, sizeLabel: px)
    }

    /// 即将执行某个操作（在轮盘收起之前调用，避免关闭时误提示“已复制”）
    func willPerform() { handled = true }

    /// 轮盘关闭时调用：没做任何操作就提示截图在剪贴板里
    func wheelClosed() {
        guard current != nil, !handled else { return }
        handled = true
        HUD.shared.show(t("截图已复制到剪贴板", "Screenshot copied to clipboard"), symbol: "doc.on.clipboard.fill")
    }

    /// 缩略图被拖到了轮盘外（比如访达文件夹、微信）：算作已处理
    func draggedOut() {
        handled = true
        HUD.shared.show(t("截图已拖出", "Screenshot dropped"))
    }

    // MARK: - 操作

    func perform(_ action: SnapAction) {
        guard let url = current else { return }
        handled = true
        switch action {
        case .copy:
            copyToClipboard(silently: false)
        case .save(let folder?):
            save(url, to: folder)
        case .save(nil):
            chooseAndSave(url)
        case .ocr:
            recognizeText(url)
        case .pin:
            if let image { PinWindow.show(image) }
        }
    }

    private func copyToClipboard(silently: Bool) {
        guard let image else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        if !silently { HUD.shared.show(t("已复制到剪贴板", "Copied to clipboard"), symbol: "doc.on.clipboard.fill") }
    }

    private func save(_ url: URL, to folder: URL) {
        let dst = Output.unique(folder.appendingPathComponent(url.lastPathComponent))
        do {
            try FileManager.default.copyItem(at: url, to: dst)
            Settings.lastSnapFolder = folder
            HUD.shared.show(t("已保存到「\(folder.lastPathComponent)」", "Saved to “\(folder.lastPathComponent)”"))
        } catch {
            HUD.shared.show(t("保存失败：\(error.localizedDescription)", "Save failed: \(error.localizedDescription)"),
                            symbol: "xmark.octagon.fill", duration: 4)
        }
    }

    private func chooseAndSave(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.png]
        panel.directoryURL = Settings.lastSnapFolder
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.level = .floating
        guard panel.runModal() == .OK, let dst = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
            try FileManager.default.copyItem(at: url, to: dst)
            Settings.lastSnapFolder = dst.deletingLastPathComponent()
            HUD.shared.show(t("已保存「\(dst.lastPathComponent)」", "Saved “\(dst.lastPathComponent)”"))
        } catch {
            HUD.shared.show(t("保存失败：\(error.localizedDescription)", "Save failed: \(error.localizedDescription)"),
                            symbol: "xmark.octagon.fill", duration: 4)
        }
    }

    /// 本机识别文字（中英文），结果复制到剪贴板
    private func recognizeText(_ url: URL) {
        HUD.shared.progress(t("正在识别文字…", "Recognizing text…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Self.ocr(url)
            DispatchQueue.main.async {
                guard let text, !text.isEmpty else {
                    HUD.shared.show(t("没有识别到文字", "No text found"), symbol: "text.viewfinder")
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                let count = text.filter { !$0.isWhitespace }.count
                HUD.shared.show(t("识别了 \(count) 个字，已复制", "Recognized \(count) characters — copied"),
                                symbol: "text.viewfinder", duration: 3)
            }
        }
    }

    static func ocr(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        try? VisionRunner.perform([request], on: VNImageRequestHandler(cgImage: cg))
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    static func fileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return t("截图 \(f.string(from: Date())).png", "Screenshot \(f.string(from: Date())).png")
    }
}
