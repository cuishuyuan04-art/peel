import PDFKit
import SwiftUI

/// PDF 签名：手写 / 打字 / 已保存的签名，拖到页面上放好，可顺带加日期
struct SignEditor: View {
    let src: URL
    let done: () -> Void

    private enum Source: Hashable { case draw, type, saved }

    @State private var doc: PDFDocument?
    @State private var pageIndex = 0
    @State private var pageImage: CGImage?
    @State private var pageAspect: CGFloat = 0.707   // 宽 / 高

    @State private var source = Source.draw
    @StateObject private var pad = PadModel()
    @State private var saveForLater = true
    @State private var typedName = ""
    @State private var fontIndex = 0
    @State private var saved: [URL] = []

    /// 放在页面上的签名和日期（比例坐标，原点左上）
    @State private var signature: CGImage?
    @State private var sigRect = CGRect(x: 0.6, y: 0.78, width: 0.28, height: 0.08)
    @State private var addDate = true
    @State private var dateFormat = 0
    @State private var dateRect = CGRect(x: 0.6, y: 0.87, width: 0.28, height: 0.022)
    @State private var dragStart: (sig: CGRect, date: CGRect)?

    private let fonts = SignatureStore.handwritingFonts

    var body: some View {
        EditorFrame(applyTitle: t("签名并生成", "Sign & Create"), canApply: signature != nil,
                    note: signature == nil ? t("先在右边准备签名", "Prepare a signature on the right")
                                           : t("拖动签名和日期调整位置，拖右下角调整大小", "Drag to move; drag the corner to resize"),
                    onApply: apply, done: done) {
            HStack(spacing: 20) {
                VStack(spacing: 10) {
                    pagePreview
                    HStack {
                        Button { go(pageIndex - 1) } label: { Image(systemName: "chevron.left") }.disabled(pageIndex == 0)
                        Text(t("第 \(pageIndex + 1) / \(doc?.pageCount ?? 0) 页", "Page \(pageIndex + 1) / \(doc?.pageCount ?? 0)"))
                            .monospacedDigit()
                        Button { go(pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(pageIndex + 1 >= (doc?.pageCount ?? 0))
                    }
                }
                panel.frame(width: 300)
            }
            .padding(20)
        }
        .onAppear {
            doc = PDFDocument(url: src)
            saved = SignatureStore.all()
            if saved.isEmpty == false { source = .saved }
            // 多页文件默认翻到最后一页（签名通常在最后）
            go(max(0, (doc?.pageCount ?? 1) - 1))
        }
    }

    // MARK: - 页面预览 + 可拖动的签名、日期

    private var pagePreview: some View {
        GeometryReader { geo in
            let d = aspectFit(CGSize(width: pageAspect, height: 1), in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                if let pageImage {
                    Image(decorative: pageImage, scale: 1)
                        .resizable()
                        .frame(width: d.width, height: d.height)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .offset(x: d.minX, y: d.minY)
                }
                if let signature {
                    let r = viewRect(sigRect, d)
                    Image(decorative: signature, scale: 1)
                        .resizable()
                        .frame(width: r.width, height: r.height)
                        .overlay(Rectangle().stroke(PeelColors.ring.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .offset(x: r.minX, y: r.minY)
                        .gesture(move(d, date: false))
                    resizeHandle(at: CGPoint(x: r.maxX, y: r.maxY), d: d)
                    if addDate {
                        let dr = viewRect(dateRect, d)
                        Text(dateText)
                            .font(.system(size: max(6, dr.height * 0.78)))
                            .foregroundStyle(Color(white: 0.08))
                            .fixedSize()
                            .frame(width: dr.width, height: dr.height, alignment: .leading)
                            .overlay(Rectangle().stroke(PeelColors.ring.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            .offset(x: dr.minX, y: dr.minY)
                            .gesture(move(d, date: true))
                    }
                }
            }
        }
    }

    private func viewRect(_ r: CGRect, _ d: CGRect) -> CGRect {
        CGRect(x: d.minX + r.minX * d.width, y: d.minY + r.minY * d.height, width: r.width * d.width, height: r.height * d.height)
    }

    private func move(_ d: CGRect, date: Bool) -> some Gesture {
        DragGesture()
            .onChanged { v in
                let start = dragStart ?? (sigRect, dateRect)
                if dragStart == nil { dragStart = start }
                let dx = v.translation.width / d.width, dy = v.translation.height / d.height
                if date {
                    dateRect.origin = CGPoint(x: start.date.minX + dx, y: start.date.minY + dy)
                } else {
                    sigRect.origin = CGPoint(x: start.sig.minX + dx, y: start.sig.minY + dy)
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    /// 右下角拖动：等比缩放签名
    private func resizeHandle(at p: CGPoint, d: CGRect) -> some View {
        Circle().fill(Color.white)
            .overlay(Circle().stroke(PeelColors.ring, lineWidth: 2))
            .frame(width: 12, height: 12)
            .position(p)
            .gesture(DragGesture()
                .onChanged { v in
                    let start = dragStart?.sig ?? sigRect
                    if dragStart == nil { dragStart = (sigRect, dateRect) }
                    let w = max(0.05, start.width + v.translation.width / d.width)
                    sigRect.size = CGSize(width: w, height: w * start.height / start.width)
                }
                .onEnded { _ in dragStart = nil })
    }

    // MARK: - 右侧：准备签名

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $source) {
                Text(t("手写", "Draw")).tag(Source.draw)
                Text(t("打字", "Type")).tag(Source.type)
                Text(t("已保存", "Saved")).tag(Source.saved)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch source {
            case .draw:
                SignaturePad(model: pad)
                    .frame(height: 140)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                    .overlay(alignment: .bottomLeading) {
                        if pad.isEmpty {
                            Text(t("用触控板或鼠标在这里签名", "Sign here with trackpad or mouse"))
                                .font(.callout).foregroundStyle(.secondary).padding(8)
                        }
                    }
                Toggle(t("保存，下次直接用", "Save for next time"), isOn: $saveForLater)
                HStack {
                    Button(t("清除", "Clear")) { pad.clear() }
                    Spacer()
                    Button(t("使用这个签名", "Use Signature")) {
                        guard let img = pad.export() else { return }
                        if saveForLater { SignatureStore.save(img); saved = SignatureStore.all() }
                        place(img)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pad.isEmpty)
                }
            case .type:
                TextField(t("你的名字", "Your name"), text: $typedName).textFieldStyle(.roundedBorder)
                if fonts.isEmpty {
                    Text(t("没有找到手写风格字体", "No handwriting fonts found")).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(fonts.indices, id: \.self) { i in
                                Button { fontIndex = i } label: {
                                    Text(typedName.isEmpty ? fonts[i].label : typedName)
                                        .font(.custom(fonts[i].name, size: 24))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(fontIndex == i ? PeelColors.ring.opacity(0.18) : Color.secondary.opacity(0.06),
                                                    in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                HStack {
                    Spacer()
                    Button(t("使用这个签名", "Use Signature")) {
                        guard !fonts.isEmpty, let img = SignatureStore.typed(typedName, font: fonts[fontIndex].name) else { return }
                        place(img)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(typedName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case .saved:
                if saved.isEmpty {
                    Text(t("还没有保存的签名，先在“手写”里签一个", "No saved signatures yet — draw one first"))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(saved, id: \.self) { url in
                                if let img = SignatureStore.load(url) {
                                    Button { place(img) } label: {
                                        Image(decorative: img, scale: 1)
                                            .resizable().aspectRatio(contentMode: .fit)
                                            .frame(height: 60).frame(maxWidth: .infinity)
                                            .padding(8)
                                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(t("删除这个签名", "Delete")) {
                                            SignatureStore.delete(url)
                                            saved = SignatureStore.all()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    Text(t("点一下放到页面上；右键可删除", "Click to place; right-click to delete"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Divider()
            Toggle(t("加日期", "Add date"), isOn: $addDate)
            if addDate {
                Picker("", selection: $dateFormat) {
                    ForEach(dateFormats.indices, id: \.self) { i in Text(format(i)).tag(i) }
                }
                .labelsHidden()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 逻辑

    private let dateFormats = ["yyyy-MM-dd", "yyyy年M月d日", "MMM d, yyyy", "dd/MM/yyyy"]

    private func format(_ i: Int) -> String {
        let f = DateFormatter()
        f.locale = i == 2 ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
        f.dateFormat = dateFormats[i]
        return f.string(from: Date())
    }

    private var dateText: String { format(dateFormat) }

    private func go(_ i: Int) {
        guard let doc, i >= 0, i < doc.pageCount, let page = doc.page(at: i) else { return }
        pageIndex = i
        pageImage = MarkEngine.previewPage(page, dpi: 100)
        if let img = pageImage { pageAspect = CGFloat(img.width) / CGFloat(img.height) }
    }

    /// 放到页面上：宽度约占页面 28%，默认在右下方；日期放在签名下面
    private func place(_ img: CGImage) {
        signature = img
        let w: CGFloat = 0.28
        let h = w * CGFloat(img.height) / CGFloat(img.width) * pageAspect
        sigRect = CGRect(x: 0.62, y: min(0.8, 0.92 - h), width: w, height: h)
        dateRect = CGRect(x: sigRect.minX, y: sigRect.maxY + 0.008, width: 0.25, height: 0.02)
    }

    private func apply() {
        guard let signature else { return }
        let placement = SignaturePlacement(page: pageIndex, image: signature, rect: sigRect,
                                           date: addDate ? (dateText, dateRect) : nil)
        let file = src
        ActionRunner.runJob(LText("签名", "Sign")) { [try MarkEngine.sign(file, placements: [placement])] }
    }
}

// MARK: - 手写签名板

final class PadModel: ObservableObject {
    @Published var isEmpty = true
    weak var view: PadView?

    func clear() {
        view?.strokes = []
        view?.needsDisplay = true
        isEmpty = true
    }

    func export() -> CGImage? { view?.exportImage() }
}

struct SignaturePad: NSViewRepresentable {
    @ObservedObject var model: PadModel

    func makeNSView(context: Context) -> PadView {
        let v = PadView()
        v.onChange = { [weak model] empty in model?.isEmpty = empty }
        model.view = v
        return v
    }

    func updateNSView(_ nsView: PadView, context: Context) {}
}

/// 记录笔画，画成平滑曲线；导出时裁掉四周空白，生成透明 PNG
final class PadView: NSView {
    var strokes: [[CGPoint]] = []
    var onChange: ((Bool) -> Void)?
    private let ink = NSColor(red: 0.05, green: 0.1, blue: 0.3, alpha: 1)
    private let lineWidth: CGFloat = 2.6

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
        onChange?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        ink.setStroke()
        for s in strokes { Self.path(s, width: lineWidth).stroke() }
    }

    /// 用相邻点的中点做二次曲线，笔画更顺滑
    static func path(_ pts: [CGPoint], width: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = width
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count < 3 {
            pts.dropFirst().forEach { p.line(to: $0) }
            if pts.count == 1 { p.line(to: CGPoint(x: first.x + 0.5, y: first.y)) }
            return p
        }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.curve(to: mid, controlPoint1: pts[i], controlPoint2: pts[i])
        }
        p.line(to: pts[pts.count - 1])
        return p
    }

    func exportImage(scale: CGFloat = 4) -> CGImage? {
        let all = strokes.flatMap { $0 }
        guard !all.isEmpty else { return nil }
        let pad: CGFloat = 6
        let minX = all.map(\.x).min()! - pad, maxX = all.map(\.x).max()! + pad
        let minY = all.map(\.y).min()! - pad, maxY = all.map(\.y).max()! + pad
        let w = Int((maxX - minX) * scale), h = Int((maxY - minY) * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 视图坐标 y 向下 → 位图 y 向上
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -minX, y: -minY)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        ink.setStroke()
        for s in strokes { Self.path(s, width: lineWidth).stroke() }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
