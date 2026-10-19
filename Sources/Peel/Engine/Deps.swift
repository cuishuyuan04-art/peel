import AppKit

/// 外部依赖：第一次用到时询问，再用 Homebrew（或 pip）安装
enum Tool: String, CaseIterable {
    case libreoffice, ghostscript, cwebp, pngquant, pdf2docx, ffmpeg

    var displayName: String {
        switch self {
        case .libreoffice: return "LibreOffice"
        case .ghostscript: return "Ghostscript"
        case .cwebp: return "WebP (cwebp)"
        case .pngquant: return "pngquant"
        case .pdf2docx: return "pdf2docx"
        case .ffmpeg: return "FFmpeg"
        }
    }

    var purpose: LText {
        switch self {
        case .libreoffice: return LText("转换 Office 文档", "Office conversions")
        case .ghostscript: return LText("压缩 PDF", "PDF compression")
        case .cwebp: return LText("输出 WebP 图片", "WebP output")
        case .pngquant: return LText("压缩 PNG 图片", "PNG compression")
        case .pdf2docx: return LText("PDF 转 Word", "PDF to Word")
        case .ffmpeg: return LText("音频、视频处理", "Audio & video")
        }
    }

    /// 已安装时返回可执行文件路径
    var path: String? {
        switch self {
        case .libreoffice:
            let p = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
            return FileManager.default.isExecutableFile(atPath: p) ? p : nil
        case .ghostscript: return Shell.which("gs")
        case .cwebp: return Shell.which("cwebp")
        case .pngquant: return Shell.which("pngquant")
        case .ffmpeg: return Shell.which("ffprobe") != nil ? Shell.which("ffmpeg") : nil
        case .pdf2docx:
            let marker = Deps.venv.appendingPathComponent(".pdf2docx-ok")
            return FileManager.default.fileExists(atPath: marker.path)
                ? Deps.venv.appendingPathComponent("bin/python").path : nil
        }
    }

    var isInstalled: Bool { path != nil }
}

enum Deps {
    static var venv: URL { Output.appSupport.appendingPathComponent("venv", isDirectory: true) }

    static var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 某个操作需要哪些工具
    static func required(for action: PeelAction, files: [URL]) -> [Tool] {
        var tools = Set<Tool>()
        for f in files {
            let kind = FileKind.of(f)
            let ext = FileKind.normalizedExt(f)
            if kind == .video || kind == .audio {
                tools.insert(.ffmpeg)
                continue
            }
            switch action {
            case .convert(let target):
                switch kind {
                case .image where target == "webp": tools.insert(.cwebp)
                case .pdf where target == "docx": tools.insert(.pdf2docx)
                case .document, .presentation, .spreadsheet:
                    if OfficeEngine.needsLibreOffice(ext: ext, target: target) { tools.insert(.libreoffice) }
                default: break
                }
            case .compress, .compressTo:
                if kind == .pdf { tools.insert(.ghostscript) }
                if ext == "png" { tools.insert(.pngquant) }
                if ext == "webp" { tools.insert(.cwebp) }
            default:
                break
            }
        }
        return Tool.allCases.filter { tools.contains($0) && !$0.isInstalled }
    }

    /// 确保工具都装好；缺的话弹窗询问并安装，装好后调用 then（主线程）
    static func ensure(_ missing: [Tool], then: @escaping () -> Void) {
        guard !missing.isEmpty else { return then() }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("需要先安装组件", "Components needed")
        let list = missing.map { "• \($0.displayName)：\($0.purpose.text)" }.joined(separator: "\n")
        alert.informativeText = t("这个操作需要：\n\(list)\n\n现在通过 Homebrew 自动安装吗？只需安装一次。",
                                  "This needs:\n\(list)\n\nInstall now via Homebrew? Only needed once.")
        alert.addButton(withTitle: t("安装", "Install"))
        alert.addButton(withTitle: t("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 统一走一键安装（没有 Homebrew 会先引导安装）
        Setup.install(missing) { ok in if ok { then() } }
    }

    static func install(_ tool: Tool) throws {
        func brewInstall(_ args: [String]) throws {
            guard let brew else { throw PeelError("没有找到 Homebrew", "Homebrew not found") }
            try Shell.run(brew, ["install"] + args, env: Setup.brewEnv)
        }
        switch tool {
        case .libreoffice: try brewInstall(["--cask", "libreoffice"])
        case .ghostscript: try brewInstall(["ghostscript"])
        case .cwebp: try brewInstall(["webp"])
        case .pngquant: try brewInstall(["pngquant"])
        case .ffmpeg: try brewInstall(["ffmpeg"])
        case .pdf2docx:
            // 优先 Homebrew / python.org 的 Python，其次系统自带的（需要命令行工具）
            guard let python = Shell.which("python3", extra: [
                "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            ]) else { throw PeelError("没有找到 Python 3", "Python 3 not found") }
            try Shell.run(python, ["-m", "venv", venv.path])
            // python.org 版 Python 常常没配好证书，用系统证书
            try Shell.run(venv.appendingPathComponent("bin/pip").path,
                          ["install", "--quiet", "--cert", "/etc/ssl/cert.pem"] + Setup.pipIndexArgs + ["pdf2docx"])
            FileManager.default.createFile(atPath: venv.appendingPathComponent(".pdf2docx-ok").path, contents: nil)
        }
    }
}
