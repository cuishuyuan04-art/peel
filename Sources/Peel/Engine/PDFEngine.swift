import AppKit
import PDFKit
import UniformTypeIdentifiers

enum PDFEngine {

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw PeelError("无法打开「\(url.lastPathComponent)」", "Can't open “\(url.lastPathComponent)”")
        }
        if doc.isLocked {
            throw PeelError("「\(url.lastPathComponent)」有密码保护", "“\(url.lastPathComponent)” is password-protected")
        }
        return doc
    }

    // MARK: - 转图片

    /// 单页 PDF → 一张图片；多页 → 放进一个文件夹，每页一张
    static func toImages(_ src: URL, ext: String, baseName: String? = nil, dpi: CGFloat = 150) throws -> [URL] {
        let doc = try open(src)
        let base = baseName ?? src.deletingPathExtension().lastPathComponent
        let dir = src.deletingLastPathComponent()
        let type: UTType = ext == "png" ? .png : .jpeg
        let q: Double? = ext == "png" ? nil : 0.9

        if doc.pageCount == 1, let page = doc.page(at: 0) {
            let dst = Output.unique(dir.appendingPathComponent(base).appendingPathExtension(ext))
            try ImageEngine.write(render(page, dpi: dpi), type: type, quality: q, to: dst)
            return [dst]
        }

        let folder = Output.unique(dir.appendingPathComponent("\(base) (\(ext.uppercased()))"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let num = String(format: "%0\(digits)d", i + 1)
            let dst = folder.appendingPathComponent("\(base)-\(num)").appendingPathExtension(ext)
            try ImageEngine.write(render(page, dpi: dpi), type: type, quality: q, to: dst)
        }
        return [folder]
    }

    /// 白底渲染一页（考虑页面旋转）
    static func render(_ page: PDFPage, dpi: CGFloat) throws -> CGImage {
        let scale = dpi / 72
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PeelError("页面渲染失败", "Failed to render page")
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.transform(for: .mediaBox))
        page.draw(with: .mediaBox, to: ctx)
        guard let img = ctx.makeImage() else { throw PeelError("页面渲染失败", "Failed to render page") }
        return img
    }

    // MARK: - 转文字 / Word

    static func toText(_ src: URL) throws -> URL {
        let text = try open(src).string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw PeelError("这个 PDF 里没有可提取的文字（可能是扫描件）",
                            "No extractable text in this PDF (it may be a scan)")
        }
        let dst = Output.sibling(of: src, ext: "txt")
        try text.write(to: dst, atomically: true, encoding: .utf8)
        return dst
    }

    static func toDocx(_ src: URL) throws -> URL {
        _ = try open(src)
        guard let python = Tool.pdf2docx.path else { throw PeelError("缺少 pdf2docx", "pdf2docx missing") }
        let tmp = try Output.tempDir().appendingPathComponent("out.docx")
        let script = """
        import sys
        from pdf2docx import Converter
        c = Converter(sys.argv[1])
        c.convert(sys.argv[2])
        c.close()
        """
        do {
            try Shell.run(python, ["-c", script, src.path, tmp.path])
        } catch {
            throw PeelError("PDF 转 Word 失败", "PDF to Word failed")
        }
        return try Output.place(tmp, at: Output.sibling(of: src, ext: "docx"))
    }

    // MARK: - 压缩

    /// 用 Ghostscript 重写 PDF：轻度 300dpi、中度 150dpi、强力 72dpi 图片
    static func compress(_ src: URL, level: CompressLevel, to dst: URL) throws {
        _ = try open(src)
        guard let gs = Tool.ghostscript.path else { throw PeelError("缺少 Ghostscript", "Ghostscript missing") }
        let preset: String
        switch level {
        case .light: preset = "/printer"
        case .medium: preset = "/ebook"
        case .strong: preset = "/screen"
        }
        do {
            try Shell.run(gs, ["-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.5", "-dPDFSETTINGS=\(preset)",
                               "-dNOPAUSE", "-dQUIET", "-dBATCH", "-dDetectDuplicateImages=true",
                               "-sOutputFile=\(dst.path)", src.path])
        } catch {
            throw PeelError("PDF 压缩失败", "PDF compression failed")
        }
    }

    // MARK: - 合并

    static func merge(_ files: [URL], to dst: URL) throws {
        let out = PDFDocument()
        for url in files {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) { out.insert(page, at: out.pageCount) }
            }
        }
        guard out.write(to: dst) else { throw PeelError("无法生成 PDF", "Can't create PDF") }
    }
}
