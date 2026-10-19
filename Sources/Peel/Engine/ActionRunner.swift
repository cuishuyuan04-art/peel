import AppKit

/// 执行轮盘选中的操作
enum ActionRunner {
    /// 仅供开发测试（Peel --do …）
    static func debugPerform(_ action: PeelAction, files: [URL]) -> (outputs: [URL], errors: [LText]) {
        let r = perform(action, files: files, cached: [:]) { p in print(String(format: "progress %.0f%%", p * 100)) }
        return (r.outputs, r.errors)
    }

    private struct Result {
        var outputs: [URL] = []
        var errors: [LText] = []
        var before: Int64 = 0
        var after: Int64 = 0
        var alreadySmall = 0
        /// 压到指定大小：本来就不超过目标的文件数、压不到目标的文件
        var underTarget = 0
        var missedTarget: [LText] = []
    }

    static func run(_ node: WheelNode, path: [LText], files: [URL]) {
        guard let action = node.action else { return }
        // 自定义大小：先问要压到多大
        if case .compressTo(nil) = action {
            guard let bytes = askTargetSize() else { return }
            var n = node
            n.action = .compressTo(bytes)
            n.title = LText("≤ \(Catalog.formatBytes(bytes))")
            return run(n, path: Array(path.dropLast()) + [n.title], files: files)
        }
        let label = LText(path.map(\.zh).joined(separator: " › "), path.map(\.en).joined(separator: " › "))

        // 需要参数的编辑功能：先弹出设置窗口，确认后再执行
        switch action {
        case .crop, .resize, .addBackground, .metadata, .splitPDF, .redact, .idPhoto, .watermark, .sign:
            EditorWindow.open(action, file: files[0], title: node.title)
            return
        default:
            break
        }

        // 预估时已经压好的文件，在隐藏轮盘（会清空预估）之前先取走
        var cached: [URL: URL] = [:]
        if case .compress(let level) = action {
            for f in files { cached[f] = Estimator.shared.take(level, for: f) }
        }

        Deps.ensure(Deps.required(for: action, files: files)) {
            let working = LText("正在处理：\(label.zh)…", "Working: \(label.en)…")
            HUD.shared.progress(working.text)
            Jobs.queue.async {
                Jobs.begin(label)
                // 进度最多每 0.2 秒刷新一次提示条
                var lastUpdate = Date.distantPast
                let result = perform(action, files: files, cached: cached) { p in
                    guard Date().timeIntervalSince(lastUpdate) > 0.2 else { return }
                    lastUpdate = Date()
                    DispatchQueue.main.async {
                        guard Jobs.label != nil else { return }
                        HUD.shared.progress("\(working.text) \(Int(p * 100))%")
                    }
                }
                let cancelled = Jobs.isCancelled
                Jobs.end()
                DispatchQueue.main.async {
                    if cancelled {
                        HUD.shared.show(t("已取消", "Cancelled"), symbol: "stop.circle.fill")
                    } else {
                        report(result, action: action)
                    }
                }
            }
        }
    }

    // MARK: - 执行

