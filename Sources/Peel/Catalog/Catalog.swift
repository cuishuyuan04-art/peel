import Foundation

/// 根据选中的文件决定轮盘上出现哪些扇区（对应需求功能表）
enum Catalog {

    /// 还没拿到文件时的占位轮盘（等待拖入）
    static func placeholder() -> WheelNode {
        WheelNode(title: LText("拖动文件", "Drag the file"), symbol: "hand.draw")
    }

    /// 截图轮盘：保存（展开选位置）、复制、识别文字、钉在屏幕上
    static func snapRoot(sizeLabel: String) -> WheelNode {
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        var places: [WheelNode] = []
        if let desktop { places.append(leaf(LText("桌面", "Desktop"), "menubar.dock.rectangle", .snap(.save(desktop)))) }
        if let downloads { places.append(leaf(LText("下载", "Downloads"), "arrow.down.circle", .snap(.save(downloads)))) }
        if let last = Settings.lastSnapFolder, last != desktop, last != downloads,
           fm.fileExists(atPath: last.path) {
            var n = leaf(LText(last.lastPathComponent), "folder", .snap(.save(last)))
            n.detail = LText("上次位置", "Last used")
            places.append(n)
        }
        places.append(leaf(LText("选择位置…", "Choose…"), "folder.badge.plus", .snap(.save(nil))))

        return WheelNode(title: LText("截图 · \(sizeLabel)", "Screenshot · \(sizeLabel)"), symbol: "camera.viewfinder",
                         children: [
                            WheelNode(title: LText("保存", "Save"), symbol: "square.and.arrow.down", children: places),
                            leaf(LText("复制", "Copy"), "doc.on.doc", .snap(.copy)),
                            leaf(LText("识别文字", "Copy Text"), "text.viewfinder", .snap(.ocr)),
                            leaf(LText("钉在屏幕上", "Pin"), "pin", .snap(.pin)),
                         ])
    }

    static func root(for files: [URL]) -> WheelNode {
        guard !files.isEmpty else { return placeholder() }

        let kinds = Set(files.map(FileKind.of))
        let exts = Set(files.map(FileKind.normalizedExt))
        let total = totalSize(files)
        let multi = files.count > 1

        var cats: [WheelNode] = []
        if kinds.count == 1, let kind = kinds.first {
            switch kind {
            case .document:
                cats = [convert(["pdf", "docx", "txt", "html"], from: exts)]
            case .presentation:
                cats = [convert(["pdf", "slides-jpg", "pptx"], from: exts)]
            case .spreadsheet:
                cats = [convert(["pdf", "csv", "xlsx"], from: exts)]
            case .pdf:
                if multi { cats.append(mergeToPDF()) }
                cats.append(convert(["docx", "txt", "jpg", "png"], from: exts))
                cats.append(compress(total: total, ratios: (0.8, 0.5, 0.3), largest: largest(files)))
                if !multi { cats.append(pdfEdit()) }
            case .image:
                if multi { cats.append(mergeToPDF()) }
                cats.append(convert(["jpg", "png", "webp", "heic", "pdf"], from: exts))
                cats.append(compress(total: total, ratios: (0.7, 0.45, 0.25),
                                     largest: exts.contains("gif") ? nil : largest(files)))
                if !multi { cats.append(imageEdit()) }
            case .video:
                cats.append(convert(["mp4", "mov", "gif"], from: exts))
                cats.append(compress(total: total, ratios: (0.6, 0.35, 0.2)))
                cats.append(WheelNode(
                    title: LText("提取音频", "Extract Audio"), symbol: "waveform",
                    children: [
                        leaf("MP3", "music.note", .extractAudio(to: "mp3")),
                        leaf("M4A", "music.note", .extractAudio(to: "m4a")),
                    ]))
            case .audio:
                cats.append(convert(["mp3", "m4a"], from: exts))
                cats.append(compress(total: total, ratios: (0.75, 0.5, 0.35)))
            case .other:
                cats = [zip()]
            }
        } else if kinds.isSubset(of: [.document, .presentation, .spreadsheet]) {
            // 混合的 Office 文档：都能转 PDF
            cats = [leaf("PDF", "doc.richtext", .convert(to: "pdf")), zip()]
        } else {
            cats = [zip()]
        }

        let title = multi
            ? LText("\(files.count) 个文件", "\(files.count) files")
            : LText(files[0].lastPathComponent)

        // 只有一个分类时直接展开，少点一层
        if cats.count == 1, cats[0].isCategory {
            return WheelNode(title: title, symbol: "doc", children: cats[0].children)
        }
        return WheelNode(title: title, symbol: "doc", children: cats)
    }

    // MARK: - 分类构造

    private static func convert(_ targets: [String], from exts: Set<String>) -> WheelNode {
        // 源文件格式全都一样时，不显示“转成自己”
        let skip: String? = exts.count == 1 ? exts.first : nil
        let kids = targets.filter { $0 != skip }.map { target -> WheelNode in
            var n = formatLeaf(target)
            // PDF 转 Word 对扫描件/复杂排版效果有限
            if exts == ["pdf"], target == "docx" {
                n.detail = LText("效果不保证", "Best effort")
            }
            return n
        }
        return WheelNode(title: LText("转为…", "Convert"), symbol: "arrow.triangle.2.circlepath", children: kids)
    }

