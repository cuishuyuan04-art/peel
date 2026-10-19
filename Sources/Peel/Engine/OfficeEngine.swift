import AppKit

/// Word / PPT / Excel / iWork 文档转换
enum OfficeEngine {
    /// textutil（系统自带）能处理的文字文档
    private static let textutilSources: Set<String> = ["doc", "docx", "rtf", "txt", "html", "odt", "md"]
    private static let textutilTargets: Set<String> = ["docx", "txt", "html"]
    private static let iWork: [String: String] = ["pages": "Pages", "key": "Keynote", "numbers": "Numbers"]
    private static let libreOfficeLock = NSLock()

    static func needsLibreOffice(ext: String, target: String) -> Bool {
        if textutilSources.contains(ext) && textutilTargets.contains(target) { return false }
        if let app = iWork[ext], appInstalled(app) { return false }
        return true
    }

    private static func appInstalled(_ name: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.\(name)") != nil
    }

    /// 返回生成的文件（Keynote 导出图片时是一个文件夹）
    static func convert(_ src: URL, to target: String) throws -> [URL] {
        let ext = FileKind.normalizedExt(src)

        if let app = iWork[ext], appInstalled(app) {
            return try iWorkExport(src, app: app, target: target)
        }
        if textutilSources.contains(ext) && textutilTargets.contains(target) {
            return [try textutil(src, to: target)]
        }
        // 演示文稿 → 每页一张图片：先转 PDF，再逐页渲染
        if FileKind.of(src) == .presentation && target == "jpg" {
            let pdf = try libreOffice(src, to: "pdf", into: try Output.tempDir())
            return try PDFEngine.toImages(pdf, ext: "jpg", baseName: src.deletingPathExtension().lastPathComponent)
                .map { try relocate($0, besides: src) }
        }
        let tmp = try libreOffice(src, to: target, into: try Output.tempDir())
        return [try Output.place(tmp, at: Output.sibling(of: src, ext: target))]
    }

