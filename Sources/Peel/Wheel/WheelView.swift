import AppKit
import SwiftUI

enum WheelMetrics {
    static let size: CGFloat = 440
    static let outerR: CGFloat = 168
    static let innerR: CGFloat = 70
    /// 外圈进度条半径
    static let ringR: CGFloat = 180
    /// 扇区之间的缝宽（点）
    static let gap: CGFloat = 7
    /// 用圆头描边做出圆角，几何上先往里收这么多
    static let cornerInset: CGFloat = 6
}

enum PeelColors {
    static let cream = LinearGradient(
        colors: [Color(red: 1.0, green: 0.965, blue: 0.93), Color(red: 1.0, green: 0.87, blue: 0.76)],
        startPoint: .top, endPoint: .bottom)
    static let hot = LinearGradient(
        colors: [Color(red: 1.0, green: 0.60, blue: 0.25), Color(red: 0.97, green: 0.33, blue: 0.11)],
        startPoint: .top, endPoint: .bottom)
    /// 进度条用纯色：渐变首尾不同色，起点圆头会露出终点颜色
    static let ring = Color(red: 1.0, green: 0.52, blue: 0.16)
    /// 扇区底色：整盘统一的左上受光（每瓣用同一个渐变坐标，光照方向一致）
    static let creamLit = LinearGradient(
        colors: [Color(red: 1.0, green: 0.99, blue: 0.97), Color(red: 1.0, green: 0.84, blue: 0.70)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let ink = Color(red: 0.36, green: 0.22, blue: 0.15)
}

/// 系统毛玻璃，模糊窗口后面的内容
struct BackdropBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct WheelView: View {
    @ObservedObject var controller: WheelController
    /// DebugRender 离屏渲染时设为 true
    static var offscreen = false

    var body: some View {
        let M = WheelMetrics.self
        let appeared = controller.appeared
        ZStack {
            GlassBase(offscreen: Self.offscreen)
                .scaleEffect(appeared ? 1 : 0.72)
                .opacity(appeared ? 1 : 0)
                .animation(appeared ? .spring(response: 0.38, dampingFraction: 0.78) : .easeIn(duration: 0.16),
                           value: appeared)

            // 外圈进度条：悬停时从顶部顺时针跑满一圈才跳转
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 6)
                .frame(width: M.ringR * 2, height: M.ringR * 2)
                .opacity(appeared ? 1 : 0)
            Circle()
                .trim(from: 0, to: controller.dwellProgress)
                .stroke(PeelColors.ring, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: M.ringR * 2, height: M.ringR * 2)
                .shadow(color: Color.orange.opacity(0.7), radius: 4)
                .opacity(controller.dwellProgress > 0 ? 1 : 0)

            if let node = controller.current {
                ZStack {
                    ForEach(Array(node.children.enumerated()), id: \.element.id) { i, child in
                        SectorView(node: child, index: i, count: node.children.count,
                                   hovered: controller.hovered == .sector(i),
                                   detail: controller.detailText(for: child))
                            // 弹出：一瓣一瓣从中心旋转着展开；收起：一起快速缩回
                            .scaleEffect(appeared ? 1 : 0.3)
                            .rotationEffect(.degrees(appeared ? 0 : -32))
                            .opacity(appeared ? 1 : 0)
                            .animation(appeared
                                       ? .spring(response: 0.42, dampingFraction: 0.7).delay(0.03 + Double(i) * 0.035)
                                       : .easeIn(duration: 0.14),
                                       value: appeared)
                    }
                    CenterView(controller: controller, node: node)
                        .scaleEffect(appeared ? 1 : 0.4)
                        .opacity(appeared ? 1 : 0)
                        .animation(appeared ? .spring(response: 0.36, dampingFraction: 0.65) : .easeIn(duration: 0.14),
                                   value: appeared)
                }
                .id(node.id)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.75).combined(with: .opacity),
                    removal: .scale(scale: 1.12).combined(with: .opacity)))
            }
        }
        .frame(width: M.size, height: M.size)
    }
}

/// 玻璃底座：模糊背后的内容，左上角柔和高光、边缘一圈亮边、内侧淡淡的阴影
struct GlassBase: View {
    let offscreen: Bool

    var body: some View {
        let d = (WheelMetrics.outerR + 18) * 2
        ZStack {
            // 只投在外沿的柔和阴影
            Circle()
                .stroke(Color.black.opacity(0.22), lineWidth: 18)
                .blur(radius: 14)
                .offset(y: 7)
            Group {
                if offscreen {
                    Circle().fill(.ultraThinMaterial)   // 离屏渲染时 NSVisualEffectView 画不出来
                } else {
                    BackdropBlur().clipShape(Circle())
                }
            }
            Circle().fill(RadialGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.06)],
                                         center: UnitPoint(x: 0.32, y: 0.22), startRadius: 0, endRadius: d * 0.75))
            // 内阴影
            Circle()
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 8)
                .blur(radius: 6)
                .clipShape(Circle())
            // 亮边：上亮下暗
            Circle()
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.18),
                                                      Color.white.opacity(0.45)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1.3)
        }
        .frame(width: d, height: d)
    }
}

/// 完整圆环（只有一个选项时用，避免扇形首尾相接处出现一条线）
struct RingShape: Shape {
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        return p
    }
}

