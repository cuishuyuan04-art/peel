import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 压缩到指定大小：自动找到刚好不超过目标、画质尽量高的版本
enum TargetCompressor {
    struct Result {
        let file: URL       // 临时文件（可能换了扩展名，比如 PNG → JPG）
        let size: Int64
        let fits: Bool      // 是否达到了目标；达不到时 file 是能压到的最小版本
    }

    /// 尺寸缩放的档位：先原尺寸，不够再逐步缩小
    private static let scales: [Double] = [1.0, 0.85, 0.72, 0.6, 0.5, 0.42, 0.35, 0.28, 0.2]
    /// 画质低于这个就宁可缩小尺寸，换更清楚的画面
    private static let preferredMinQuality = 0.5

    static func compress(_ src: URL, target: Int64) throws -> Result {
        switch FileKind.of(src) {
        case .image: return try image(src, target: target)
        case .pdf: return try pdf(src, target: target)
        default: throw PeelError.notYet
        }
    }

    // MARK: - 图片

    private static func image(_ src: URL, target: Int64) throws -> Result {
        let ext = FileKind.normalizedExt(src)
        let full = try ImageEngine.load(src)
        let side = max(full.width, full.height)
        let dir = try Output.tempDir()
        let base = src.deletingPathExtension().lastPathComponent

        switch ext {
        case "jpg", "heic":
            return try lossy(src, side: side, type: ext == "jpg" ? .jpeg : .heic, target: target,
                             out: dir.appendingPathComponent(base).appendingPathExtension(src.pathExtension))
        case "webp":
            return try webp(src, side: side, target: target, out: dir.appendingPathComponent(base).appendingPathExtension("webp"))
        case "png", "tiff", "bmp":
            if ImageEngine.hasAlpha(full) {
                // 有透明部分：保持 PNG，减少颜色 + 缩小尺寸
                return try png(src, side: side, target: target, out: dir.appendingPathComponent(base).appendingPathExtension("png"))
            }
            // 没有透明部分：改存为 JPG，体积小很多
            return try lossy(src, side: side, type: .jpeg, target: target,
                             out: dir.appendingPathComponent(base).appendingPathExtension("jpg"))
        default:
            throw PeelError("暂不支持把 \(ext.uppercased()) 压到指定大小", "Can't target-compress \(ext.uppercased()) yet")
        }
    }

    /// JPEG / HEIC：每个尺寸档位里二分查找最高的画质
    private static func lossy(_ src: URL, side: Int, type: UTType, target: Int64, out: URL) throws -> Result {
        var fallback: Data?           // 达标但画质偏低的版本（尺寸最大的那个）
        var smallest: Data?
        for scale in scales {
            if Jobs.isCancelled { throw PeelError.cancelled }
            let img = try ImageEngine.load(src, maxPixel: Int(Double(side) * scale))
            let meta = ImageEngine.metadata(from: src, width: img.width, height: img.height)
            func encode(_ q: Double) -> Data? { encodeData(img, type: type, quality: q, meta: meta) }

            guard let low = encode(0.1) else { continue }
            if smallest == nil || low.count < smallest!.count { smallest = low }
            guard Int64(low.count) <= target else { continue }     // 这个尺寸画质最低也超了：缩小

            // 二分：找最高的、不超过目标的画质
            var lo = 0.1, hi = 0.95, best = low
            for _ in 0..<7 {
                let mid = (lo + hi) / 2
                if let d = encode(mid), Int64(d.count) <= target { best = d; lo = mid } else { hi = mid }
            }
            if lo >= preferredMinQuality {
                return try finish(best, out: out, fits: true)
            }
            if fallback == nil { fallback = best }
        }
        if let fallback { return try finish(fallback, out: out, fits: true) }
        guard let smallest else { throw PeelError("压缩失败", "Compression failed") }
        return try finish(smallest, out: out, fits: false)
    }

    private static func encodeData(_ img: CGImage, type: UTType, quality: Double, meta: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props = meta
        props[kCGImageDestinationLossyCompressionQuality] = quality
        let image = (type == .jpeg && ImageEngine.hasAlpha(img)) ? ImageEngine.flatten(img) : img
        CGImageDestinationAddImage(dst, image, props as CFDictionary)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }

    private static func finish(_ data: Data, out: URL, fits: Bool) throws -> Result {
        try data.write(to: out)
        return Result(file: out, size: Int64(data.count), fits: fits)
    }