    /// PDFEngine.toImages 输出在 PDF 旁边（临时目录），挪到原文件旁边
    private static func relocate(_ url: URL, besides src: URL) throws -> URL {
        let dst = Output.unique(src.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent))
        return try Output.place(url, at: dst)
    }

    // MARK: - textutil

    private static func textutil(_ src: URL, to target: String) throws -> URL {
        let dst = Output.sibling(of: src, ext: target)
        var args = ["-convert", target, "-output", dst.path]
        if FileKind.normalizedExt(src) == "md" { args += ["-format", "txt"] }
        args.append(src.path)
        do {
            try Shell.run("/usr/bin/textutil", args)
        } catch {
            throw PeelError("「\(src.lastPathComponent)」转换失败", "Failed to convert “\(src.lastPathComponent)”")
        }
        return dst
    }

    // MARK: - LibreOffice

    private static func filter(for target: String) -> String {
        switch target {
        case "docx": return "docx:MS Word 2007 XML"
        case "pptx": return "pptx:Impress MS PowerPoint 2007 XML"
        case "xlsx": return "xlsx:Calc MS Excel 2007 XML"
        case "csv": return "csv:Text - txt - csv (StarCalc):44,34,76,1"
        case "txt": return "txt:Text (encoded):UTF8"
        case "html": return "html:XHTML Writer File:UTF8"
        default: return target
        }
    }

    /// 转换到临时目录，返回生成的文件
    private static func libreOffice(_ src: URL, to target: String, into dir: URL) throws -> URL {
        guard let soffice = Tool.libreoffice.path else { throw PeelError("缺少 LibreOffice", "LibreOffice missing") }
        // 独立的配置目录，不和用户自己打开的 LibreOffice 冲突
        let profile = Output.appSupport.appendingPathComponent("lo-profile", isDirectory: true)
        // 同一个配置目录同时只能有一个 LibreOffice 在用
        libreOfficeLock.lock()
        defer { libreOfficeLock.unlock() }
        installFontSubstitutions(profile)
        do {
            try Shell.run(soffice, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
                                    "--convert-to", filter(for: target), "--outdir", dir.path, src.path],
                          env: ["FONTCONFIG_FILE": fontconfigFile().path])
        } catch {
            throw PeelError("「\(src.lastPathComponent)」转换失败", "Failed to convert “\(src.lastPathComponent)”")
        }
        let produced = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let out = produced.first(where: { $0.pathExtension.lowercased() == target }) ?? produced.first else {
            throw PeelError("「\(src.lastPathComponent)」转换失败", "Failed to convert “\(src.lastPathComponent)”")
        }
        return out
    }

    private static let fontTableVersion = 2

    /// Windows 中文字体 → macOS 自带字体（仅在缺字体时）。没有这张表，LibreOffice 会换成不含中文的字体，中文变方框
    private static let fontPairs: [(String, String)] = {
        let pingfang = ["微软雅黑", "Microsoft YaHei", "微软雅黑 Light", "Microsoft YaHei UI", "等线", "DengXian",
                        "黑体", "SimHei", "华文黑体", "STXihei"]
        let songti = ["宋体", "SimSun", "新宋体", "NSimSun", "华文宋体", "宋体-简", "方正书宋_GBK"]
        let kaiti = ["楷体", "KaiTi", "楷体_GB2312", "华文楷体"]
        let fangsong = ["仿宋", "FangSong", "仿宋_GB2312", "华文仿宋"]
        return pingfang.map { ($0, "PingFang SC") } + songti.map { ($0, "Songti SC") }
            + kaiti.map { ($0, "Kaiti SC") } + fangsong.map { ($0, "STFangsong") }
    }()

    /// 无界面模式下 LibreOffice 靠 fontconfig 找字体，默认只看得到它自带的字体。
    /// 这里把 macOS 的字体目录（包括按需下载的苹方、宋体等）告诉它
    private static func fontconfigFile() -> URL {
        let fm = FileManager.default
        var dirs = ["/System/Library/Fonts", "/Library/Fonts", NSHomeDirectory() + "/Library/Fonts"]
        // 装了 Microsoft Office 时，用它自带的原版字体（微软雅黑、宋体、Calibri…），排版和 Word 里一致
        for app in ["Microsoft Word", "Microsoft PowerPoint", "Microsoft Excel"] {
            let d = "/Applications/\(app).app/Contents/Resources/DFonts"
            if fm.fileExists(atPath: d) {
                dirs.append(d)
                break
            }
        }
        let assets = "/System/Library/AssetsV2"
        let fontAssets = ((try? fm.contentsOfDirectory(atPath: assets)) ?? [])
            .filter { $0.hasPrefix("com_apple_MobileAsset_Font") }
            .map { "\(assets)/\($0)" }
        dirs += fontAssets
        let cache = Output.appSupport.appendingPathComponent("fontconfig-cache").path
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
        <fontconfig>
        \(dirs.map { "  <dir>\($0)</dir>" }.joined(separator: "\n"))
          <cachedir>\(cache)</cachedir>
        </fontconfig>
        """
        let url = Output.appSupport.appendingPathComponent("fonts.conf")
        if (try? String(contentsOf: url, encoding: .utf8)) != xml {
            try? xml.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    private static func installFontSubstitutions(_ profile: URL) {
        let fm = FileManager.default
        let userDir = profile.appendingPathComponent("user", isDirectory: true)
        let xcu = userDir.appendingPathComponent("registrymodifications.xcu")
        var content = (try? String(contentsOf: xcu, encoding: .utf8)) ?? """
        <?xml version="1.0" encoding="UTF-8"?>
        <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        </oor:items>
        """
        // 版本号变了就重写（去掉旧版写入的条目）
        let marker = "Peel_font\(fontTableVersion)_"
        guard !content.contains(marker) else { return }
        content = content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("Peel_font") }
            .joined(separator: "\n")
        guard let end = content.range(of: "</oor:items>") else { return }

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        var items = #"<item oor:path="/org.openoffice.Office.Common/Font/Substitution"><prop oor:name="Replacement" oor:op="fuse"><value>true</value></prop></item>"# + "\n"
        for (i, pair) in fontPairs.enumerated() {
            // Always = false：只在原字体找不到时才替换（装了 Office 就用原版字体）
            items += #"<item oor:path="/org.openoffice.Office.Common/Font/Substitution/FontPairs"><node oor:name="\#(marker)\#(i)" oor:op="replace">"#
                + #"<prop oor:name="Always" oor:op="fuse"><value>false</value></prop>"#
                + #"<prop oor:name="OnScreenOnly" oor:op="fuse"><value>false</value></prop>"#
                + #"<prop oor:name="ReplaceFont" oor:op="fuse"><value>\#(esc(pair.0))</value></prop>"#
                + #"<prop oor:name="SubstituteFont" oor:op="fuse"><value>\#(esc(pair.1))</value></prop>"#
                + "</node></item>\n"
        }
        content.insert(contentsOf: items, at: end.lowerBound)
        try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        try? content.write(to: xcu, atomically: true, encoding: .utf8)
    }

    // MARK: - iWork（Pages / Keynote / Numbers 自己导出，效果最好）

    private static func iWorkExport(_ src: URL, app: String, target: String) throws -> [URL] {
        // Pages 不能直接导出 HTML：先导出 Word 再转
        if app == "Pages" && target == "html" {
            let docx = try iWorkExport(src, app: app, target: "docx")[0]
            defer { try? FileManager.default.removeItem(at: docx) }
            return [try textutil(docx, to: "html")]
        }

        let format: String
        var options = ""
        var dst = Output.sibling(of: src, ext: target)
        switch (app, target) {
        case (_, "pdf"): format = "PDF"
        case ("Pages", "docx"): format = "Microsoft Word"
        case ("Pages", "txt"): format = "unformatted text"
        case ("Keynote", "pptx"): format = "Microsoft PowerPoint"
        case ("Keynote", "jpg"):
            format = "slide images"
            options = " with properties {image format:JPEG}"
            dst = Output.unique(src.deletingLastPathComponent()
                .appendingPathComponent("\(src.deletingPathExtension().lastPathComponent) (JPG)"))
        case ("Numbers", "xlsx"): format = "Microsoft Excel"
        case ("Numbers", "csv"): format = "CSV"
        default:
            throw PeelError("\(app) 不支持导出为 \(target.uppercased())", "\(app) can't export to \(target.uppercased())")
        }

        let script = """
        on run argv
            set src to POSIX file (item 1 of argv)
            set dst to POSIX file (item 2 of argv)
            tell application "\(app)"
                set d to open src
                export d to dst as \(format)\(options)
                close d saving no
            end tell
        end run
        """
        do {
            try Shell.run("/usr/bin/osascript", ["-e", script, src.path, dst.path])
        } catch let e as ToolFailure where e.output.contains("-1743") {
            throw PeelError("请在“系统设置 › 隐私与安全性 › 自动化”里允许 Peel 控制 \(app)",
                            "Allow Peel to control \(app) in System Settings › Privacy & Security › Automation")
        } catch {
            throw PeelError("\(app) 导出失败", "\(app) export failed")
        }
        return [dst]
    }
}
