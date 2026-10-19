import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// 编辑类操作（裁剪、改尺寸、加背景、元数据、PDF 拆分 / 旋转 / 涂黑 / 元数据）
enum EditEngine {

    // MARK: - 图片

    /// 输出格式：与原图相同；BMP/GIF/WebP 等不便写回的用 PNG（有透明）或 JPG
    private static func outputType(for src: URL, image: CGImage) -> (UTType, String, Double?) {
        switch FileKind.normalizedExt(src) {
        case "jpg": return (.jpeg, src.pathExtension, 0.92)
        case "heic": return (.heic, src.pathExtension, 0.9)
        case "png": return (.png, src.pathExtension, nil)
        case "tiff": return (.tiff, src.pathExtension, nil)
        default:
            return ImageEngine.hasAlpha(image) ? (.png, "png", nil) : (.jpeg, "jpg", 0.92)
        }
    }

    private static func save(_ img: CGImage, like src: URL, suffix: String, keepMetadata: Bool = true) throws -> URL {
        let (type, ext, q) = outputType(for: src, image: img)
        let dst = Output.sibling(of: src, ext: ext, suffix: suffix)
        try ImageEngine.write(img, type: type, quality: q, to: dst, metadataFrom: keepMetadata ? src : nil)
        return dst
    }

    /// rect：在转正后的原图像素坐标里（原点左上）
    static func crop(_ src: URL, rect: CGRect) throws -> URL {
        let img = try ImageEngine.load(src)
        // CGImage.cropping 的原点也在左上
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard r.width >= 1, r.height >= 1, let out = img.cropping(to: r) else {
            throw PeelError("裁剪区域无效", "Invalid crop area")
        }
        return try save(out, like: src, suffix: t("_裁剪", "_cropped"))
    }

    static func resize(_ src: URL, width: Int, height: Int) throws -> URL {
        let img = try ImageEngine.load(src)
        guard width > 0, height > 0, width <= 30000, height <= 30000 else {
            throw PeelError("尺寸无效", "Invalid size")
        }
        let out = try draw(width: width, height: height, alpha: ImageEngine.hasAlpha(img), space: img.colorSpace) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try save(out, like: src, suffix: "_\(width)x\(height)")
    }