    private static func formatLeaf(_ target: String) -> WheelNode {
        switch target {
        case "pdf":
            return leaf("PDF", "doc.richtext", .convert(to: "pdf"))
        case "docx":
            return leaf("DOCX", "doc.text", .convert(to: "docx"))
        case "txt":
            return leaf("TXT", "doc.plaintext", .convert(to: "txt"))
        case "html":
            return leaf("HTML", "chevron.left.forwardslash.chevron.right", .convert(to: "html"))
        case "slides-jpg":
            var n = leaf(LText("图片", "Images"), "rectangle.on.rectangle", .convert(to: "jpg"))
            n.detail = LText("每页一张", "One per slide")
            return n
        case "pptx":
            return leaf("PPTX", "rectangle.on.rectangle.angled", .convert(to: "pptx"))
        case "csv", "xlsx":
            return leaf(target.uppercased(), "tablecells", .convert(to: target))
        case "jpg", "png", "webp", "heic":
            return leaf(target.uppercased(), "photo", .convert(to: target))
        case "mp4", "mov":
            return leaf(target.uppercased(), "film", .convert(to: target))
        case "gif":
            var n = leaf("GIF", "photo.stack", .convert(to: "gif"))
            n.detail = LText("最长 30 秒", "Up to 30s")
            return n
        case "mp3", "m4a":
            return leaf(target.uppercased(), "music.note", .convert(to: target))
        default:
            return leaf(target.uppercased(), "doc", .convert(to: target))
        }
    }

    private static func largest(_ files: [URL]) -> Int64 {
        files.map(Output.size).max() ?? 0
    }

    /// largest：最大那个文件的大小；给了就加“指定大小”（只列比它小的目标）
    private static func compress(total: Int64, ratios: (Double, Double, Double), largest: Int64? = nil) -> WheelNode {
        func level(_ title: LText, _ symbol: String, _ lvl: CompressLevel, _ r: Double) -> WheelNode {
            var n = leaf(title, symbol, .compress(lvl))
            let est = "≈ " + formatBytes(Int64(Double(total) * r))
            n.detail = LText(est)
            return n
        }
        return WheelNode(
            title: LText("压缩", "Compress"), symbol: "arrow.down.right.and.arrow.up.left",
            detail: LText(formatBytes(total)),
            children: [
                level(LText("轻度", "Light"), "gauge.with.dots.needle.33percent", .light, ratios.0),
                level(LText("中度", "Medium"), "gauge.with.dots.needle.50percent", .medium, ratios.1),
                level(LText("强力", "Strong"), "gauge.with.dots.needle.67percent", .strong, ratios.2),
            ] + (largest.map { [targetSizes(largest: $0)] } ?? []))
    }

    /// 压到指定大小：≤ 2 MB / 1 MB / 500 KB（只列比文件小的）+ 自定义
    private static func targetSizes(largest: Int64) -> WheelNode {
        let presets: [(String, Int64)] = [("2 MB", 2_000_000), ("1 MB", 1_000_000), ("500 KB", 500_000)]
        var kids = presets.filter { $0.1 < largest }.map { label, bytes in
            leaf(LText("≤ \(label)"), "scalemass", .compressTo(bytes))
        }
        kids.append(leaf(LText("自定义…", "Custom…"), "slider.horizontal.below.rectangle", .compressTo(nil)))
        var node = WheelNode(title: LText("指定大小", "Target Size"), symbol: "target", children: kids)
        node.detail = LText("每个文件", "Per file")
        return node
    }

    private static func mergeToPDF() -> WheelNode {
        leaf(LText("合并为 PDF", "Merge to PDF"), "square.stack.3d.up", .mergeToPDF)
    }

    private static func zip() -> WheelNode {
        leaf(LText("压缩为 ZIP", "Zip"), "doc.zipper", .zip)
    }

    private static func pdfEdit() -> WheelNode {
        WheelNode(
            title: LText("编辑", "Edit"), symbol: "slider.horizontal.3",
            children: [
                leaf(LText("拆分", "Split"), "scissors", .splitPDF),
                WheelNode(title: LText("旋转", "Rotate"), symbol: "rotate.right", children: [
                    leaf(LText("向右 90°", "Right 90°"), "rotate.right", .rotate(90)),
                    leaf(LText("向左 90°", "Left 90°"), "rotate.left", .rotate(-90)),
                    leaf("180°", "arrow.up.arrow.down", .rotate(180)),
                ]),
                leaf(LText("签名", "Sign"), "signature", .sign),
                leaf(LText("加水印", "Watermark"), "drop.halffull", .watermark),
                leaf(LText("涂黑", "Redact"), "eye.slash", .redact),
                leaf(LText("元数据", "Metadata"), "tag", .metadata),
            ])
    }

    private static func imageEdit() -> WheelNode {
        WheelNode(
            title: LText("编辑", "Edit"), symbol: "slider.horizontal.3",
            children: [
                leaf(LText("裁剪", "Crop"), "crop", .crop),
                leaf(LText("加背景", "Add BG"), "photo.on.rectangle", .addBackground),
                leaf(LText("改尺寸", "Resize"), "arrow.up.left.and.arrow.down.right", .resize),
                leaf(LText("抠图", "Cut Out"), "wand.and.stars", .cutout),
                leaf(LText("证件照", "ID Photo"), "person.crop.square", .idPhoto),
                leaf(LText("加水印", "Watermark"), "drop.halffull", .watermark),
                leaf(LText("元数据", "Metadata"), "tag", .metadata),
            ])
    }

    // MARK: - 工具

    private static func leaf(_ title: String, _ symbol: String, _ action: PeelAction) -> WheelNode {
        leaf(LText(title), symbol, action)
    }

    private static func leaf(_ title: LText, _ symbol: String, _ action: PeelAction) -> WheelNode {
        WheelNode(title: title, symbol: symbol, action: action)
    }

    static func totalSize(_ files: [URL]) -> Int64 {
        files.reduce(0) { sum, url in
            let size = Output.size(url)
            return sum + size
        }
    }

    static func formatBytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }
}