    /// PNG（有透明）：pngquant 减少颜色，不够再缩小尺寸
    private static func png(_ src: URL, side: Int, target: Int64, out: URL) throws -> Result {
        var smallestSize = Int64.max
        let smallest = out.deletingLastPathComponent().appendingPathComponent("smallest.png")
        for scale in scales {
            if Jobs.isCancelled { throw PeelError.cancelled }
            let img = try ImageEngine.load(src, maxPixel: Int(Double(side) * scale))
            for quality in ["65-90", "40-70", "10-45"] {
                try? FileManager.default.removeItem(at: out)
                try ImageEngine.compressPNG(img, quality: quality, to: out)
                let size = Output.size(out)
                if size <= target { return Result(file: out, size: size, fits: true) }
                if size < smallestSize {
                    smallestSize = size
                    try? FileManager.default.removeItem(at: smallest)
                    try? FileManager.default.copyItem(at: out, to: smallest)
                }
            }
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: smallest, to: out)
        return Result(file: out, size: smallestSize, fits: false)
    }

    /// WebP：cwebp 的质量参数二分
    private static func webp(_ src: URL, side: Int, target: Int64, out: URL) throws -> Result {
        var smallestSize = Int64.max
        var smallestData: Data?
        for scale in scales {
            if Jobs.isCancelled { throw PeelError.cancelled }
            let img = try ImageEngine.load(src, maxPixel: Int(Double(side) * scale))
            func encode(_ q: Int) throws -> Data {
                try? FileManager.default.removeItem(at: out)
                try ImageEngine.encodeWebP(img, quality: q, lossless: false, to: out)
                return try Data(contentsOf: out)
            }
            let low = try encode(10)
            if Int64(low.count) < smallestSize { smallestSize = Int64(low.count); smallestData = low }
            guard Int64(low.count) <= target else { continue }
            var lo = 10, hi = 95, best = low
            while hi - lo > 4 {
                let mid = (lo + hi) / 2
                let d = try encode(mid)
                if Int64(d.count) <= target { best = d; lo = mid } else { hi = mid }
            }
            return try finish(best, out: out, fits: true)
        }
        guard let smallestData else { throw PeelError("压缩失败", "Compression failed") }
        return try finish(smallestData, out: out, fits: false)
    }

    // MARK: - PDF

    /// 从清晰到模糊依次尝试（图片分辨率逐步降低），第一个不超过目标的就用
    private static func pdf(_ src: URL, target: Int64) throws -> Result {
        guard let gs = Tool.ghostscript.path else { throw PeelError("缺少 Ghostscript", "Ghostscript missing") }
        _ = try PDFEngine.open(src)
        let dir = try Output.tempDir()
        let out = dir.appendingPathComponent(src.lastPathComponent)
        var smallest: (URL, Int64)?
        for (i, dpi) in [300, 200, 150, 120, 100, 85, 72, 60, 50, 40].enumerated() {
            if Jobs.isCancelled { throw PeelError.cancelled }
            let attempt = dir.appendingPathComponent("try-\(i).pdf")
            let preset = dpi >= 300 ? "/printer" : dpi >= 150 ? "/ebook" : "/screen"
            do {
                try Shell.run(gs, ["-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5", "-dPDFSETTINGS=\(preset)",
                                   "-dNOPAUSE", "-dQUIET", "-dBATCH", "-dDetectDuplicateImages=true",
                                   "-dDownsampleColorImages=true", "-dDownsampleGrayImages=true",
                                   "-dColorImageResolution=\(dpi)", "-dGrayImageResolution=\(dpi)",
                                   "-dMonoImageResolution=\(max(dpi * 2, 150))",
                                   "-sOutputFile=\(attempt.path)", src.path])
            } catch let e as PeelError {
                throw e
            } catch {
                continue
            }
            let size = Output.size(attempt)
            if size > 0, size <= target {
                try FileManager.default.moveItem(at: attempt, to: out)
                return Result(file: out, size: size, fits: true)
            }
            if size > 0, smallest == nil || size < smallest!.1 { smallest = (attempt, size) }
        }
        guard let smallest else { throw PeelError("PDF 压缩失败", "PDF compression failed") }
        try FileManager.default.moveItem(at: smallest.0, to: out)
        return Result(file: out, size: smallest.1, fits: false)
    }
}
