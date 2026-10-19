import AppKit
import SwiftUI

/// 图标风格：颜色、剥开大小等
struct IconStyle {
    var name: String
    var cut: CGFloat = 470                 // 从右上角沿 45° 剥开的大小
    var curl: CGFloat = 0.84               // 页角翻起后的透视收缩（1 = 平铺镜像）
    var segments = 5
    var page: [Color]
    var line: Color
    var lineCount = 6
    var rind: Color
    var pith: Color
    var flesh: [Color]                     // 果肉：中心 → 外缘
    var flap: [Color]                      // 页角背面：折痕 → 尖端
    var pores = true
    var foldHighlight: Color = .white
    var shadow: Color = Color(red: 0.45, green: 0.2, blue: 0.0)
    var title: Color = Color(red: 0.24, green: 0.14, blue: 0.08)
    var titleText = "Peel"
    var titleFont: Font = .system(size: 230, weight: .heavy, design: .rounded)
    var titleTracking: CGFloat = 0

    static let vivid = IconStyle(
        name: "A 活力橙",
        page: [.white, Color(red: 0.99, green: 0.96, blue: 0.93)],
        line: Color(red: 0.92, green: 0.87, blue: 0.82),
        rind: Color(red: 0.95, green: 0.43, blue: 0.08),
        pith: Color(red: 1.0, green: 0.95, blue: 0.86),
        flesh: [Color(red: 1.0, green: 0.84, blue: 0.5), Color(red: 1.0, green: 0.55, blue: 0.15)],
        flap: [Color(red: 1.0, green: 0.74, blue: 0.34), Color(red: 0.93, green: 0.38, blue: 0.07)])

    static let modern = IconStyle(
        name: "B 现代渐变", cut: 500, curl: 0.8, segments: 4,
        page: [.white, Color(red: 0.95, green: 0.96, blue: 0.97)],
        line: Color(red: 0.88, green: 0.9, blue: 0.93), lineCount: 4,
        rind: Color(red: 1.0, green: 0.36, blue: 0.24),
        pith: .white,
        flesh: [Color(red: 1.0, green: 0.78, blue: 0.3), Color(red: 1.0, green: 0.42, blue: 0.25)],
        flap: [Color(red: 1.0, green: 0.62, blue: 0.3), Color(red: 0.98, green: 0.28, blue: 0.3)],
        pores: false, shadow: Color(red: 0.5, green: 0.1, blue: 0.1),
        title: Color(red: 0.12, green: 0.14, blue: 0.2))

    static let mono = IconStyle(
        name: "C 黑白极简", curl: 0.84, segments: 5,
        page: [.white, Color(white: 0.97)],
        line: Color(white: 0.86),
        rind: Color(white: 0.08),
        pith: .white,
        flesh: [Color(white: 0.22), Color(white: 0.08)],
        flap: [Color(white: 0.32), Color(white: 0.04)],
        pores: false, foldHighlight: Color(white: 0.92), shadow: .black, title: .black)

    static let dark = IconStyle(
        name: "D 深色",
        page: [Color(white: 0.17), Color(white: 0.11)],
        line: Color(white: 0.26),
        rind: Color(red: 0.98, green: 0.45, blue: 0.08),
        pith: Color(red: 1.0, green: 0.93, blue: 0.82),
        flesh: [Color(red: 1.0, green: 0.84, blue: 0.5), Color(red: 1.0, green: 0.55, blue: 0.15)],
        flap: [Color(red: 1.0, green: 0.74, blue: 0.34), Color(red: 0.93, green: 0.38, blue: 0.07)],
        shadow: .black, title: .white)

    static let all = [vivid, modern, mono, dark]

    /// A 版的几种字体 / 大小写组合
    static let titleOptions: [IconStyle] = {
        func v(_ name: String, _ text: String, _ font: Font, _ tracking: CGFloat) -> IconStyle {
            var s = IconStyle.vivid
            s.name = name
            s.titleText = text
            s.titleFont = font
            s.titleTracking = tracking
            return s
        }
        return [
            v("1 PEEL 圆体粗", "PEEL", .system(size: 210, weight: .heavy, design: .rounded), 4),
            v("2 Peel 圆体粗", "Peel", .system(size: 230, weight: .heavy, design: .rounded), 0),
            v("3 peel 圆体粗", "peel", .system(size: 250, weight: .heavy, design: .rounded), -2),
            v("4 PEEL 无衬线", "PEEL", .system(size: 210, weight: .black, design: .default), 2),
            v("5 Peel 无衬线", "Peel", .system(size: 230, weight: .bold, design: .default), -4),
            v("6 Peel 衬线", "Peel", .system(size: 240, weight: .bold, design: .serif), -2),
        ]
    }()
}

/// App 图标：整个圆角方形就是一张文档，右上角被剥开向左下卷起——
/// 卷起的页背是橘子皮；露出的是橘子切面，果皮正好贴着图标的圆角。剥开文档 = 露出新格式。
struct AppIconView: View {
    var style: IconStyle = .vivid