    /// progress：整体进度 0…1（多个文件时按文件平均）
    private static func perform(_ action: PeelAction, files: [URL], cached: [URL: URL],
                                progress: @escaping (Double) -> Void) -> Result {
        var r = Result()
        let n = Double(files.count)
        /// 第 i 个文件的进度换算成整体进度
        func step(_ i: Int) -> (Double) -> Void { { p in progress((Double(i) + p) / n) } }
        func attempt(_ body: () throws -> Void) {
            do { try body() } catch let e as PeelError {
                r.errors.append(e.message)
            } catch {
                r.errors.append(LText("出错了：\(error.localizedDescription)", "Error: \(error.localizedDescription)"))
            }
        }

        switch action {
        case .convert(let target):
            for (i, f) in files.enumerated() where !Jobs.isCancelled {
                attempt { r.outputs += try convert(f, to: target, progress: step(i)) }
            }

        case .compressTo(let target?):
            for (i, f) in files.enumerated() where !Jobs.isCancelled {
                attempt {
                    let original = Output.size(f)
                    guard original > target else { r.underTarget += 1; return }   // 本来就够小，不用压
                    let res = try TargetCompressor.compress(f, target: target)
                    let dst = Output.sibling(of: f, ext: res.file.pathExtension, suffix: Output.compressedSuffix)
                    r.outputs.append(try Output.place(res.file, at: dst))
                    r.before += original
                    r.after += res.size
                    if !res.fits {
                        r.missedTarget.append(LText("「\(f.lastPathComponent)」最小只能压到 \(Catalog.formatBytes(res.size))",
                                                    "“\(f.lastPathComponent)” can only go down to \(Catalog.formatBytes(res.size))"))
                    }
                }
                progress(Double(i + 1) / n)
            }

        case .compressTo(nil):
            break

        case .compress(let level):
            for (i, f) in files.enumerated() where !Jobs.isCancelled {
                attempt {
                    let original = Output.size(f)
                    let dst = Output.sibling(of: f, ext: f.pathExtension, suffix: Output.compressedSuffix)
                    let tmp = try cached[f] ?? Estimator.compressToTemp(f, level: level, progress: step(i))
                    let size = Output.size(tmp)
                    r.before += original
                    guard size < original else {
                        r.alreadySmall += 1
                        r.after += original
                        return
                    }
                    // 可能换了扩展名（BMP/TIFF → JPG/PNG，WAV → M4A，AVI → MP4）
                    let final = tmp.pathExtension.lowercased() == f.pathExtension.lowercased()
                        ? dst : Output.unique(dst.deletingPathExtension().appendingPathExtension(tmp.pathExtension))
                    r.outputs.append(try Output.place(tmp, at: final))
                    r.after += size
                }
            }

        case .mergeToPDF:
            attempt {
                let sorted = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let dir = sorted[0].deletingLastPathComponent()
                let dst = Output.unique(dir.appendingPathComponent(t("合并", "Merged")).appendingPathExtension("pdf"))
                if sorted.allSatisfy({ FileKind.of($0) == .pdf }) {
                    try PDFEngine.merge(sorted, to: dst)
                } else {
                    try ImageEngine.makePDF(sorted, to: dst)
                }
                r.outputs.append(dst)
            }

        case .zip:
            attempt { r.outputs.append(try zip(files)) }

        case .extractAudio(let ext):
            for (i, f) in files.enumerated() where !Jobs.isCancelled {
                attempt {
                    let tmp = try Output.tempDir().appendingPathComponent("audio.\(ext)")
                    try MediaEngine.extractAudio(f, to: ext, dst: tmp, progress: step(i))
                    r.outputs.append(try Output.place(tmp, at: Output.sibling(of: f, ext: ext)))
                }
            }

        case .rotate(let degrees):
            for f in files where !Jobs.isCancelled {
                attempt { r.outputs.append(try EditEngine.rotate(f, degrees: degrees)) }
            }

        case .cutout:
            for (i, f) in files.enumerated() where !Jobs.isCancelled {
                attempt { r.outputs.append(try PortraitEngine.cutoutFile(f)) }
                progress(Double(i + 1) / n)
            }

        case .splitPDF, .redact, .metadata, .crop, .addBackground, .resize, .snap, .idPhoto, .watermark, .sign:
            // 这些由设置窗口通过 runJob 执行
            break
        }
        return r
    }

    /// 设置窗口确认后执行：在任务队列里跑，提示条显示进度和结果
    static func runJob(_ label: LText, work: @escaping () throws -> [URL]) {
        let working = LText("正在处理：\(label.zh)…", "Working: \(label.en)…")
        HUD.shared.progress(working.text)
        Jobs.queue.async {
            Jobs.begin(label)
            var r = Result()
            do {
                r.outputs = try work()
            } catch let e as PeelError {
                r.errors.append(e.message)
            } catch {
                r.errors.append(LText("出错了：\(error.localizedDescription)", "Error: \(error.localizedDescription)"))
            }
            let cancelled = Jobs.isCancelled
            Jobs.end()
            DispatchQueue.main.async {
                if cancelled {
                    HUD.shared.show(t("已取消", "Cancelled"), symbol: "stop.circle.fill")
                } else {
                    report(r, action: .zip)
                }
            }
        }
    }

