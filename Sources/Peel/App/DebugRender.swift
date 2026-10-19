import AppKit
import PDFKit
import Vision
import SwiftUI

/// 开发用：把轮盘渲染成 PNG，便于检查样式。
/// 用法：Peel --render out.png [--hover N] [--open N] [--en] 文件...
enum DebugRender {
    @MainActor static func runIfRequested() -> Bool {
        var args = Array(CommandLine.arguments.dropFirst())
        // 开发用：Peel --pin-test 图片（钉图窗口的缩放和滚轮）
        if args.first == "--pin-test", args.count >= 2, let img = NSImage(contentsOfFile: args[1]) {
            PinWindow.show(img)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let w = NSApp.windows.first(where: { $0 is PinWindow }), let v = w.contentView else { exit(1) }
                print("start", w.frame.size, type(of: v))
                // 模拟鼠标滚轮向上 3 格、触控板捏合放大
                for _ in 0..<3 {
                    if let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0),
                       let ns = NSEvent(cgEvent: e) { v.scrollWheel(with: ns) }
                }
                print("after scroll up x3", w.frame.size)
                for _ in 0..<2 {
                    if let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0),
                       let ns = NSEvent(cgEvent: e) { v.scrollWheel(with: ns) }
                }
                print("after scroll down x2", w.frame.size, "movable:", v.mouseDownCanMoveWindow)
                exit(0)
            }
            return true
        }
        // 开发用：Peel --ghost 输出.png 文件...（跟随光标的文件图标）
        if args.first == "--ghost", args.count >= 3 {
            let img = GhostIcon.image(for: args.dropFirst(2).map { URL(fileURLWithPath: $0) }, size: 112)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
            }
            exit(0)
        }
        // 开发用：Peel --anim-shot 目录 文件（弹出轮盘，逐帧截图检查动画）
        if args.first == "--anim-shot", args.count >= 3 {
            let dir = URL(fileURLWithPath: args[1])
            let c = WheelController.shared
            let screen = NSScreen.main!.visibleFrame
            c.show(at: NSPoint(x: screen.midX, y: screen.midY), files: [URL(fileURLWithPath: args[2])], mode: .click)
            func shot(_ name: String) {
                guard let v = NSApp.windows.first(where: { $0 is WheelPanel })?.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
            for i in 0..<8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01 + Double(i) * 0.05) { shot("in-\(i).png") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { c.hide() }
            for i in 0..<4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.02 + Double(i) * 0.05) { shot("out-\(i).png") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
            return true
        }
        // 开发用：Peel --editor-shot 操作 文件 输出.png（打开设置窗口并截图）
        if args.first == "--editor-shot", args.count >= 4 {
            let actions: [String: PeelAction] = ["crop": .crop, "resize": .resize, "bg": .addBackground,
                                                 "meta": .metadata, "split": .splitPDF, "redact": .redact]
            guard let action = actions[args[1]] else { exit(1) }
            EditorWindow.open(action, file: URL(fileURLWithPath: args[2]), title: LText(args[1]))
            let out = URL(fileURLWithPath: args[3])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let view = NSApp.windows.first(where: { $0.isVisible && $0.title.contains("·") })?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out)
                    print("wrote", out.path)
                }
                exit(0)
            }
            return true
        }
        // 开发用：Peel --icon-variants 目录（每种风格一张）
        if args.first == "--icon-variants", args.count >= 2 {
            let styles = args.count >= 3 && args[2] == "titles" ? IconStyle.titleOptions : IconStyle.all
            for (i, style) in styles.enumerated() {
                let url = URL(fileURLWithPath: args[1]).appendingPathComponent("variant-\(i).png")
                do { try IconRenderer.render(to: url, size: 512, style: style) } catch { print(error) }
                print(url.path, style.name)
            }
            exit(0)
        }
        if args.first == "--icon", args.count >= 2 {
            let size = args.count >= 3 ? CGFloat(Double(args[2]) ?? 1024) : 1024
            do { try IconRenderer.render(to: URL(fileURLWithPath: args[1]), size: size) } catch { print(error) }
            exit(0)
        }

        guard args.first == "--render", args.count >= 2 else { return false }
        args.removeFirst()
        let out = URL(fileURLWithPath: args.removeFirst())
        var hover: Int?
        var open: Int?
        var files: [URL] = []
        var snap = false
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--hover": hover = Int(args.removeFirst())
            case "--open": open = Int(args.removeFirst())
            case "--en": Settings.langOverride = .en
            case "--snap": snap = true
            default: files.append(URL(fileURLWithPath: a))
            }
        }

        WheelView.offscreen = true
        let c = WheelController.shared
        if snap {
            c.debugSnapshot(file: files[0], open: open, hover: hover)
        } else {
            c.debugSetup(files: files, open: open, hover: hover)
        }
        let view = ZStack {
            LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            WheelView(controller: c)
        }
        .frame(width: WheelMetrics.size, height: WheelMetrics.size)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let img = renderer.nsImage,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: out)
            print("wrote \(out.path)")
        }
        exit(0)
    }
}

