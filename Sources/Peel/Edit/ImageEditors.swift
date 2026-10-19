import SwiftUI

/// 图片改尺寸：百分比 / 常用宽度预设，或自己输入宽高
struct ResizeEditor: View {
    let src: URL
    let done: () -> Void

    @State private var image: LoadedImage?
    @State private var width = ""
    @State private var height = ""
    @State private var lock = true

    var body: some View {
        EditorFrame(canApply: target != nil, note: note, onApply: apply, done: done) {
            Form {
                if let image {
                    LabeledContent(t("原尺寸", "Original")) {
                        Text("\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height)) px")
                    }
                }
                LabeledContent(t("按比例", "Scale")) {
                    HStack {
                        ForEach([75, 50, 25], id: \.self) { p in
                            Button("\(p)%") { setScale(Double(p) / 100) }
                        }
                    }
                }
                LabeledContent(t("按宽度", "Width")) {
                    HStack {
                        ForEach([1920, 1280, 1080], id: \.self) { w in
                            Button("\(w)") { setWidth(w) }
                        }
                    }
                }
                LabeledContent(t("宽", "Width")) {
                    TextField("", text: $width).frame(width: 90)
                        .onChange(of: width) { _ in syncFromWidth() }
                }
                LabeledContent(t("高", "Height")) {
                    TextField("", text: $height).frame(width: 90)
                        .onChange(of: height) { _ in syncFromHeight() }
                }
                Toggle(t("锁定宽高比", "Lock aspect ratio"), isOn: $lock)
            }
            .formStyle(.grouped)
        }
        .onAppear {
            image = LoadedImage.load(src, maxPixel: 64)
            if let image {
                width = String(Int(image.pixelSize.width))
                height = String(Int(image.pixelSize.height))
            }
        }
    }

    private var aspect: Double {
        guard let image, image.pixelSize.height > 0 else { return 1 }
        return image.pixelSize.width / image.pixelSize.height
    }

    // 联动时避免互相触发
    @State private var syncing = false

    private func syncFromWidth() {
        guard lock, !syncing, let w = Int(width) else { return }
        syncing = true
        height = String(max(1, Int((Double(w) / aspect).rounded())))
        DispatchQueue.main.async { syncing = false }
    }

    private func syncFromHeight() {
        guard lock, !syncing, let h = Int(height) else { return }
        syncing = true
        width = String(max(1, Int((Double(h) * aspect).rounded())))
        DispatchQueue.main.async { syncing = false }
    }

    private func setScale(_ s: Double) {
        guard let image else { return }
        syncing = true
        width = String(max(1, Int((image.pixelSize.width * s).rounded())))
        height = String(max(1, Int((image.pixelSize.height * s).rounded())))
        DispatchQueue.main.async { syncing = false }
    }

    private func setWidth(_ w: Int) {
        syncing = true
        width = String(w)
        height = String(max(1, Int((Double(w) / aspect).rounded())))
        DispatchQueue.main.async { syncing = false }
    }

    private var target: (Int, Int)? {
        guard let w = Int(width), let h = Int(height), w > 0, h > 0, w <= 30000, h <= 30000 else { return nil }
        return (w, h)
    }

    private var note: String? {
        guard let image, let (w, _) = target else { return t("请输入有效的宽高", "Enter a valid size") }
        return w > Int(image.pixelSize.width) ? t("放大会让图片变模糊", "Upscaling may look blurry") : nil
    }

    private func apply() {
        guard let (w, h) = target else { return }
        let file = src
        ActionRunner.runJob(LText("改尺寸", "Resize")) { [try EditEngine.resize(file, width: w, height: h)] }
    }
}

/// 图片加背景：底色 + 留白边距 + 画布比例，实时预览
struct BackgroundEditor: View {
    let src: URL
    let done: () -> Void

    @State private var image: LoadedImage?
    @State private var color = Color.white
    @State private var padding = 0.08
    @State private var ratio: Double? = nil

    private let swatches: [(String, Color)] = [
        ("白", .white), ("浅灰", Color(white: 0.94)), ("奶油", Color(red: 1.0, green: 0.96, blue: 0.9)),
        ("橙", Color(red: 1.0, green: 0.6, blue: 0.25)), ("黑", .black),
    ]

