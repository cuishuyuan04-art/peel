import SwiftUI

/// 证件照：自动抠出人像、按人脸自动构图；选尺寸和底色，可拖动 / 缩放微调，可选生成 6 寸排版
struct IDPhotoEditor: View {
    let src: URL
    let done: () -> Void

    /// 预览用（缩小过）的原图和抠好的人像；裁剪框用比例坐标，所以和原图通用
    @State private var source: CGImage?
    @State private var cutout: CGImage?
    @State private var failed: String?
    @State private var spec = IDPhotoSpec.domestic[0]
    /// 自动构图的结果，缩放以它为基准
    @State private var baseCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var zoom = 1.0
    @State private var dragStart: CGRect?
    @State private var color = Color.white
    @State private var printSheet = false
    /// 抠图超过几秒还没好：提示第一次使用需要准备模型
    @State private var slow = false

    private let swatches: [(LText, Color)] = [
        (LText("白", "White"), .white),
        (LText("蓝", "Blue"), Color(red: 67 / 255, green: 142 / 255, blue: 219 / 255)),
        (LText("红", "Red"), Color(red: 220 / 255, green: 20 / 255, blue: 40 / 255)),
        (LText("浅灰", "Light gray"), Color(white: 0.94)),
    ]

    var body: some View {
        EditorFrame(canApply: cutout != nil,
                    note: "\(spec.name.text) · \(spec.label) · \(Int(spec.pixelSize.width))×\(Int(spec.pixelSize.height)) px",
                    onApply: apply, done: done) {
            HStack(spacing: 20) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .frame(width: 270)
            }
            .padding(20)
        }
        .onAppear(perform: load)
    }

    // MARK: - 预览

    private var preview: some View {
        GeometryReader { geo in
            let aspect = spec.widthMM / spec.heightMM
            let d = aspectFit(CGSize(width: aspect, height: 1), in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 10, dy: 10))
            ZStack(alignment: .topLeading) {
                if let cutout,
                   let img = PortraitEngine.render(cutout: cutout, crop: crop,
                                                   size: CGSize(width: d.width * 2, height: d.height * 2),
                                                   background: NSColor(color).usingColorSpace(.sRGB)?.cgColor ?? .white) {
                    Image(decorative: img, scale: 2)
                        .resizable()
                        .frame(width: d.width, height: d.height)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                        .overlay(guides(height: d.height).frame(width: d.width, height: d.height))
                        .offset(x: d.minX, y: d.minY)
                        .gesture(DragGesture()
                            .onChanged { v in
                                let start = dragStart ?? crop
                                if dragStart == nil { dragStart = crop }
                                // 拖动照片：裁剪框往反方向移
                                crop.origin.x = start.minX - v.translation.width / d.width * start.width
                                crop.origin.y = start.minY - v.translation.height / d.height * start.height
                            }
                            .onEnded { _ in dragStart = nil })
                } else if let failed {
                    Text(failed).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(t("正在抠出人像…", "Cutting out the portrait…")).foregroundStyle(.secondary)
                        if slow {
                            Text(t("第一次使用时系统需要准备识别模型，可能要一分钟左右",
                                   "The first run prepares the recognition model and may take about a minute"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// 头顶、下巴的参考线（按当前规格的头部比例）
    private func guides(height h: CGFloat) -> some View {
        let top = h * 0.09, chin = h * (0.09 + spec.headRatio)
        return ZStack(alignment: .topLeading) {
            ForEach([top, chin], id: \.self) { y in
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: 10_000, y: y))
                }
                .stroke(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }

    // MARK: - 选项

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group(t("国内常用", "China")) { specChips(IDPhotoSpec.domestic) }
                group(t("留学 / 签证", "Visa")) { specChips(IDPhotoSpec.visa) }
                group(t("底色", "Background")) {
                    HStack(spacing: 10) {
                        ForEach(swatches.indices, id: \.self) { i in
                            let c = swatches[i].1
                            ColorSwatch(color: c, selected: c == color) { color = c }
                                .help(swatches[i].0.text)
                        }
                        ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                    }
                }
                group(t("大小", "Size")) {
                    HStack {
                        Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                        Slider(value: $zoom, in: 0.6...1.6)
                            .onChange(of: zoom) { z in applyZoom(z) }
                        Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                    }
                    Button(t("重新自动构图", "Auto-fit again")) { autoFit() }
                }
                Toggle(t("同时生成 6 寸排版（打印用）", "Also create a 4×6 print sheet"), isOn: $printSheet)
                Text(t("拖动照片调整位置；橙色虚线是头顶和下巴的参考位置。",
                       "Drag the photo to reposition. Orange lines mark where the crown and chin should be."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func specChips(_ specs: [IDPhotoSpec]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(specs, id: \.self) { s in
                let on = s == spec
                Button {
                    spec = s
                    autoFit()
                } label: {
                    HStack {
                        Text(s.name.text).fontWeight(.semibold)
                        Spacer()
                        Text(s.label).foregroundStyle(on ? Color.white.opacity(0.85) : .secondary)
                    }
                    .font(.system(size: 12, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(on ? PeelColors.ring : Color.secondary.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 逻辑

    private func load() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if cutout == nil { slow = true } }
        let file = src
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let img = try ImageEngine.load(file, maxPixel: 1600)
                let cut = try PortraitEngine.cutout(img, preferPerson: true, focus: PortraitEngine.faceCenter(img))
                DispatchQueue.main.async {
                    source = img
                    cutout = cut
                    autoFit()
                }
            } catch let e as PeelError {
                DispatchQueue.main.async { failed = e.message.text }
            } catch {
                DispatchQueue.main.async { failed = error.localizedDescription }
            }
        }
    }

    private func autoFit() {
        guard let source else { return }
        baseCrop = PortraitEngine.autoCrop(source, spec: spec)
        crop = baseCrop
        zoom = 1
    }

    /// 缩放：以当前裁剪框中心为基准，框越小人越大
    private func applyZoom(_ z: Double) {
        let w = baseCrop.width / z, h = baseCrop.height / z
        crop = CGRect(x: crop.midX - w / 2, y: crop.midY - h / 2, width: w, height: h)
    }

    private func apply() {
        let file = src, s = spec, c = crop, bg = NSColor(color), sheet = printSheet
        ActionRunner.runJob(LText("证件照", "ID photo")) {
            try PortraitEngine.idPhoto(file, spec: s, crop: c, background: bg, printSheet: sheet)
        }
    }
}
