import AppKit
import CoreImage
import CoreML
import UniformTypeIdentifiers
import Vision

/// 证件照规格（毫米；输出 300 dpi）
struct IDPhotoSpec: Hashable {
    let name: LText
    let widthMM: Double
    let heightMM: Double
    /// 头部（头顶到下巴）占照片高度的比例
    var headRatio: Double = 0.62

    var pixelSize: CGSize {
        CGSize(width: (widthMM / 25.4 * 300).rounded(), height: (heightMM / 25.4 * 300).rounded())
    }
    var label: String { "\(Int(widthMM))×\(Int(heightMM))mm" }

    static let domestic: [IDPhotoSpec] = [
        IDPhotoSpec(name: LText("1 寸", "1-inch"), widthMM: 25, heightMM: 35),
        IDPhotoSpec(name: LText("小 2 寸 · 护照", "Small 2-inch · Passport"), widthMM: 33, heightMM: 48),
        IDPhotoSpec(name: LText("2 寸", "2-inch"), widthMM: 35, heightMM: 49),
    ]
    static let visa: [IDPhotoSpec] = [
        IDPhotoSpec(name: LText("美国签证", "US Visa"), widthMM: 50.8, heightMM: 50.8, headRatio: 0.58),
        IDPhotoSpec(name: LText("申根 / 英国", "Schengen / UK"), widthMM: 35, heightMM: 45, headRatio: 0.72),
        IDPhotoSpec(name: LText("日本签证", "Japan Visa"), widthMM: 45, heightMM: 45, headRatio: 0.65),
        IDPhotoSpec(name: LText("加拿大", "Canada"), widthMM: 50, heightMM: 70, headRatio: 0.5),
    ]
    static let all = domestic + visa
}

/// 让 Vision 请求只用 CPU 计算。
/// 默认会用神经网络引擎（ANE），但它偶尔会卡住（系统服务出状况时请求会一直等），
/// 用 CPU 慢一点（一张照片约一秒），但稳定、结果一样
enum VisionRunner {
    private static let queue = DispatchQueue(label: "peel.vision", qos: .userInitiated, attributes: .concurrent)

    /// 每一步识别最多等这么久：系统识别服务偶尔会卡住不回应，不能让用户一直等
    static let timeout: TimeInterval = 20

    static func perform(_ requests: [VNRequest], on handler: VNImageRequestHandler) throws {
        for req in requests { useCPU(req) }
        try withTimeout { try handler.perform(requests) }
    }

    /// 在单独的线程上执行，超时就放弃并报错
    static func withTimeout<T>(_ work: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        queue.async {
            result = Result { try work() }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let result else {
            Log.write("vision timed out")
            throw PeelError("系统的图像识别服务没有响应，重启电脑通常可以解决",
                            "The system's image recognition service isn't responding — restarting your Mac usually fixes it")
        }
        return try result.get()
    }

    static func useCPU(_ req: VNRequest) {
        if #available(macOS 14.0, *) {
            // 只有这一步支持 CPU 时才切换（有些识别只能在神经网络引擎 / GPU 上跑）
            for (stage, devices) in (try? req.supportedComputeStageDevices) ?? [:] {
                if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                    req.setComputeDevice(cpu, for: stage)
                }
            }
        } else {
            req.usesCPUOnly = true
        }
    }
}

/// 抠图（人像 / 主体）与证件照
enum PortraitEngine {
    private static let ci = CIContext()

    // MARK: - 抠图