/// 环形扇区。两侧边与扇区中线平行地内收 `sideInset`，这样扇区之间的缝是等宽的
struct SectorShape: Shape {
    var midDeg: Double
    var halfSpanDeg: Double
    var inner: CGFloat
    var outer: CGFloat
    var sideInset: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        func trim(_ r: CGFloat) -> Double { asin(min(1, Double(sideInset / r))) * 180 / .pi }
        let fullRing = halfSpanDeg >= 180
        let oT = fullRing ? 0 : trim(outer)
        let iT = fullRing ? 0 : trim(inner)
        var p = Path()
        p.addArc(center: c, radius: outer,
                 startAngle: .degrees(midDeg - halfSpanDeg + oT), endAngle: .degrees(midDeg + halfSpanDeg - oT),
                 clockwise: false)
        p.addArc(center: c, radius: inner,
                 startAngle: .degrees(midDeg + halfSpanDeg - iT), endAngle: .degrees(midDeg - halfSpanDeg + iT),
                 clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct SectorView: View {
    let node: WheelNode
    let index: Int
    let count: Int
    let hovered: Bool
    /// 扇区标题下的小字（格式说明、压缩后大小等）
    var detail: String?

    var body: some View {
        let M = WheelMetrics.self
        let step = 360.0 / Double(count)
        let mid = -90 + Double(index) * step
        let inset = M.cornerInset
        let midR = (M.innerR + M.outerR) / 2
        let shape: AnyShape = count == 1
            ? AnyShape(RingShape(inner: M.innerR + inset, outer: M.outerR - inset))
            : AnyShape(SectorShape(midDeg: mid, halfSpanDeg: step / 2,
                                   inner: M.innerR + inset, outer: M.outerR - inset,
                                   sideInset: M.gap / 2 + inset))
        let fill = hovered ? PeelColors.hot : PeelColors.creamLit
        let rad = mid * .pi / 180
        let labelPos = CGPoint(x: M.size / 2 + midR * CGFloat(cos(rad)),
                               y: M.size / 2 + midR * CGFloat(sin(rad)))
        // 悬停时沿中线往外弹出
        let pop: CGFloat = hovered && count > 1 ? 7 : 0
        let compact = count >= 6
        let even = FillStyle(eoFill: true)

        ZStack {
            ZStack {
                shape.fill(fill, style: even)
                    .overlay(shape.stroke(fill, style: StrokeStyle(lineWidth: inset * 2, lineJoin: .round)))
                // 立体感：圆角边带上叠一层上亮下暗的高光，像倒角
                shape.stroke(LinearGradient(colors: [Color.white.opacity(hovered ? 0.18 : 0.42),
                                                     Color.white.opacity(0)],
                                            startPoint: .top, endPoint: .center),
                             style: StrokeStyle(lineWidth: inset * 2, lineJoin: .round))
            }
            .shadow(color: hovered ? Color.orange.opacity(0.55) : Color(red: 0.5, green: 0.28, blue: 0.12).opacity(0.18),
                    radius: hovered ? 14 : 5, y: hovered ? 0 : 3)

            VStack(spacing: 3) {
                Image(systemName: node.symbol)
                    .font(.system(size: compact ? 15 : 18, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(node.title.text)
                    .font(.system(size: compact ? 10.5 : 12, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail {
                    Text(detail)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .opacity(0.75)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(hovered ? Color.white : PeelColors.ink)
            .shadow(color: hovered ? Color(red: 0.6, green: 0.2, blue: 0).opacity(0.35) : .clear, radius: 2, y: 1)
            .frame(width: compact ? 64 : 84)
            .position(labelPos)
        }
        .frame(width: M.size, height: M.size)
        .offset(x: pop * CGFloat(cos(rad)), y: pop * CGFloat(sin(rad)))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
    }
}

struct CenterView: View {
    @ObservedObject var controller: WheelController
    let node: WheelNode

    var body: some View {
        let r = WheelMetrics.innerR - 8
        let isRoot = controller.stack.count <= 1
        let hovered = controller.hovered == .center && !isRoot

        ZStack {
            Circle()
                .fill(hovered ? AnyShapeStyle(PeelColors.hot)
                              : AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.97), Color(red: 1, green: 0.95, blue: 0.9).opacity(0.92)],
                                                             startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Color.white, Color.white.opacity(0.3)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
                .shadow(color: hovered ? Color.orange.opacity(0.5) : Color.black.opacity(0.14),
                        radius: hovered ? 12 : 7, y: hovered ? 0 : 3)

            VStack(spacing: 3) {
                if isRoot {
                    rootIcon
                    Text(node.title.text)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                } else {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 14, weight: .bold))
                    Text(node.title.text)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(controller.mode == .click ? t("点这里返回", "Click to go back") : t("拖回中心返回", "Back to center"))
                        .font(.system(size: 8.5, weight: .medium))
                        .opacity(0.65)
                }
            }
            .foregroundStyle(hovered ? Color.white : PeelColors.ink)
            .frame(width: r * 2 - 16)
        }
        .frame(width: r * 2, height: r * 2)
        .scaleEffect(hovered ? 1.06 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
    }

    @ViewBuilder private var rootIcon: some View {
        if let snap = controller.snapshotImage {
            // 截图缩略图：可以按住拖走
            Image(nsImage: snap)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 84, maxHeight: 52)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        } else if controller.files.count == 1 {
            Image(nsImage: NSWorkspace.shared.icon(forFile: controller.files[0].path))
                .resizable()
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        } else if controller.files.count > 1 {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.hierarchical)
        } else {
            Image(systemName: node.symbol)
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
        }
    }
}