    static let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let tileRadius: CGFloat = 824 * 0.225

    // 几何（随 cut 变化）
    private var foldC: CGFloat { Self.tile.maxX - style.cut - Self.tile.minY }   // 折线 x - y = foldC
    private var foldA: CGPoint { CGPoint(x: Self.tile.maxX - style.cut, y: Self.tile.minY) }
    private var foldB: CGPoint { CGPoint(x: Self.tile.maxX, y: Self.tile.minY + style.cut) }
    private var foldMid: CGPoint { CGPoint(x: (foldA.x + foldB.x) / 2, y: (foldA.y + foldB.y) / 2) }

    /// 剥开的那块：先关于折线镜像，再沿垂直折线方向收缩（像卷起来的透视）
    private var flapTransform: CGAffineTransform {
        let c = foldC
        let reflect = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: c, ty: -c)
        let k = (1 - style.curl) / 2
        let squash = CGAffineTransform(a: 1 - k, b: k, c: k, d: 1 - k, tx: k * c, ty: -k * c)
        return reflect.concatenating(squash)
    }

    var body: some View {
        let T = Self.tile
        let tip = CGPoint(x: T.maxX, y: T.minY).applying(flapTransform)
        ZStack {
            // 页面
            TileShape()
                .fill(LinearGradient(colors: style.page, startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.22), radius: 20, y: 12)

            // 文字行：左上一小段 + 下方几行，避开卷起的页角
            ForEach(Array(textLines.enumerated()), id: \.offset) { _, line in
                Capsule()
                    .fill(style.line)
                    .frame(width: line.width, height: 30)
                    .position(x: T.minX + 100 + line.width / 2, y: line.y)
            }

            // 应用名
            Text(style.titleText)
                .font(style.titleFont)
                .tracking(style.titleTracking)
                .foregroundStyle(style.title)
                .frame(width: 680, alignment: .leading)
                .position(x: T.minX + 92 + 340, y: 760)

            // 露出的橘子
            revealedOrange

            // 卷起的页角在页面上的投影
            flapShape(style.shadow.opacity(0.35))
                .blur(radius: 18)
                .offset(x: -14, y: 18)
                .mask(TileShape())

            // 卷起的页角：背面是橘子皮，折痕处高光、尖端颜色更深，像卷起来的样子
            LinearGradient(stops: [
                .init(color: style.foldHighlight.opacity(0.9), location: 0),
                .init(color: style.flap[0], location: 0.12),
                .init(color: style.flap[1], location: 1),
            ], startPoint: unit(foldMid), endPoint: unit(tip))
            .frame(width: 1024, height: 1024)
            .mask(flapShape(.black))
            .overlay(
                Group {
                    if style.pores {
                        Pores(tile: T).fill(Color.white.opacity(0.24))
                            .transformEffect(flapTransform)
                            .mask(flapShape(.black))
                    }
                }
            )
        }
        .frame(width: 1024, height: 1024)
    }

    private func unit(_ p: CGPoint) -> UnitPoint { UnitPoint(x: p.x / 1024, y: p.y / 1024) }

    /// 剥开区域（图标 ∩ 折线右上方）经过镜像 + 收缩后的形状，用指定颜色填充
    private func flapShape(_ color: Color) -> some View {
        TileShape().fill(color)
            .frame(width: 1024, height: 1024)
            .mask(HalfPlane(foldC: foldC))
            .transformEffect(flapTransform)
    }

    private var textLines: [(y: CGFloat, width: CGFloat)] {
        // 下方是 PEEL 字样，只在左上角留两行
        let top: [(CGFloat, CGFloat)] = style.lineCount >= 6 ? [(230, 200), (300, 150), (370, 110)] : [(240, 190), (310, 130)]
        return top.map { (y: $0.0, width: $0.1) }
    }

    private var revealedOrange: some View {
        let rindW: CGFloat = 36, pithW: CGFloat = 16
        let n = style.segments
        let start = -135.0, total = 180.0
        return ZStack {
            TileShape().fill(style.rind)
            TileShape(inset: rindW).fill(style.pith)
            ZStack {
                ForEach(0..<n, id: \.self) { i in
                    Wedge(center: foldMid, startDeg: start + Double(i) * total / Double(n),
                          spanDeg: total / Double(n), inner: 30, outer: 900)
                        .fill(RadialGradient(colors: style.flesh, center: unit(foldMid),
                                             startRadius: 30, endRadius: style.cut * 0.8))
                }
            }
            .mask(TileShape(inset: rindW + pithW))
        }
        .frame(width: 1024, height: 1024)
        .mask(HalfPlane(foldC: foldC))
    }
}

private struct TileShape: Shape {
    var inset: CGFloat = 0
    func path(in _: CGRect) -> Path {
        let r = AppIconView.tile.insetBy(dx: inset, dy: inset)
        return RoundedRectangle(cornerRadius: AppIconView.tileRadius - inset, style: .continuous).path(in: r)
    }
}