    /// 加背景：铺底色、加留白边距，并按画布比例扩展画布（图片居中）
    /// padding：边距占较长边的比例；ratio：画布宽/高，nil 为原比例
    static func addBackground(_ src: URL, color: NSColor, padding: Double, ratio: Double?) throws -> URL {
        let img = try ImageEngine.load(src)
        let (w, h) = canvasSize(imageWidth: img.width, imageHeight: img.height, padding: padding, ratio: ratio)
        let out = try draw(width: w, height: h, alpha: color.alphaComponent < 1, space: img.colorSpace) { ctx in
            ctx.setFillColor(color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: (w - img.width) / 2, y: (h - img.height) / 2, width: img.width, height: img.height))
        }
        // 原图有透明、底色不透明时，结果不再需要透明：JPG 源仍输出 JPG
        return try save(out, like: src, suffix: t("_加背景", "_background"))
    }

    static func canvasSize(imageWidth w: Int, imageHeight h: Int, padding: Double, ratio: Double?) -> (Int, Int) {
        let pad = Double(max(w, h)) * padding
        var cw = Double(w) + pad * 2, ch = Double(h) + pad * 2
        if let ratio {
            if cw / ch < ratio { cw = ch * ratio } else { ch = cw / ratio }
        }
        return (Int(cw.rounded()), Int(ch.rounded()))
    }

    private static func draw(width: Int, height: Int, alpha: Bool, space: CGColorSpace?,
                             _ body: (CGContext) -> Void) throws -> CGImage {
        let cs = (space?.model == .rgb ? space : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: info) else {
            throw PeelError("图片太大，无法处理", "Image too large")
        }
        body(ctx)
        guard let out = ctx.makeImage() else { throw PeelError("图片处理失败", "Image processing failed") }
        return out
    }

    // MARK: - 图片元数据

    struct PhotoInfo {
        var date: String?
        var camera: String?
        var lens: String?
        var exposure: String?
        var location: (lat: Double, lon: Double)?
        var size: String = ""
    }

    static func photoInfo(_ src: URL) -> PhotoInfo {
        var info = PhotoInfo()
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return info }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            info.size = "\(w) × \(h)"
        }
        info.date = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String
        let make = (tiff[kCGImagePropertyTIFFMake] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let camera = model.hasPrefix(make) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        info.camera = camera.isEmpty ? nil : camera
        info.lens = exif[kCGImagePropertyExifLensModel] as? String
        var parts: [String] = []
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { parts.append(String(format: "f/%.1f", f)) }
        if let e = exif[kCGImagePropertyExifExposureTime] as? Double {
            parts.append(e < 1 ? "1/\(Int((1 / e).rounded()))s" : String(format: "%.1fs", e))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { parts.append(String(format: "%.0fmm", fl)) }
        info.exposure = parts.isEmpty ? nil : parts.joined(separator: "  ")
        if var lat = gps[kCGImagePropertyGPSLatitude] as? Double, var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            info.location = (lat, lon)
        }
        return info
    }

    /// 去掉位置（onlyLocation）或全部元数据。能无损复制的格式直接复制图像数据，不重新压缩
    static func stripMetadata(_ src: URL, onlyLocation: Bool) throws -> URL {
        let suffix = onlyLocation ? t("_无位置", "_no-location") : t("_无元数据", "_no-metadata")
        let dst = Output.sibling(of: src, ext: src.pathExtension, suffix: suffix)
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), let type = CGImageSourceGetType(source),
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, type, 1, nil) else {
            throw PeelError("无法读取「\(src.lastPathComponent)」", "Can't read “\(src.lastPathComponent)”")
        }
        // 必须显式传入要保留的元数据，否则会被全部丢掉
        var opts: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true, kCGImageDestinationMergeMetadata: false]
        if onlyLocation, let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            opts[kCGImageDestinationMetadata] = meta
        } else {
            opts[kCGImageDestinationMetadata] = CGImageMetadataCreateMutable()
            opts[kCGImageMetadataShouldExcludeXMP] = true
        }
        var err: Unmanaged<CFError>?
        // 有些格式（如 HEIC）复制成功但元数据没去掉：写完检查一遍，不干净就改用重新编码
        if CGImageDestinationCopyImageSource(dest, source, opts as CFDictionary, &err),
           isClean(dst, onlyLocation: onlyLocation) {
            return dst
        }

        // 不支持无损复制的格式：重新编码（高质量），只带上保留的那部分元数据
        try? FileManager.default.removeItem(at: dst)
        let img = try ImageEngine.load(src)
        if onlyLocation {
            let out = try save(img, like: src, suffix: suffix)
            try removeGPS(out)
            return out
        }
        return try save(img, like: src, suffix: suffix, keepMetadata: false)
    }

    private static func isClean(_ url: URL, onlyLocation: Bool) -> Bool {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return false }
        if p[kCGImagePropertyGPSDictionary] != nil { return false }
        if onlyLocation { return true }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        return exif[kCGImagePropertyExifDateTimeOriginal] == nil && tiff[kCGImagePropertyTIFFModel] == nil
    }

    private static func removeGPS(_ url: URL) throws {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(s),
              let img = CGImageSourceCreateImageAtIndex(s, 0, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return }
        props.removeValue(forKey: kCGImagePropertyGPSDictionary)
        let tmp = try Output.tempDir().appendingPathComponent(url.lastPathComponent)
        guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return }
        props[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(d, img, props as CFDictionary)
        guard CGImageDestinationFinalize(d) else { return }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - PDF

    static func rotate(_ src: URL, degrees: Int) throws -> URL {
        let doc = try PDFEngine.open(src)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        let dst = Output.sibling(of: src, ext: "pdf", suffix: t("_旋转", "_rotated"))
        guard doc.write(to: dst) else { throw PeelError("无法生成 PDF", "Can't create PDF") }
        return dst
    }

    enum SplitMode {
        case everyPage
        case chunks(Int)
        case ranges([ClosedRange<Int>])   // 页码从 1 开始
    }

    /// 解析“1-3, 5, 8-10”；超出页数或格式不对返回 nil
    static func parseRanges(_ text: String, pageCount: Int) -> [ClosedRange<Int>]? {
        let parts = text.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "～", with: "-")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var ranges: [ClosedRange<Int>] = []
        for p in parts {
            let ends = p.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let a = ends.first ?? nil else { return nil }
            let b = ends.count == 2 ? (ends[1] ?? -1) : a
            guard ends.count <= 2, a >= 1, b >= a, b <= pageCount else { return nil }
            ranges.append(a...b)
        }
        return ranges
    }

    static func split(_ src: URL, mode: SplitMode) throws -> [URL] {
        let doc = try PDFEngine.open(src)
        let n = doc.pageCount
        let base = src.deletingPathExtension().lastPathComponent
        let dir = src.deletingLastPathComponent()

        func extract(_ range: ClosedRange<Int>, to url: URL) throws {
            let out = PDFDocument()
            for i in range {
                if let page = doc.page(at: i - 1)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
            }
            guard out.write(to: url) else { throw PeelError("无法生成 PDF", "Can't create PDF") }
        }

        switch mode {
        case .ranges(let ranges):
            guard !ranges.isEmpty, ranges.allSatisfy({ $0.lowerBound >= 1 && $0.upperBound <= n }) else {
                throw PeelError("页码无效（共 \(n) 页）", "Invalid pages (\(n) total)")
            }
            // 所有范围合成一个 PDF
            let label = ranges.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
                .joined(separator: ",")
            let dst = Output.unique(dir.appendingPathComponent("\(base)_\(t("第", "p"))\(label)\(t("页", ""))")
                .appendingPathExtension("pdf"))
            let out = PDFDocument()
            for r in ranges {
                for i in r {
                    if let page = doc.page(at: i - 1)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
                }
            }
            guard out.write(to: dst) else { throw PeelError("无法生成 PDF", "Can't create PDF") }
            return [dst]
        case .everyPage, .chunks:
            let size: Int
            if case .chunks(let k) = mode { size = max(1, k) } else { size = 1 }
            let folder = Output.unique(dir.appendingPathComponent("\(base) (\(t("拆分", "split")))"))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let digits = String(n).count
            var start = 1
            while start <= n {
                if Jobs.isCancelled { throw PeelError.cancelled }
                let end = min(n, start + size - 1)
                let a = String(format: "%0\(digits)d", start), b = String(format: "%0\(digits)d", end)
                let name = start == end ? "\(base)-\(a)" : "\(base)-\(a)-\(b)"
                try extract(start...end, to: folder.appendingPathComponent(name).appendingPathExtension("pdf"))
                start = end + 1
            }
            return [folder]
        }
    }

    /// 涂黑：有涂黑框的页面渲染成图片再画黑框，原页面的文字和图形被彻底移除；其他页面保持原样。
    /// rects：页码（从 0 开始）→ 页面坐标里的矩形
    static func redact(_ src: URL, rects: [Int: [CGRect]], dpi: CGFloat = 200) throws -> URL {
        let doc = try PDFEngine.open(src)
        for (index, boxes) in rects.sorted(by: { $0.key < $1.key }) where !boxes.isEmpty {
            if Jobs.isCancelled { throw PeelError.cancelled }
            guard let page = doc.page(at: index) else { continue }
            let replacement = try rasterized(page, boxes: boxes, dpi: dpi)
            doc.removePage(at: index)
            doc.insert(replacement, at: index)
        }
        let dst = Output.sibling(of: src, ext: "pdf", suffix: t("_涂黑", "_redacted"))
        guard doc.write(to: dst) else { throw PeelError("无法生成 PDF", "Can't create PDF") }
        return dst
    }

    private static func rasterized(_ page: PDFPage, boxes: [CGRect], dpi: CGFloat) throws -> PDFPage {
        let scale = dpi / 72
        let transform = page.transform(for: .mediaBox)
        let image = try PDFEngine.render(page, dpi: dpi)
        let w = CGFloat(image.width), h = CGFloat(image.height)

        // 在渲染图上画黑框（页面坐标 → 图片坐标）
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PeelError("页面渲染失败", "Failed to render page")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(.black)
        for box in boxes {
            let r = box.applying(transform).applying(CGAffineTransform(scaleX: scale, y: scale))
            ctx.fill(r.insetBy(dx: -1, dy: -1))
        }
        guard let redacted = ctx.makeImage() else { throw PeelError("页面渲染失败", "Failed to render page") }

        // 写成单页 PDF（页面大小不变），再取出这一页
        let data = NSMutableData()
        // 页面大小用原页面的精确尺寸（考虑旋转），不用取整后的像素换算
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        var box = CGRect(x: 0, y: 0, width: rotated ? bounds.height : bounds.width,
                         height: rotated ? bounds.width : bounds.height)
        guard let consumer = CGDataConsumer(data: data),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PeelError("无法生成 PDF", "Can't create PDF")
        }
        pdf.beginPage(mediaBox: &box)
        pdf.draw(redacted, in: box)
        pdf.endPage()
        pdf.closePDF()
        guard let one = PDFDocument(data: data as Data), let newPage = one.page(at: 0) else {
            throw PeelError("无法生成 PDF", "Can't create PDF")
        }
        return newPage
    }

    struct PDFMeta {
        var title = "", author = "", subject = "", keywords = ""
        var creator = "", producer = "", created = "", modified = ""
    }

    static func pdfMeta(_ src: URL) -> PDFMeta {
        var m = PDFMeta()
        guard let a = PDFDocument(url: src)?.documentAttributes else { return m }
        func s(_ k: PDFDocumentAttribute) -> String {
            if let v = a[k] as? String { return v }
            if let arr = a[k] as? [String] { return arr.joined(separator: ", ") }
            if let d = a[k] as? Date {
                let f = DateFormatter()
                f.dateStyle = .medium
                f.timeStyle = .short
                return f.string(from: d)
            }
            return ""
        }
        m.title = s(.titleAttribute); m.author = s(.authorAttribute)
        m.subject = s(.subjectAttribute); m.keywords = s(.keywordsAttribute)
        m.creator = s(.creatorAttribute); m.producer = s(.producerAttribute)
        m.created = s(.creationDateAttribute); m.modified = s(.modificationDateAttribute)
        return m
    }

    /// clearAll 时清空所有信息（包括创建工具和日期）
    static func setPDFMeta(_ src: URL, meta: PDFMeta, clearAll: Bool) throws -> URL {
        let doc = try PDFEngine.open(src)
        // 键要用字符串（PDFDocumentAttribute.rawValue），否则写出时被忽略
        var attrs: [AnyHashable: Any] = [:]
        if !clearAll {
            // 只保留标准字段：非标准字段（如 WPS 的 SourceModified）会被 PDFKit 写坏，整个信息区都读不出来
            let standard: [PDFDocumentAttribute] = [.creatorAttribute, .producerAttribute,
                                                    .creationDateAttribute, .modificationDateAttribute]
            for key in standard {
                if let v = doc.documentAttributes?[key] ?? doc.documentAttributes?[key.rawValue] {
                    attrs[key.rawValue] = v
                }
            }
            attrs[PDFDocumentAttribute.titleAttribute.rawValue] = meta.title
            attrs[PDFDocumentAttribute.authorAttribute.rawValue] = meta.author
            attrs[PDFDocumentAttribute.subjectAttribute.rawValue] = meta.subject
            attrs[PDFDocumentAttribute.keywordsAttribute.rawValue] = meta.keywords
                .split(whereSeparator: { $0 == "," || $0 == "，" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute,
                        .creatorAttribute, .producerAttribute] {
                attrs[key.rawValue] = ""
            }
            attrs[PDFDocumentAttribute.keywordsAttribute.rawValue] = [String]()
        }
        doc.documentAttributes = attrs
        let suffix = clearAll ? t("_无元数据", "_no-metadata") : t("_已编辑", "_edited")
        let dst = Output.sibling(of: src, ext: "pdf", suffix: suffix)
        guard doc.write(to: dst) else { throw PeelError("无法生成 PDF", "Can't create PDF") }
        return dst
    }
}
