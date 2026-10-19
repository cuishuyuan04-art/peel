import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageEngine {

    // MARK: - 读写

    /// 读入图片（已按 EXIF 方向转正），可限制最长边
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw unreadable(url) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let full = max(w, h, 1)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? full, full),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw unreadable(url) }
        return img
    }

    /// metadataFrom：从原图复制拍摄信息（EXIF / TIFF / GPS / IPTC）
    static func write(_ img: CGImage, type: UTType, quality: Double? = nil, to url: URL,
                      metadataFrom src: URL? = nil) throws {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw PeelError("无法生成 \(url.pathExtension.uppercased())", "Can't create \(url.pathExtension.uppercased())")
        }
        let image = (type == .jpeg && hasAlpha(img)) ? flatten(img) : img
        var props = src.map { metadata(from: $0, width: image.width, height: image.height) } ?? [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else {
            throw PeelError("无法生成 \(url.pathExtension.uppercased())", "Can't create \(url.pathExtension.uppercased())")
        }
    }

    /// 原图的拍摄信息。像素已经按方向转正，所以方向一律写 1，并更新尺寸
    static func metadata(from url: URL, width: Int, height: Int) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let all = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let dict = all[key] { out[key] = dict }
        }
        out[kCGImagePropertyOrientation] = 1
        if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            out[kCGImagePropertyExifDictionary] = exif
        }
        return out
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// 透明部分铺白底（JPEG 不支持透明）
    static func flatten(_ img: CGImage) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        return ctx.makeImage() ?? img
    }

    private static func unreadable(_ url: URL) -> PeelError {
        PeelError("无法读取「\(url.lastPathComponent)」", "Can't read “\(url.lastPathComponent)”")
    }

    private static func utType(_ ext: String) -> UTType {
        switch ext {
        case "jpg": return .jpeg
        case "png": return .png
        case "heic": return .heic
        case "tiff": return .tiff
        case "bmp": return .bmp
        default: return .png
        }
    }

    // MARK: - 转换

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let dst = Output.sibling(of: src, ext: ext)
        switch ext {
        case "pdf":
            try makePDF([src], to: dst)
        case "webp":
            let img = try load(src)
            try encodeWebP(img, quality: 90, lossless: FileKind.normalizedExt(src) == "png", to: dst)
        default:
            let img = try load(src)
            let q: Double? = (ext == "jpg" || ext == "heic") ? 0.9 : nil
            try write(img, type: utType(ext), quality: q, to: dst, metadataFrom: src)
        }
        return dst
    }

    static func encodeWebP(_ img: CGImage, quality: Int, lossless: Bool, to dst: URL) throws {
        guard let cwebp = Tool.cwebp.path else { throw PeelError("缺少 cwebp", "cwebp missing") }
        let tmp = try Output.tempDir().appendingPathComponent("in.png")
        try write(img, type: .png, to: tmp)
        var args = ["-quiet", "-metadata", "none"]
        args += lossless ? ["-lossless", "-z", "6"] : ["-q", String(quality)]
        args += [tmp.path, "-o", dst.path]
        try Shell.run(cwebp, args)
    }

    // MARK: - 压缩

    /// 各档位的参数：JPEG/HEIC/WebP 质量、PNG 量化质量区间、最长边限制
    private static func params(_ level: CompressLevel) -> (quality: Double, pngQuality: String, maxPixel: Int?) {
        switch level {
        case .light: return (0.65, "70-90", nil)
        case .medium: return (0.55, "55-75", 3000)
        case .strong: return (0.4, "35-60", 2000)
        }
    }

    /// 压缩一张图片写到 dst（dst 由调用方决定，便于预估时写临时文件）。
    /// 返回实际写出的文件（BMP/TIFF 会换成 JPEG/PNG）
    @discardableResult
    static func compress(_ src: URL, level: CompressLevel, to dst: URL) throws -> URL {
        let ext = FileKind.normalizedExt(src)
        let p = params(level)
        switch ext {
        case "jpg", "heic":
            let img = try load(src, maxPixel: p.maxPixel)
            try write(img, type: utType(ext), quality: p.quality, to: dst, metadataFrom: src)
            // 原图本身压得很狠时，只降质量省不了多少：再把尺寸缩到 70%
            if level == .light, Output.size(dst) > Output.size(src) * 9 / 10 {
                let smaller = try load(src, maxPixel: Int(Double(max(img.width, img.height)) * 0.7))
                try write(smaller, type: utType(ext), quality: p.quality, to: dst, metadataFrom: src)
            }
            return dst
        case "png":
            let img = try load(src, maxPixel: p.maxPixel)
            try compressPNG(img, quality: p.pngQuality, to: dst)
            return dst
        case "webp":
            let img = try load(src, maxPixel: p.maxPixel)
            try encodeWebP(img, quality: Int(p.quality * 100), lossless: false, to: dst)
            return dst
        case "tiff", "bmp":
            let img = try load(src, maxPixel: p.maxPixel)
            if hasAlpha(img) {
                let out = dst.deletingPathExtension().appendingPathExtension("png")
                try compressPNG(img, quality: p.pngQuality, to: out)
                return out
            }
            let out = dst.deletingPathExtension().appendingPathExtension("jpg")
            try write(img, type: .jpeg, quality: p.quality, to: out, metadataFrom: src)
            return out
        default:
            throw PeelError("暂不支持压缩 \(ext.uppercased()) 图片", "Can't compress \(ext.uppercased()) images yet")
        }
    }

    static func compressPNG(_ img: CGImage, quality: String, to dst: URL) throws {
        let tmp = try Output.tempDir().appendingPathComponent("in.png")
        try write(img, type: .png, to: tmp)
        guard let pngquant = Tool.pngquant.path else {
            try FileManager.default.moveItem(at: tmp, to: dst)
            return
        }
        do {
            try Shell.run(pngquant, ["--quality=\(quality)", "--speed", "3", "--skip-if-larger",
                                     "--strip", "--force", "--output", dst.path, tmp.path])
        } catch let e as ToolFailure where e.status == 98 || e.status == 99 {
            // 98 = 压完反而更大，99 = 达不到质量要求：退回无损 PNG
            try FileManager.default.moveItem(at: tmp, to: dst)
        }
    }

    // MARK: - 图片合成 PDF

    /// 每张图片一页；页面最长边适配 A4，图片保留原始像素
    static func makePDF(_ images: [URL], to dst: URL) throws {
        var mediaBox = CGRect.zero
        guard let ctx = CGContext(dst as CFURL, mediaBox: &mediaBox, nil) else {
            throw PeelError("无法生成 PDF", "Can't create PDF")
        }
        for url in images {
            var img: CGImage
            if let original = jpegPassthrough(url) {
                // 方向正常的 JPEG：原始数据直接放进 PDF，不重新编码
                img = original
            } else {
                img = try load(url)
                // 其他不透明图片转成 JPEG 数据再放进 PDF，体积小很多
                if !hasAlpha(img), let jpeg = jpegImage(img) { img = jpeg }
            }
            let w = CGFloat(img.width), h = CGFloat(img.height)
            let scale = min(1, 842 / max(w, h))
            var box = CGRect(x: 0, y: 0, width: w * scale, height: h * scale)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(img, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    private static func jpegPassthrough(_ url: URL) -> CGImage? {
        guard FileKind.normalizedExt(url) == "jpg",
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        guard orientation == 1, let provider = CGDataProvider(url: url as CFURL) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func jpegImage(_ img: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dst), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
