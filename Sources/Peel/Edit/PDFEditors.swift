import PDFKit
import SwiftUI

/// PDF 拆分：每页一个文件 / 每 N 页一个文件 / 提取指定页码
struct SplitEditor: View {
    let src: URL
    let done: () -> Void

    private enum Mode: Hashable { case every, chunks, ranges }
    @State private var pageCount = 0
    @State private var mode = Mode.every
    @State private var chunk = 2
    @State private var rangeText = ""

    var body: some View {
        EditorFrame(canApply: splitMode != nil, note: note, onApply: apply, done: done) {
            Form {
                LabeledContent(t("页数", "Pages")) { Text("\(pageCount)") }
                Picker(t("方式", "Mode"), selection: $mode) {
                    Text(t("每页一个文件", "One file per page")).tag(Mode.every)
                    Text(t("每 N 页一个文件", "Every N pages")).tag(Mode.chunks)
                    Text(t("提取指定页码", "Extract pages")).tag(Mode.ranges)
                }
                .pickerStyle(.radioGroup)
                if mode == .chunks {
                    Stepper(value: $chunk, in: 1...max(1, pageCount)) {
                        Text(t("每 \(chunk) 页", "Every \(chunk) pages"))
                    }
                }
                if mode == .ranges {
                    TextField(t("页码", "Pages"), text: $rangeText, prompt: Text(t("例如 1-3, 5, 8-10", "e.g. 1-3, 5, 8-10")))
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { pageCount = PDFDocument(url: src)?.pageCount ?? 0 }
    }

    private var splitMode: EditEngine.SplitMode? {
        guard pageCount > 0 else { return nil }
        switch mode {
        case .every: return .everyPage
        case .chunks: return .chunks(chunk)
        case .ranges: return EditEngine.parseRanges(rangeText, pageCount: pageCount).map { .ranges($0) }
        }
    }

    private var note: String? {
        switch mode {
        case .every: return t("生成 \(pageCount) 个文件，放在一个文件夹里", "\(pageCount) files in a folder")
        case .chunks: return t("生成 \((pageCount + chunk - 1) / max(1, chunk)) 个文件，放在一个文件夹里",
                              "\((pageCount + chunk - 1) / max(1, chunk)) files in a folder")
        case .ranges:
            if rangeText.isEmpty { return t("这些页会合成一个新的 PDF", "Selected pages go into one new PDF") }
            return splitMode == nil ? t("页码格式不对或超出范围（共 \(pageCount) 页）", "Invalid pages (\(pageCount) total)") : nil
        }
    }

    private func apply() {
        guard let m = splitMode else { return }
        let file = src
        ActionRunner.runJob(LText("拆分", "Split")) { try EditEngine.split(file, mode: m) }
    }
}

/// PDF 元数据：查看 / 修改标题、作者等，或全部清空
struct PDFMetaEditor: View {
    let src: URL
    let done: () -> Void
    @State private var meta = EditEngine.PDFMeta()
    @State private var clearAll = false

    var body: some View {
        EditorFrame(applyTitle: clearAll ? t("清空并生成", "Clear & Create") : t("保存副本", "Save Copy"),
                    note: t("会生成一个副本，原文件不变", "Creates a copy; the original is untouched"),
                    onApply: apply, done: done) {
            Form {
                Section {
                    TextField(t("标题", "Title"), text: $meta.title)
                    TextField(t("作者", "Author"), text: $meta.author)
                    TextField(t("主题", "Subject"), text: $meta.subject)
                    TextField(t("关键词", "Keywords"), text: $meta.keywords)
                }
                .disabled(clearAll)
                Section {
                    LabeledContent(t("创建工具", "Creator")) { Text(meta.creator.isEmpty ? "—" : meta.creator) }
                    LabeledContent(t("生成工具", "Producer")) { Text(meta.producer.isEmpty ? "—" : meta.producer) }
                    LabeledContent(t("创建时间", "Created")) { Text(meta.created.isEmpty ? "—" : meta.created) }
                }
                Toggle(t("清空全部元数据", "Clear all metadata"), isOn: $clearAll)
            }
            .formStyle(.grouped)
        }
        .onAppear { meta = EditEngine.pdfMeta(src) }
    }

    private func apply() {
        let file = src, m = meta, clear = clearAll
        ActionRunner.runJob(LText("PDF 元数据", "PDF metadata")) { [try EditEngine.setPDFMeta(file, meta: m, clearAll: clear)] }
    }
}

/// PDF 涂黑：在页面上框选，或搜索文字一键涂黑。被涂黑的页面会转成图片，底下的内容被彻底移除
struct RedactEditor: View {
    let src: URL
    let done: () -> Void

    @State private var doc: PDFDocument?
    @State private var pageIndex = 0
    @State private var pageImage: CGImage?
    /// 页码 → 页面坐标里的涂黑框
    @State private var boxes: [Int: [CGRect]] = [:]
    @State private var drawing: CGRect?
    @State private var query = ""
    @State private var found: Int?

    private let dpi: CGFloat = 110

    var body: some View {
        EditorFrame(applyTitle: t("涂黑并生成", "Redact & Create"), canApply: total > 0,
                    note: t("已涂黑 \(total) 处 · 涂黑的页面会转成图片，文字无法再被复制或搜索",
                            "\(total) boxes · redacted pages become images; text can't be copied or found"),
                    onApply: apply, done: done) {
            VStack(spacing: 12) {
                HStack {
                    TextField(t("搜索要涂黑的文字，如手机号、姓名", "Find text to redact, e.g. a phone number"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(redactMatches)
                    Button(t("全部涂黑", "Redact All"), action: redactMatches).disabled(query.isEmpty)
                    if let found {
                        Text(t("找到 \(found) 处", "\(found) found")).foregroundStyle(.secondary)
                    }
                }
                GeometryReader { geo in
                    if let pageImage, let page = doc?.page(at: pageIndex) {
                        let size = CGSize(width: pageImage.width, height: pageImage.height)
                        let d = aspectFit(size, in: CGRect(origin: .zero, size: geo.size))
                        ZStack(alignment: .topLeading) {
                            Image(decorative: pageImage, scale: 1)
                                .resizable()
                                .frame(width: d.width, height: d.height)
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                                .offset(x: d.minX, y: d.minY)
                                .gesture(drawGesture(page: page, d: d, imageSize: size))
                            ForEach(Array((boxes[pageIndex] ?? []).enumerated()), id: \.offset) { i, box in
                                let r = toView(box, page: page, d: d, imageSize: size)
                                Rectangle().fill(Color.black)
                                    .frame(width: r.width, height: r.height)
                                    .offset(x: r.minX, y: r.minY)
                                    .onTapGesture { boxes[pageIndex]?.remove(at: i) }
                                    .help(t("点击删除", "Click to remove"))
                            }
                            if let drawing {
                                Rectangle().fill(Color.black.opacity(0.6))
                                    .frame(width: drawing.width, height: drawing.height)
                                    .offset(x: drawing.minX, y: drawing.minY)
                            }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                HStack {
                    Text(t("在页面上拖动画框，点黑框可删除", "Drag on the page to add a box; click a box to remove it"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button { go(pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(pageIndex == 0)
                    Text("\(pageIndex + 1) / \(doc?.pageCount ?? 0)").monospacedDigit()
                    Button { go(pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(pageIndex + 1 >= (doc?.pageCount ?? 0))
                }
            }
            .padding(20)
        }
        .onAppear {
            doc = PDFDocument(url: src)
            go(0)
        }
    }

    private var total: Int { boxes.values.reduce(0) { $0 + $1.count } }

    private func go(_ i: Int) {
        guard let doc, i >= 0, i < doc.pageCount, let page = doc.page(at: i) else { return }
        pageIndex = i
        pageImage = try? PDFEngine.render(page, dpi: dpi)
    }

    // MARK: - 坐标换算：页面坐标 ↔ 渲染图（原点左下）↔ 视图（原点左上）

    private func toView(_ box: CGRect, page: PDFPage, d: CGRect, imageSize: CGSize) -> CGRect {
        let s = dpi / 72
        let img = box.applying(page.transform(for: .mediaBox)).applying(CGAffineTransform(scaleX: s, y: s))
        let k = d.width / imageSize.width
        return CGRect(x: d.minX + img.minX * k, y: d.minY + (imageSize.height - img.maxY) * k,
                      width: img.width * k, height: img.height * k)
    }

    private func toPage(_ r: CGRect, page: PDFPage, d: CGRect, imageSize: CGSize) -> CGRect {
        let s = dpi / 72
        let k = d.width / imageSize.width
        let img = CGRect(x: (r.minX - d.minX) / k, y: imageSize.height - (r.maxY - d.minY) / k,
                         width: r.width / k, height: r.height / k)
        let toImage = page.transform(for: .mediaBox).concatenating(CGAffineTransform(scaleX: s, y: s))
        return img.applying(toImage.inverted())
    }

    private func drawGesture(page: PDFPage, d: CGRect, imageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                // 手势坐标相对图片，换成相对整个区域
                let a = CGPoint(x: v.startLocation.x + d.minX, y: v.startLocation.y + d.minY)
                let b = CGPoint(x: v.location.x + d.minX, y: v.location.y + d.minY)
                drawing = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    .intersection(d)
            }
            .onEnded { _ in
                if let r = drawing, r.width > 4, r.height > 4 {
                    boxes[pageIndex, default: []].append(toPage(r, page: page, d: d, imageSize: imageSize))
                }
                drawing = nil
            }
    }

    private func redactMatches() {
        guard let doc, !query.isEmpty else { return }
        var count = 0
        for sel in doc.findString(query, withOptions: [.caseInsensitive]) {
            for page in sel.pages {
                let i = doc.index(for: page)
                boxes[i, default: []].append(sel.bounds(for: page).insetBy(dx: -1.5, dy: -1.5))
                count += 1
            }
        }
        found = count
    }

    private func apply() {
        let file = src, b = boxes
        ActionRunner.runJob(LText("涂黑", "Redact")) { [try EditEngine.redact(file, rects: b)] }
    }
}
