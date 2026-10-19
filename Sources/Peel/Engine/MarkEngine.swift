import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers

/// 水印参数
struct WatermarkStyle {
    var text = t("仅供申请使用", "For application use only")
    var color: NSColor = .gray
    var opacity: CGFloat = 0.22
    /// 字号：页面短边的比例
    var size: CGFloat = 0.045
    var angle: CGFloat = -30          // 度
    /// 行列间距：字号的倍数
    var spacing: CGFloat = 3.2
    /// PDF：把加了水印的页面转成图片，水印无法被删除（文字不能再复制）
    var bake = true
}

/// 签名放在页面上的内容（位置都是比例坐标：相对于页面显示区域，原点左上）
struct SignaturePlacement {
    var page: Int
    var image: CGImage
    var rect: CGRect
    var date: (text: String, rect: CGRect)?
}

/// 水印、签名
enum MarkEngine {

    // MARK: - 水印绘制

    /// 在一块区域上斜向平铺水印文字（CG 坐标，原点左下）
    static func drawWatermark(_ s: WatermarkStyle, in ctx: CGContext, size: CGSize) {
        let text = s.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let fontSize = max(8, min(size.width, size.height) * s.size)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        // 文字外加一圈浅色描边：浅色背景（扫描件）和深浅不一的照片上都看得清
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: (s.color.usingColorSpace(.sRGB) ?? s.color).withAlphaComponent(s.opacity),
            .strokeColor: NSColor.white.withAlphaComponent(min(1, s.opacity * 1.6)),
            .strokeWidth: -2.5,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let stepX = bounds.width + fontSize * s.spacing
        let stepY = fontSize * s.spacing

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: s.angle * .pi / 180)
        // 旋转后要铺满整块区域：按对角线长度铺
        let diag = hypot(size.width, size.height)
        var row = 0
        var y = -diag / 2
        while y < diag / 2 {
            // 隔行错开半格，看起来更均匀
            var x = -diag / 2 + (row % 2 == 0 ? 0 : stepX / 2)
            while x < diag / 2 {
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
                x += stepX
            }
            y += stepY
            row += 1
        }
        ctx.restoreGState()
    }

    // MARK: - 图片加水印

    static func watermarkImage(_ src: URL, style: WatermarkStyle) throws -> URL {
        let img = try ImageEngine.load(src)
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: img.colorSpace?.model == .rgb ? img.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PeelError("图片太大，无法处理", "Image too large")
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        drawWatermark(style, in: ctx, size: CGSize(width: w, height: h))
        guard let out = ctx.makeImage() else { throw PeelError("加水印失败", "Watermark failed") }
        let ext = FileKind.normalizedExt(src)
        let (type, outExt): (UTType, String) = ext == "png" ? (.png, "png") : ext == "heic" ? (.heic, "heic") : (.jpeg, "jpg")
        let dst = Output.sibling(of: src, ext: outExt, suffix: t("_水印", "_watermarked"))
        try ImageEngine.write(out, type: type, quality: type == .png ? nil : 0.92, to: dst, metadataFrom: src)
        return dst
    }

    /// 预览用：图片缩小后加水印
    static func previewImage(_ img: CGImage, style: WatermarkStyle) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        drawWatermark(style, in: ctx, size: CGSize(width: img.width, height: img.height))
        return ctx.makeImage()
    }

    // MARK: - PDF 加水印 / 签名（逐页重新绘制）

    static func watermarkPDF(_ src: URL, style: WatermarkStyle) throws -> URL {
        let dst = Output.sibling(of: src, ext: "pdf", suffix: t("_水印", "_watermarked"))
        try redraw(src, to: dst) { index, ctx, size in
            drawWatermark(style, in: ctx, size: size)
        } bake: { _ in style.bake }
        return dst
    }

    static func sign(_ src: URL, placements: [SignaturePlacement]) throws -> URL {
        let dst = Output.sibling(of: src, ext: "pdf", suffix: t("_已签名", "_signed"))
        try redraw(src, to: dst) { index, ctx, size in
            for p in placements where p.page == index {
                ctx.interpolationQuality = .high
                ctx.draw(p.image, in: cgRect(p.rect, in: size))
                if let date = p.date { drawText(date.text, in: cgRect(date.rect, in: size), ctx: ctx) }
            }
        } bake: { _ in false }
        return dst
    }

    /// 比例坐标（原点左上）→ CG 坐标（原点左下）
    static func cgRect(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    /// 日期等文字：按框的高度定字号，左对齐，深色
    static func drawText(_ text: String, in rect: CGRect, ctx: CGContext) {
        let font = NSFont.systemFont(ofSize: rect.height * 0.78)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.08, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 按页面显示方向（考虑旋转）逐页重画到新 PDF：原页面保持矢量（文字可复制），再叠加内容。
    /// bake 返回 true 的页面会先渲染成图片再叠加（叠加内容无法被删除）
    private static func redraw(_ src: URL, to dst: URL,
                               overlay: (Int, CGContext, CGSize) -> Void,
                               bake: (Int) -> Bool) throws {
        let doc = try PDFEngine.open(src)
        guard let ctx = CGContext(dst as CFURL, mediaBox: nil, nil) else {
            throw PeelError("无法生成 PDF", "Can't create PDF")
        }
        for i in 0..<doc.pageCount {
            if Jobs.isCancelled { ctx.closePDF(); throw PeelError.cancelled }
            guard let page = doc.page(at: i) else { continue }
            let b = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let size = CGSize(width: rotated ? b.height : b.width, height: rotated ? b.width : b.height)
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            if bake(i) {
                // 页面渲染成图片（200 dpi），叠加内容一起画进去
                let scale: CGFloat = 200 / 72
                let w = Int(size.width * scale), h = Int(size.height * scale)
                if let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                    bmp.setFillColor(.white)
                    bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    bmp.saveGState()
                    bmp.scaleBy(x: scale, y: scale)
                    bmp.concatenate(page.transform(for: .mediaBox))
                    page.draw(with: .mediaBox, to: bmp)
                    bmp.restoreGState()
                    bmp.scaleBy(x: scale, y: scale)
                    overlay(i, bmp, size)
                    if let img = bmp.makeImage() { ctx.draw(img, in: box) }
                }
            } else {
                ctx.saveGState()
                ctx.concatenate(page.transform(for: .mediaBox))
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
                overlay(i, ctx, size)
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// 预览：渲染某一页（显示方向）并叠加内容
    static func previewPage(_ page: PDFPage, dpi: CGFloat, overlay: ((CGContext, CGSize) -> Void)? = nil) -> CGImage? {
        let scale = dpi / 72
        let b = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = CGSize(width: rotated ? b.height : b.width, height: rotated ? b.width : b.height)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.saveGState()
        ctx.concatenate(page.transform(for: .mediaBox))
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        overlay?(ctx, size)
        return ctx.makeImage()
    }
}

/// 保存的签名（透明 PNG，放在 ~/Library/Application Support/Peel/signatures）
enum SignatureStore {
    static var folder: URL {
        let d = Output.appSupport.appendingPathComponent("signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func all() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    @discardableResult
    static func save(_ img: CGImage) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appendingPathComponent("signature-\(f.string(from: Date())).png")
        return (try? ImageEngine.write(img, type: .png, to: url)) != nil ? url : nil
    }

    static func delete(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func load(_ url: URL) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }

    /// 打字生成签名：用手写风格字体渲染成透明图
    static func typed(_ name: String, font: String) -> CGImage? {
        let text = name.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let nsFont = NSFont(name: font, size: 120) ?? NSFont.systemFont(ofSize: 120)
        let attrs: [NSAttributedString.Key: Any] = [.font: nsFont, .foregroundColor: NSColor(red: 0.05, green: 0.1, blue: 0.3, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let b = CTLineGetImageBounds(line, nil)
        let pad: CGFloat = 20
        let w = Int(b.width + pad * 2), h = Int(b.height + pad * 2)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: pad - b.minX, y: pad - b.minY)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    /// 本机装了的手写风格字体（中文 / 英文）
    static var handwritingFonts: [(name: String, label: String)] {
        let candidates: [(String, String)] = [
            ("HanziPenSC-W3", "翩翩体"), ("STXingkai", "行楷"), ("STKaiti", "楷体"),
            ("SnellRoundhand", "Snell Roundhand"), ("BradleyHandITCTT-Bold", "Bradley Hand"),
            ("Zapfino", "Zapfino"), ("Noteworthy-Light", "Noteworthy"),
        ]
        return candidates.filter { NSFont(name: $0.0, size: 12) != nil }
    }
}