/// 折线右上方的半平面（x - y ≥ foldC），用来从图标形状里裁出剥开的部分
private struct HalfPlane: Shape {
    let foldC: CGFloat
    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: foldC, y: 0))
        p.addLine(to: CGPoint(x: 1024, y: 0))
        p.addLine(to: CGPoint(x: 1024, y: 1024 - foldC))
        p.closeSubpath()
        return p
    }
}

/// 橘子皮上的小油胞（画在剥开区域里，随页角一起变换）
private struct Pores: Shape {
    let tile: CGRect
    func path(in _: CGRect) -> Path {
        let dots: [(CGFloat, CGFloat, CGFloat)] = [
            (-60, 40, 7), (-140, 60, 6), (-40, 130, 6), (-230, 45, 5), (-110, 160, 7),
            (-50, 230, 5), (-190, 130, 5), (-300, 70, 5), (-40, 320, 5), (-130, 250, 4),
            (-360, 40, 4), (-260, 150, 5),
        ]
        var p = Path()
        for (dx, dy, r) in dots {
            p.addEllipse(in: CGRect(x: tile.maxX + dx - r, y: tile.minY + dy - r, width: r * 2, height: r * 2))
        }
        return p
    }
}

private struct Wedge: Shape {
    let center: CGPoint
    let startDeg: Double
    let spanDeg: Double
    let inner: CGFloat
    let outer: CGFloat

    func path(in _: CGRect) -> Path {
        // 两侧平行内收，瓣与瓣之间等宽的缝
        let gap: CGFloat = 8
        func trim(_ r: CGFloat) -> Double { asin(min(1, Double(gap / r))) * 180 / .pi }
        var p = Path()
        p.addArc(center: center, radius: outer, startAngle: .degrees(startDeg + trim(outer)),
                 endAngle: .degrees(startDeg + spanDeg - trim(outer)), clockwise: false)
        p.addArc(center: center, radius: inner, startAngle: .degrees(startDeg + spanDeg - trim(inner)),
                 endAngle: .degrees(startDeg + trim(inner)), clockwise: true)
        p.closeSubpath()
        return p
    }
}

enum IconRenderer {
    /// 菜单栏图标：右上角剥开、页角向左下翻起的文档（单色模板图，随深色/浅色模式自动变色）
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            // 页面轮廓：圆角方形，右上角沿折线切掉
            let page = NSBezierPath()
            page.lineWidth = 1.5
            page.lineJoinStyle = .round
            page.move(to: NSPoint(x: 9, y: 2))
            page.line(to: NSPoint(x: 5, y: 2))
            page.curve(to: NSPoint(x: 2, y: 5), controlPoint1: NSPoint(x: 3.3, y: 2), controlPoint2: NSPoint(x: 2, y: 3.3))
            page.line(to: NSPoint(x: 2, y: 13))
            page.curve(to: NSPoint(x: 5, y: 16), controlPoint1: NSPoint(x: 2, y: 14.7), controlPoint2: NSPoint(x: 3.3, y: 16))
            page.line(to: NSPoint(x: 13, y: 16))
            page.curve(to: NSPoint(x: 16, y: 13), controlPoint1: NSPoint(x: 14.7, y: 16), controlPoint2: NSPoint(x: 16, y: 14.7))
            page.line(to: NSPoint(x: 16, y: 9))
            page.line(to: NSPoint(x: 9, y: 2))
            page.stroke()
            // 翻起的页角（实心，向左下翻）
            let flap = NSBezierPath()
            flap.move(to: NSPoint(x: 9, y: 2))
            flap.line(to: NSPoint(x: 16, y: 9))
            flap.curve(to: NSPoint(x: 9.6, y: 8.4), controlPoint1: NSPoint(x: 13, y: 9.8), controlPoint2: NSPoint(x: 10.4, y: 9.6))
            flap.curve(to: NSPoint(x: 9, y: 2), controlPoint1: NSPoint(x: 8.4, y: 7.6), controlPoint2: NSPoint(x: 8.2, y: 5))
            flap.close()
            flap.fill()
            // 一行文字
            let line = NSBezierPath()
            line.lineWidth = 1.4
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: 5, y: 12.5)); line.line(to: NSPoint(x: 12, y: 12.5))
            line.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// 渲染成 PNG（1024×1024）
    @MainActor static func render(to url: URL, size: CGFloat = 1024, style: IconStyle = .vivid) throws {
        let renderer = ImageRenderer(content: AppIconView(style: style).frame(width: 1024, height: 1024))
        renderer.scale = size / 1024
        renderer.isOpaque = false
        guard let img = renderer.cgImage else { throw PeelError("图标渲染失败", "Icon render failed") }
        try ImageEngine.write(img, type: .png, to: url)
    }
}
