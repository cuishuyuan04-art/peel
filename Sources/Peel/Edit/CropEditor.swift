import SwiftUI

/// 图片裁剪：拖动裁剪框（四角、四边、整体移动），可选固定比例
struct CropEditor: View {
    let src: URL
    let done: () -> Void

    @State private var image: LoadedImage?
    /// 裁剪框，相对图片的比例坐标（0…1，原点左上）
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// 固定比例（像素宽/高），nil 为自由
    @State private var ratio: Double? = nil
    @State private var dragStart: CGRect?

    private enum Handle { case tl, tr, bl, br, top, bottom, left, right, move }
    private let minSize: CGFloat = 0.03

    var body: some View {
        EditorFrame(canApply: image != nil, note: sizeText, onApply: apply, done: done) {
            VStack(spacing: 14) {
                HStack {
                    Text(t("比例", "Ratio")).foregroundStyle(.secondary)
                    ChipPicker(options: ratioOptions, selection: Binding(get: { ratio }, set: setRatio))
                    Spacer()
                    Button(t("重置", "Reset")) { setRatio(nil); crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                }
                GeometryReader { geo in
                    if let image {
                        let d = aspectFit(image.pixelSize, in: CGRect(origin: .zero, size: geo.size))
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: image.preview)
                                .resizable()
                                .frame(width: d.width, height: d.height)
                                .offset(x: d.minX, y: d.minY)
                            overlay(in: d)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(20)
        }
        .onAppear { image = LoadedImage.load(src) }
    }

    // MARK: - 叠加层

    @ViewBuilder private func overlay(in d: CGRect) -> some View {
        let r = CGRect(x: d.minX + crop.minX * d.width, y: d.minY + crop.minY * d.height,
                       width: crop.width * d.width, height: crop.height * d.height)
        // 裁剪框外压暗
        Path { p in
            p.addRect(d)
            p.addRect(r)
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)

        // 三分线 + 边框
        Path { p in
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.5), lineWidth: 0.8)
        .allowsHitTesting(false)

        Rectangle()
            .stroke(Color.white, lineWidth: 2)
            .frame(width: r.width, height: r.height)
            .contentShape(Rectangle())
            .offset(x: r.minX, y: r.minY)
            .gesture(drag(.move, in: d))

        ForEach(handles(r), id: \.0) { item in
            let (_, handle, point) = item
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(PeelColors.ring, lineWidth: 2))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle().inset(by: -8))
                .position(point)
                .gesture(drag(handle, in: d))
        }
    }

    private func handles(_ r: CGRect) -> [(Int, Handle, CGPoint)] {
        var list: [(Int, Handle, CGPoint)] = [
            (0, .tl, CGPoint(x: r.minX, y: r.minY)), (1, .tr, CGPoint(x: r.maxX, y: r.minY)),
            (2, .bl, CGPoint(x: r.minX, y: r.maxY)), (3, .br, CGPoint(x: r.maxX, y: r.maxY)),
        ]
        if ratio == nil {
            list += [(4, .top, CGPoint(x: r.midX, y: r.minY)), (5, .bottom, CGPoint(x: r.midX, y: r.maxY)),
                     (6, .left, CGPoint(x: r.minX, y: r.midY)), (7, .right, CGPoint(x: r.maxX, y: r.midY))]
        }
        return list
    }

    // MARK: - 拖动

    private func drag(_ handle: Handle, in d: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let start = dragStart ?? crop
                if dragStart == nil { dragStart = crop }
                let dx = v.translation.width / d.width, dy = v.translation.height / d.height
                crop = adjusted(start, handle: handle, dx: dx, dy: dy)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func adjusted(_ s: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        if handle == .move {
            let x = min(max(0, s.minX + dx), 1 - s.width), y = min(max(0, s.minY + dy), 1 - s.height)
            return CGRect(x: x, y: y, width: s.width, height: s.height)
        }
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        switch handle {
        case .tl: minX += dx; minY += dy
        case .tr: maxX += dx; minY += dy
        case .bl: minX += dx; maxY += dy
        case .br: maxX += dx; maxY += dy
        case .top: minY += dy
        case .bottom: maxY += dy
        case .left: minX += dx
        case .right: maxX += dx
        case .move: break
        }
        minX = max(0, min(minX, maxX - minSize)); maxX = min(1, max(maxX, minX + minSize))
        minY = max(0, min(minY, maxY - minSize)); maxY = min(1, max(maxY, minY + minSize))

        // 固定比例：以对角为锚点，按宽度推算高度，超出边界再反推宽度
        if let ratio, let image {
            let k = CGFloat(ratio) * image.pixelSize.height / image.pixelSize.width   // 比例坐标下的 宽/高
            let anchorX = (handle == .tl || handle == .bl) ? s.maxX : s.minX
            let anchorY = (handle == .tl || handle == .tr) ? s.maxY : s.minY
            var w = abs((handle == .tl || handle == .bl ? minX : maxX) - anchorX)
            var h = w / k
            let roomY = (handle == .tl || handle == .tr) ? anchorY : 1 - anchorY
            if h > roomY { h = roomY; w = h * k }
            minX = (handle == .tl || handle == .bl) ? anchorX - w : anchorX
            minY = (handle == .tl || handle == .tr) ? anchorY - h : anchorY
            return CGRect(x: minX, y: minY, width: w, height: h)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - 比例

    private var ratioOptions: [(String, Double?)] {
        var list: [(String, Double?)] = [(t("自由", "Free"), nil)]
        if let image { list.append((t("原比例", "Original"), image.pixelSize.width / image.pixelSize.height)) }
        return list + [("1:1", 1), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]
    }

    /// 换比例时，裁剪框变成该比例下最大的居中区域
    private func setRatio(_ r: Double?) {
        ratio = r
        guard let r, let image else { return }
        let k = CGFloat(r) * image.pixelSize.height / image.pixelSize.width
        var w: CGFloat = 1, h = 1 / k
        if h > 1 { h = 1; w = k }
        crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private var pixelRect: CGRect {
        guard let image else { return .zero }
        let W = image.pixelSize.width, H = image.pixelSize.height
        return CGRect(x: (crop.minX * W).rounded(), y: (crop.minY * H).rounded(),
                      width: (crop.width * W).rounded(), height: (crop.height * H).rounded())
    }

    private var sizeText: String? {
        guard image != nil else { return nil }
        return "\(Int(pixelRect.width)) × \(Int(pixelRect.height)) px"
    }

    private func apply() {
        let rect = pixelRect
        let file = src
        ActionRunner.runJob(LText("裁剪", "Crop")) { [try EditEngine.crop(file, rect: rect)] }
    }
}