    /// 抠出主体，返回带透明通道的图（和原图同尺寸）。
    /// preferPerson：证件照用人像分割（发丝更好）；focus：只保留这个位置上的那个人（比例坐标，原点左上）
    static func cutout(_ img: CGImage, preferPerson: Bool, focus: CGPoint? = nil) throws -> CGImage {
        var mask: CIImage?
        if !preferPerson, #available(macOS 14.0, *) {
            mask = try subjectMask(img) ?? personMask(img)
        } else {
            if let focus, #available(macOS 14.0, *) { mask = try? personInstanceMask(img, at: focus) }
            if mask == nil { mask = try personMask(img) }
        }
        guard let mask else {
            throw PeelError("没有识别出可以抠出来的主体", "No subject found to cut out")
        }
        let base = CIImage(cgImage: img)
        let sx = base.extent.width / mask.extent.width, sy = base.extent.height / mask.extent.height
        let scaledMask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let blend = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: base,
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: base.extent),
            kCIInputMaskImageKey: scaledMask,
        ])
        guard let out = blend?.outputImage,
              let cg = ci.createCGImage(out, from: base.extent, format: .RGBA8,
                                        colorSpace: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw PeelError("抠图失败", "Cutout failed")
        }
        return cg
    }

    private static func personMask(_ img: CGImage) throws -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VisionRunner.perform([req], on: VNImageRequestHandler(cgImage: img))
        guard let buffer = req.results?.first?.pixelBuffer else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }

    /// 画面里有好几个人时，只取 focus 位置上的那一个
    @available(macOS 14.0, *)
    private static func personInstanceMask(_ img: CGImage, at focus: CGPoint) throws -> CIImage? {
        let req = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: img)
        try VisionRunner.perform([req], on: handler)
        guard let obs = req.results?.first, obs.allInstances.count > 1 else { return nil }   // 只有一个人：用普通分割即可
        // instanceMask 每个像素是所属的人的编号（0 = 背景）
        let labels = obs.instanceMask
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels)
        guard let base = CVPixelBufferGetBaseAddress(labels) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(labels)
        let x = min(w - 1, max(0, Int(focus.x * Double(w)))), y = min(h - 1, max(0, Int(focus.y * Double(h))))
        let id = Int(base.load(fromByteOffset: y * row + x, as: UInt8.self))
        guard id > 0, obs.allInstances.contains(id) else { return nil }
        let buffer = try VisionRunner.withTimeout {
            try obs.generateScaledMaskForImage(forInstances: IndexSet(integer: id), from: handler)
        }
        return CIImage(cvPixelBuffer: buffer)
    }

    @available(macOS 14.0, *)
    private static func subjectMask(_ img: CGImage) throws -> CIImage? {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: img)
        try VisionRunner.perform([req], on: handler)
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else { return nil }
        let buffer = try VisionRunner.withTimeout {
            try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        }
        return CIImage(cvPixelBuffer: buffer)
    }

    /// 透明 PNG：抠出主体并裁掉四周的空白
    static func cutoutFile(_ src: URL) throws -> URL {
        let img = try ImageEngine.load(src)
        let cut = try cutout(img, preferPerson: false)
        let trimmed = trimTransparent(cut) ?? cut
        let dst = Output.sibling(of: src, ext: "png", suffix: t("_抠图", "_cutout"))
        try ImageEngine.write(trimmed, type: .png, to: dst)
        return dst
    }

    /// 裁掉透明边（留一点余量）
    private static func trimTransparent(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in stride(from: 0, to: w, by: 1) where px[row + x * 4 + 3] > 16 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = Int(Double(max(maxX - minX, maxY - minY)) * 0.03)
        // 位图缓冲区第 0 行是图片顶部
        let r = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                       width: min(w, maxX + pad + 1) - max(0, minX - pad),
                       height: min(h, maxY + pad + 1) - max(0, minY - pad))
        return ctx.makeImage()?.cropping(to: r)
    }

    // MARK: - 证件照

    /// 最大那张脸（Vision 坐标：比例，原点左下）
    private static func mainFace(_ img: CGImage) -> CGRect? {
        let req = VNDetectFaceRectanglesRequest()
        try? VisionRunner.perform([req], on: VNImageRequestHandler(cgImage: img))
        return req.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox
    }

    /// 人脸中心（比例坐标，原点左上），用来只抠这个人
    static func faceCenter(_ img: CGImage) -> CGPoint? {
        mainFace(img).map { CGPoint(x: $0.midX, y: 1 - $0.midY) }
    }

    /// 自动构图：按人脸位置和规格的头部比例算出裁剪框（比例坐标，原点左上）。
    /// 左右超出照片的部分会用底色填上；但不超出照片底边（否则身体会被截成一条横边）
    static func autoCrop(_ img: CGImage, spec: IDPhotoSpec) -> CGRect {
        let W = Double(img.width), H = Double(img.height)
        let aspect = spec.widthMM / spec.heightMM
        guard let face = mainFace(img) else {
            // 没找到人脸：取中间偏上的区域
            let h = 0.9, w = h * H / W * aspect
            return CGRect(x: 0.5 - w / 2, y: 0.03, width: w, height: h)
        }
        // Vision 的人脸框大约是眉毛到下巴，原点在左下；头顶再往上约 0.5 个脸高
        let faceH = face.height * H
        let headH = faceH * 1.5
        let cropH = headH / spec.headRatio
        let cropW = cropH * aspect
        let chinY = (1 - face.minY) * H                       // 换成原点左上
        let crownY = chinY - headH
        let top = crownY - cropH * 0.09                         // 头顶上方留一点空
        let cx = face.midX * W
        var rect = CGRect(x: (cx - cropW / 2) / W, y: top / H, width: cropW / W, height: cropH / H)
        if rect.maxY > 1 {
            // 照片底部不够：保持头顶位置，把框缩小到正好到底边（人像会稍大一点）
            let h = max(0.2, 1 - rect.minY)
            let w = rect.width * h / rect.height
            rect = CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h)
        }
        return rect
    }

    /// 把抠好的人像按裁剪框画到指定尺寸的底色画布上
    static func render(cutout: CGImage, crop: CGRect, size: CGSize, background: CGColor) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        // crop（比例坐标，原点左上）→ 整张图画到画布上的位置（CG 原点左下）
        let iw = size.width / crop.width, ih = size.height / crop.height
        let x = -crop.minX * iw
        let yTop = -crop.minY * ih
        ctx.draw(cutout, in: CGRect(x: x, y: size.height - (yTop + ih), width: iw, height: ih))
        return ctx.makeImage()
    }

    /// 生成证件照（和可选的 6 寸排版），返回生成的文件
    static func idPhoto(_ src: URL, spec: IDPhotoSpec, crop: CGRect, background: NSColor, printSheet: Bool) throws -> [URL] {
        let img = try ImageEngine.load(src)
        let cut = try cutout(img, preferPerson: true, focus: faceCenter(img))
        let bg = background.usingColorSpace(.sRGB)?.cgColor ?? background.cgColor
        guard let photo = render(cutout: cut, crop: crop, size: spec.pixelSize, background: bg) else {
            throw PeelError("证件照生成失败", "Failed to create ID photo")
        }
        let dir = src.deletingLastPathComponent()
        let name = src.deletingPathExtension().lastPathComponent + "_"
            + t("\(spec.name.zh)证件照", "\(spec.name.en) ID photo").replacingOccurrences(of: " · ", with: "_")
        let dst = Output.unique(dir.appendingPathComponent(name).appendingPathExtension("jpg"))
        try writeJPEG300(photo, to: dst)
        var out = [dst]
        if printSheet, let sheet = layout(photo, spec: spec) {
            let sheetURL = Output.unique(dir.appendingPathComponent(name + t("_6寸排版", "_4x6 print")).appendingPathExtension("jpg"))
            try writeJPEG300(sheet, to: sheetURL)
            out.append(sheetURL)
        }
        return out
    }

    /// 6 寸相纸（4×6 英寸，横向，300 dpi）上尽量多地排同一张证件照，带浅灰裁切线
    static func layout(_ photo: CGImage, spec: IDPhotoSpec) -> CGImage? {
        let sheetW = 1800, sheetH = 1200
        let pw = Int(spec.pixelSize.width), ph = Int(spec.pixelSize.height)
        let gap = 24   // 约 2mm
        let cols = max(1, (sheetW - gap) / (pw + gap)), rows = max(1, (sheetH - gap) / (ph + gap))
        guard let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
        let ox = (sheetW - cols * pw - (cols - 1) * gap) / 2
        let oy = (sheetH - rows * ph - (rows - 1) * gap) / 2
        ctx.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
        ctx.setLineWidth(1)
        for r in 0..<rows {
            for c in 0..<cols {
                let rect = CGRect(x: ox + c * (pw + gap), y: oy + r * (ph + gap), width: pw, height: ph)
                ctx.draw(photo, in: rect)
                ctx.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
            }
        }
        return ctx.makeImage()
    }

    /// JPEG，写入 300 dpi（冲印店和打印机按这个尺寸输出）
    private static func writeJPEG300(_ img: CGImage, to url: URL) throws {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PeelError("无法生成 JPG", "Can't create JPG")
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95,
                                      kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300]
        CGImageDestinationAddImage(dst, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw PeelError("无法生成 JPG", "Can't create JPG") }
    }
}