/// 开发用的命令行测试（--edit / --do / --ocr）：不经过 App 启动流程，直接在后台线程执行。
/// （从终端直接运行时，系统有时不发“启动完成”，走 App 流程会一直等；
/// Vision 也不能在主线程同步等待。）由 main.swift 在启动 App 之前调用。
enum CLI {
    static let commands: Set<String> = ["--edit", "--do", "--ocr"]

    static func run(_ argv: [String]) -> Bool {
        var args = argv
        // 开发用：Peel --edit 操作 文件 [参数]（直接调用编辑功能）
        if args.first == "--edit", args.count >= 3 {
            let f = URL(fileURLWithPath: args[2])
            let p = args.count >= 4 ? args[3] : ""
            do {
                var out: [URL] = []
                switch args[1] {
                case "crop":
                    let v = p.split(separator: ",").compactMap { Double($0) }
                    guard v.count == 4 else { print("usage: --edit crop FILE x,y,w,h"); return true }
                    out = [try EditEngine.crop(f, rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))]
                case "resize":
                    let v = p.split(separator: "x").compactMap { Int($0) }
                    guard v.count == 2 else { print("usage: --edit resize FILE WxH"); return true }
                    out = [try EditEngine.resize(f, width: v[0], height: v[1])]
                case "bg": out = [try EditEngine.addBackground(f, color: .white, padding: 0.1, ratio: 1)]
                case "cutout": out = [try PortraitEngine.cutoutFile(f)]
                case "wm":      // 参数：bake / text
                    var st = WatermarkStyle()
                    st.text = "仅供 Peel 测试使用"
                    st.bake = p != "text"
                    out = [FileKind.of(f) == .pdf ? try MarkEngine.watermarkPDF(f, style: st) : try MarkEngine.watermarkImage(f, style: st)]
                case "fonts":
                    print(SignatureStore.handwritingFonts.map(\.label))
                case "sign":    // 用打字签名签在最后一页右下角，加日期
                    let n = PDFDocument(url: f)?.pageCount ?? 1
                    guard let font = SignatureStore.handwritingFonts.first,
                          let img = SignatureStore.typed(p.isEmpty ? "Shuyuan" : p, font: font.name) else { print("ERR no font"); break }
                    let w: CGFloat = 0.28, h = w * CGFloat(img.height) / CGFloat(img.width) * 0.707
                    let r = CGRect(x: 0.62, y: 0.8, width: w, height: h)
                    out = [try MarkEngine.sign(f, placements: [SignaturePlacement(page: n - 1, image: img, rect: r,
                                                   date: ("2026-10-16", CGRect(x: 0.62, y: r.maxY + 0.008, width: 0.25, height: 0.02)))])]
                case "instances":
                    let img = try ImageEngine.load(f, maxPixel: 1600)
                    let c = PortraitEngine.faceCenter(img)
                    print("face center:", c.map { String(format: "%.2f,%.2f", $0.x, $0.y) } ?? "nil")
                    if #available(macOS 14.0, *) {
                        let req = VNGeneratePersonInstanceMaskRequest()
                        let h = VNImageRequestHandler(cgImage: img)
                        do { try VisionRunner.perform([req], on: h) } catch { print("perform error:", error) }
                        if let o = req.results?.first {
                            print("instances:", Array(o.allInstances))
                            let lb = o.instanceMask
                            CVPixelBufferLockBaseAddress(lb, .readOnly)
                            let w = CVPixelBufferGetWidth(lb), hh = CVPixelBufferGetHeight(lb)
                            print("mask size:", w, hh, "format:", CVPixelBufferGetPixelFormatType(lb))
                            CVPixelBufferUnlockBaseAddress(lb, .readOnly)
                        } else { print("no results") }
                    }
                case "masktime":
                    let img = try ImageEngine.load(f, maxPixel: 1600)
                    for (name, person) in [("subject", false), ("person", true)] {
                        let t0 = Date()
                        _ = try? PortraitEngine.cutout(img, preferPerson: person)
                        print(name, String(format: "%.2fs", Date().timeIntervalSince(t0)))
                    }
                case "faces":
                    let img = try ImageEngine.load(f, maxPixel: 1200)
                    let req = VNDetectFaceRectanglesRequest()
                    try VNImageRequestHandler(cgImage: img).perform([req])
                    print("faces:", req.results?.count ?? 0, req.results?.map { String(format: "%.2f", $0.boundingBox.width) } ?? [])
                case "idphoto":
                    let spec = IDPhotoSpec.all[Int(p) ?? 0]
                    let img = try ImageEngine.load(f, maxPixel: 1600)
                    let crop = PortraitEngine.autoCrop(img, spec: spec)
                    out = try PortraitEngine.idPhoto(f, spec: spec, crop: crop,
                                                     background: NSColor(red: 67 / 255, green: 142 / 255, blue: 219 / 255, alpha: 1),
                                                     printSheet: true)
                case "noloc": out = [try EditEngine.stripMetadata(f, onlyLocation: true)]
                case "nometa": out = [try EditEngine.stripMetadata(f, onlyLocation: false)]
                case "rotate": out = [try EditEngine.rotate(f, degrees: Int(p) ?? 90)]
                case "split": out = try EditEngine.split(f, mode: p.isEmpty ? .everyPage
                    : .ranges(EditEngine.parseRanges(p, pageCount: PDFDocument(url: f)?.pageCount ?? 0) ?? []))
                case "redact":
                    let doc = PDFDocument(url: f)!
                    var boxes: [Int: [CGRect]] = [:]
                    for sel in doc.findString(p, withOptions: [.caseInsensitive]) {
                        for page in sel.pages { boxes[doc.index(for: page), default: []].append(sel.bounds(for: page)) }
                    }
                    print("matches:", boxes.values.reduce(0) { $0 + $1.count })
                    out = [try EditEngine.redact(f, rects: boxes)]
                case "pdfmeta":
                    var m = EditEngine.pdfMeta(f)
                    print("before:", m)
                    m.title = p
                    out = [try EditEngine.setPDFMeta(f, meta: m, clearAll: p.isEmpty)]
                default: break
                }
                for o in out { print("OUT", o.path) }
            } catch let e as PeelError {
                print("ERR", e.message.zh)
            } catch {
                print("ERR", error)
            }
            return true
        }
        // 开发用：Peel --ocr 图片
        if args.first == "--ocr", args.count >= 2 {
            print(SnapController.ocr(URL(fileURLWithPath: args[1])) ?? "(nil)")
            return true
        }
        // 开发用：Peel --do convert:pdf|compress:medium|merge|zip 文件...
        if args.first == "--do", args.count >= 3 {
            let spec = args[1].split(separator: ":").map(String.init)
            let files = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
            if spec[0] == "estimate" {
                for level in [CompressLevel.light, .medium, .strong] {
                    let est = files.reduce(Int64(0)) { sum, f in
                        sum + ((try? FileKind.of(f) == .video
                            ? MediaEngine.estimateVideo(f, level: level)
                            : MediaEngine.estimateAudio(f, level: level)) ?? 0)
                    }
                    print("EST", level, Catalog.formatBytes(est))
                }
                return true
            }
            let action: PeelAction
            switch spec[0] {
            case "convert": action = .convert(to: spec[1])
            case "compress": action = spec[1] == "light" ? .compress(.light) : spec[1] == "strong" ? .compress(.strong) : .compress(.medium)
            case "merge": action = .mergeToPDF
            case "target": action = .compressTo(Int64(spec[1]))
            case "extract": action = .extractAudio(to: spec[1])
            default: action = .zip
            }
            let missing = Deps.required(for: action, files: files)
            if !missing.isEmpty { print("missing:", missing.map(\.displayName)) }
            let r = ActionRunner.debugPerform(action, files: files)
            for o in r.outputs { print("OUT", o.path, Catalog.formatBytes(Output.size(o))) }
            for e in r.errors { print("ERR", e.zh) }
            return true
        }
        return false
    }
}