    var body: some View {
        EditorFrame(canApply: image != nil, note: sizeNote, onApply: apply, done: done) {
            VStack(spacing: 14) {
                GeometryReader { geo in
                    if let image {
                        let canvas = canvasSize(image)
                        let d = aspectFit(canvas, in: CGRect(origin: .zero, size: geo.size))
                        let s = d.width / canvas.width
                        ZStack {
                            Checkerboard()
                            Rectangle().fill(color)
                            Image(nsImage: image.preview)
                                .resizable()
                                .frame(width: image.pixelSize.width * s, height: image.pixelSize.height * s)
                        }
                        .frame(width: d.width, height: d.height)
                        .clipped()
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                        .position(x: d.midX, y: d.midY)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                HStack(spacing: 10) {
                    Text(t("底色", "Color")).foregroundStyle(.secondary)
                    ForEach(swatches.indices, id: \.self) { i in
                        let c = swatches[i].1
                        ColorSwatch(color: c, selected: c == color) { color = c }
                    }
                    ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                    Spacer()
                }
                HStack {
                    Text(t("边距", "Padding")).foregroundStyle(.secondary)
                    Slider(value: $padding, in: 0...0.3)
                    Text("\(Int(padding * 100))%").monospacedDigit().frame(width: 40)
                }
                HStack {
                    Text(t("画布", "Canvas")).foregroundStyle(.secondary)
                    ChipPicker(options: [(t("原比例", "Original"), nil), ("1:1", 1.0), ("4:5", 0.8),
                                         ("9:16", 9.0 / 16), ("16:9", 16.0 / 9)] as [(String, Double?)],
                               selection: $ratio)
                    Spacer()
                }
            }
            .padding(20)
        }
        .onAppear { image = LoadedImage.load(src, maxPixel: 1400) }
    }

    private func canvasSize(_ image: LoadedImage) -> CGSize {
        let (w, h) = EditEngine.canvasSize(imageWidth: Int(image.pixelSize.width), imageHeight: Int(image.pixelSize.height),
                                           padding: padding, ratio: ratio)
        return CGSize(width: w, height: h)
    }

    private var sizeNote: String? {
        guard let image else { return nil }
        let c = canvasSize(image)
        return "\(Int(c.width)) × \(Int(c.height)) px"
    }

    private func apply() {
        let file = src, ns = NSColor(color), p = padding, r = ratio
        ActionRunner.runJob(LText("加背景", "Add background")) {
            [try EditEngine.addBackground(file, color: ns, padding: p, ratio: r)]
        }
    }
}

/// 图片元数据：查看拍摄信息，去掉位置或全部元数据（生成副本）
struct PhotoMetaEditor: View {
    let src: URL
    let done: () -> Void
    @State private var info = EditEngine.PhotoInfo()

    var body: some View {
        EditorFrame(applyTitle: nil, done: done) {
            VStack(alignment: .leading, spacing: 16) {
                Form {
                    row(t("尺寸", "Size"), info.size)
                    row(t("拍摄时间", "Taken"), info.date)
                    row(t("相机", "Camera"), info.camera)
                    row(t("镜头", "Lens"), info.lens)
                    row(t("参数", "Exposure"), info.exposure)
                    row(t("位置", "Location"), info.location.map { String(format: "%.5f, %.5f", $0.lat, $0.lon) })
                }
                .formStyle(.grouped)
                HStack {
                    Button(t("去掉位置信息", "Remove location")) { run(onlyLocation: true) }
                        .disabled(info.location == nil)
                    Button(t("去掉全部元数据", "Remove all metadata")) { run(onlyLocation: false) }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .controlSize(.large)
                .padding(.horizontal, 20)
                Text(t("会生成一个副本，原图不变；JPG / PNG / HEIC 不会重新压缩，画质不变。",
                       "Creates a copy; the original is untouched. JPG / PNG / HEIC aren't re-compressed."))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                Spacer(minLength: 0)
            }
        }
        .onAppear { info = EditEngine.photoInfo(src) }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value ?? "—").foregroundStyle(value == nil ? .secondary : .primary).textSelection(.enabled)
        }
    }

    private func run(onlyLocation: Bool) {
        let file = src
        ActionRunner.runJob(onlyLocation ? LText("去掉位置信息", "Remove location") : LText("去掉元数据", "Remove metadata")) {
            [try EditEngine.stripMetadata(file, onlyLocation: onlyLocation)]
        }
        done()
    }
}
