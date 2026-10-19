import PDFKit
import SwiftUI

/// 加水印（PDF / 图片）：文字、模板、颜色、透明度、大小、角度、疏密；斜向平铺整页，实时预览
struct WatermarkEditor: View {
    let src: URL
    let done: () -> Void

    @State private var base: CGImage?          // 预览底图（PDF 第一页 / 缩小的图片）
    @State private var pageCount = 1
    @State private var style = WatermarkStyle()
    @State private var colorChoice = 0

    private var isPDF: Bool { FileKind.of(src) == .pdf }

    private let templates: [LText] = [
        LText("仅供 XX 申请使用", "For XX application only"),
        LText("复印无效", "Copy not valid"),
        LText("仅供本人使用", "For personal use only"),
        LText("机密 CONFIDENTIAL", "CONFIDENTIAL"),
        LText("草稿 DRAFT", "DRAFT"),
    ]
    private let colors: [(LText, NSColor)] = [
        (LText("灰", "Gray"), NSColor(white: 0.45, alpha: 1)),
        (LText("红", "Red"), NSColor(red: 0.85, green: 0.12, blue: 0.12, alpha: 1)),
        (LText("蓝", "Blue"), NSColor(red: 0.1, green: 0.35, blue: 0.8, alpha: 1)),
        (LText("黑", "Black"), .black),
    ]

    var body: some View {
        EditorFrame(canApply: base != nil && !style.text.trimmingCharacters(in: .whitespaces).isEmpty,
                    note: note, onApply: apply, done: done) {
            HStack(spacing: 20) {
                GeometryReader { geo in
                    if let base, let img = MarkEngine.previewImage(base, style: style) {
                        let d = aspectFit(CGSize(width: img.width, height: img.height),
                                          in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 8, dy: 8))
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .frame(width: d.width, height: d.height)
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                            .position(x: d.midX, y: d.midY)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                controls.frame(width: 280)
            }
            .padding(20)
        }
        .onAppear(perform: load)
    }

    private var note: String {
        if isPDF {
            return style.bake
                ? t("共 \(pageCount) 页 · 防移除：页面会转成图片，文字不能再复制", "\(pageCount) pages · tamper-proof: pages become images")
                : t("共 \(pageCount) 页 · 保留可复制的文字", "\(pageCount) pages · text stays selectable")
        }
        return t("会生成一个副本，原图不变", "Creates a copy; the original is untouched")
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("水印文字", "Text")).font(.headline)
                    TextField("", text: $style.text).textFieldStyle(.roundedBorder)
                    FlowChips(items: templates.map(\.text)) { style.text = $0 }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("颜色", "Color")).font(.headline)
                    HStack(spacing: 10) {
                        ForEach(colors.indices, id: \.self) { i in
                            ColorSwatch(color: Color(nsColor: colors[i].1), selected: colorChoice == i) {
                                colorChoice = i
                                style.color = colors[i].1
                            }
                            .help(colors[i].0.text)
                        }
                    }
                }
                slider(t("透明度", "Opacity"), value: $style.opacity, range: 0.08...0.6, format: { "\(Int($0 * 100))%" })
                slider(t("大小", "Size"), value: $style.size, range: 0.02...0.1, format: { _ in "" })
                slider(t("角度", "Angle"), value: $style.angle, range: -60...60, format: { "\(Int($0))°" })
                slider(t("疏密", "Spacing"), value: $style.spacing, range: 1.5...6, format: { _ in "" })
                if isPDF {
                    Toggle(t("防移除（页面转成图片）", "Tamper-proof (flatten pages)"), isOn: $style.bake)
                    Text(t("打开时水印和内容融为一体，无法被删掉，适合身份证、护照等复印件；但文字不能再复制。",
                           "When on, the watermark can't be removed — good for ID copies — but text can no longer be copied."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>,
                        format: @escaping (CGFloat) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(format(value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }

    private func load() {
        if isPDF {
            guard let doc = PDFDocument(url: src), let page = doc.page(at: 0) else { return }
            pageCount = doc.pageCount
            base = MarkEngine.previewPage(page, dpi: 100)
        } else {
            base = try? ImageEngine.load(src, maxPixel: 1400)
        }
    }

    private func apply() {
        let file = src, s = style, pdf = isPDF
        ActionRunner.runJob(LText("加水印", "Watermark")) {
            [pdf ? try MarkEngine.watermarkPDF(file, style: s) : try MarkEngine.watermarkImage(file, style: s)]
        }
    }
}

/// 自动换行的一组小按钮
struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { onTap(item) } label: {
                    Text(item)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