    private static func convert(_ f: URL, to target: String, progress: @escaping (Double) -> Void) throws -> [URL] {
        switch FileKind.of(f) {
        case .image:
            return [try ImageEngine.convert(f, to: target)]
        case .pdf:
            switch target {
            case "txt": return [try PDFEngine.toText(f)]
            case "docx": return [try PDFEngine.toDocx(f)]
            default: return try PDFEngine.toImages(f, ext: target)
            }
        case .document, .presentation, .spreadsheet:
            return try OfficeEngine.convert(f, to: target)
        case .video, .audio:
            let tmp = try Output.tempDir().appendingPathComponent("out.\(target)")
            if FileKind.of(f) == .video && target != "mp3" && target != "m4a" {
                try MediaEngine.convertVideo(f, to: target, dst: tmp, progress: progress)
            } else {
                try MediaEngine.convertAudio(f, to: target, dst: tmp, progress: progress)
            }
            return [try Output.place(tmp, at: Output.sibling(of: f, ext: target))]
        case .other:
            throw PeelError.notYet
        }
    }

    private static func zip(_ files: [URL]) throws -> URL {
        let dir = files[0].deletingLastPathComponent()
        if files.count == 1 {
            let dst = Output.sibling(of: files[0], ext: "zip")
            try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", files[0].path, dst.path])
            return dst
        }
        let dst = Output.unique(dir.appendingPathComponent(t("归档", "Archive")).appendingPathExtension("zip"))
        // 文件可能来自不同文件夹：先汇集到临时目录再打包
        let stage = try Output.tempDir().appendingPathComponent(dst.deletingPathExtension().lastPathComponent)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for f in files {
            try FileManager.default.copyItem(at: f, to: Output.unique(stage.appendingPathComponent(f.lastPathComponent)))
        }
        try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", stage.path, dst.path])
        return dst
    }

    /// 自定义目标大小：输入数字 + 选单位
    private static func askTargetSize() -> Int64? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("压缩到多大？", "Compress to what size?")
        alert.informativeText = t("每个文件都会压到不超过这个大小。", "Each file will be at most this size.")
        let field = NSTextField(string: "1")
        field.frame = NSRect(x: 0, y: 0, width: 90, height: 24)
        let unit = NSPopUpButton(frame: NSRect(x: 98, y: 0, width: 72, height: 24), pullsDown: false)
        unit.addItems(withTitles: ["MB", "KB"])
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 170, height: 24))
        box.addSubview(field)
        box.addSubview(unit)
        alert.accessoryView = box
        alert.addButton(withTitle: t("压缩", "Compress"))
        alert.addButton(withTitle: t("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let value = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        let bytes = unit.indexOfSelectedItem == 0 ? value * 1_000_000 : value * 1_000
        return Int64(bytes)
    }

    // MARK: - 结果提示

    private static func report(_ r: Result, action: PeelAction) {
        let fmt = Catalog.formatBytes
        if r.outputs.isEmpty {
            if r.underTarget > 0 && r.errors.isEmpty {
                HUD.shared.show(t("文件本来就不超过这个大小，不用压缩", "Already under the target size"),
                                symbol: "info.circle.fill", duration: 3)
            } else if r.alreadySmall > 0 {
                HUD.shared.show(t("文件已经很小，这一档压不动了，试试更强的档位",
                                  "Already small — try a stronger level"), symbol: "info.circle.fill", duration: 3.5)
            } else if let e = r.errors.first {
                HUD.shared.show(e.text, symbol: "xmark.octagon.fill", duration: 4)
            }
            return
        }

        let names = r.outputs.count == 1
            ? "「\(r.outputs[0].lastPathComponent)」"
            : t(" \(r.outputs.count) 个文件", " \(r.outputs.count) files")
        var text = t("已生成\(names)", "Created\(names)")
        if case .compress = action, r.before > 0 {
            let pct = Int((1 - Double(r.after) / Double(r.before)) * 100)
            text += t("：\(fmt(r.before)) → \(fmt(r.after))（-\(pct)%）", ": \(fmt(r.before)) → \(fmt(r.after)) (-\(pct)%)")
        }
        if case .compressTo(let target?) = action, r.before > 0 {
            text += t("：\(fmt(r.before)) → \(fmt(r.after))（目标 \(fmt(target))）",
                      ": \(fmt(r.before)) → \(fmt(r.after)) (target \(fmt(target)))")
            if let miss = r.missedTarget.first { text += t("；", "; ") + miss.text }
            if r.underTarget > 0 {
                text += t("；\(r.underTarget) 个本来就够小，没有改动", "; \(r.underTarget) already small enough")
            }
        }
        if !r.errors.isEmpty {
            text += t("；\(r.errors.count) 个失败：\(r.errors[0].zh)", "; \(r.errors.count) failed: \(r.errors[0].en)")
        }
        HUD.shared.show(text, symbol: r.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        duration: r.errors.isEmpty ? 3 : 5)
    }
}
