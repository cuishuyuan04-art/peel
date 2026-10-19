import AppKit
import SwiftUI

/// 提示气泡：从菜单栏的 Peel 图标下方弹出，尖角指向图标
final class HUD {
    static let shared = HUD()

    /// 菜单栏图标在屏幕上的位置（由 AppDelegate 提供）；拿不到时气泡放在屏幕上方居中
    var anchor: (() -> NSRect?)?

    private let model = HUDModel()
    private var panel: NSPanel?
    private var host: NSHostingView<HUDView>?
    private var hideWork: DispatchWorkItem?

    /// 气泡尖角高度、阴影留白（与 HUDView 一致）
    static let arrowHeight: CGFloat = 9
    static let margin: CGFloat = 18
    /// 文字最宽多少，超过就换行
    static let maxTextWidth: CGFloat = 340

    func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 2.5) {
        present(text, symbol: symbol, duration: duration)
    }

    /// 带转圈的提示，一直显示到下一次 show；重复调用只更新文字（用于百分比进度）
    func progress(_ text: String) {
        present(text, symbol: nil, duration: nil)
    }

    private func present(_ text: String, symbol: String?, duration: TimeInterval?) {
        hideWork?.cancel()
        model.text = text
        model.symbol = symbol

        let p = panel ?? makePanel()
        let wasShown = p.isVisible && model.shown
        layout(p)
        if !wasShown {
            model.shown = false
            p.alphaValue = 1
            p.orderFrontRegardless()
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { self.model.shown = true }
            }
        }

        guard let duration else { return }
        let work = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p else { return }
            withAnimation(.easeIn(duration: 0.18)) { self.model.shown = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if !self.model.shown { p.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 按内容调整大小；有菜单栏图标时尖角对准图标，否则放在屏幕上方居中
    private func layout(_ p: NSPanel) {
        // 单独量尺寸（显示用的宿主视图不自动改窗口大小）
        // 先量文字单行的宽度，决定单行还是换行，再量整个气泡
        let textWidth = NSHostingController(rootView: HUDView.measureLabel(model.text))
            .sizeThatFits(in: NSSize(width: 10000, height: 200)).width
        model.singleLine = textWidth <= Self.maxTextWidth
        let fitted = NSHostingController(rootView: HUDView(model: model)).sizeThatFits(in: NSSize(width: 2000, height: 800))
        let size = NSSize(width: ceil(fitted.width) + 2, height: ceil(fitted.height))
        // 图标还没摆好位置（刚启动时坐标为 0）就当作没有
        let icon = anchor?().flatMap { $0.width > 0 && $0.minY > 0 ? $0 : nil }
        let screen = icon.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }

        var origin: NSPoint
        if let icon {
            // 尖角尖端贴着图标下沿；气泡尽量以图标为中心，但不超出屏幕
            origin = NSPoint(x: icon.midX - size.width / 2, y: icon.minY - size.height + Self.margin - 2)
            origin.x = min(max(origin.x, vf.minX + 4 - Self.margin), vf.maxX - size.width - 4 + Self.margin)
            model.arrowX = icon.midX - origin.x
        } else {
            origin = NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height + Self.margin - 4)
            model.arrowX = nil
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        // 宿主视图不自动跟随，手动对齐窗口大小
        host?.frame = NSRect(origin: .zero, size: size)
        host?.layoutSubtreeIfNeeded()
    }

    private func makePanel() -> NSPanel {
        let h = NSHostingView(rootView: HUDView(model: model))
        // 窗口大小由 layout() 决定，不让宿主视图自己改
        h.sizingOptions = []
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = h
        panel = p
        host = h
        return p
    }
}

final class HUDModel: ObservableObject {
    @Published var text = ""
    @Published var symbol: String?
    /// 尖角在气泡视图里的横坐标；nil 表示不画尖角
    @Published var arrowX: CGFloat?
    @Published var shown = false
    @Published var singleLine = true
}

/// 带尖角的气泡外形（尖角在顶部）
struct BubbleShape: Shape {
    var arrowX: CGFloat?
    var arrowHeight: CGFloat = HUD.arrowHeight
    var radius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + (arrowX == nil ? 0 : arrowHeight)
        let body = CGRect(x: rect.minX, y: top, width: rect.width, height: rect.maxY - top)
        guard let x = arrowX else { return Path(roundedRect: body, cornerRadius: radius, style: .continuous) }

        // 一条完整的轮廓：顶边中间凸出一个圆润的尖角
        let r = min(radius, body.height / 2)
        let half: CGFloat = 11
        let ax = min(max(x, body.minX + r + half), body.maxX - r - half)
        var p = Path()
        p.move(to: CGPoint(x: body.minX + r, y: top))
        p.addLine(to: CGPoint(x: ax - half, y: top))
        p.addCurve(to: CGPoint(x: ax, y: rect.minY),
                   control1: CGPoint(x: ax - half * 0.45, y: top), control2: CGPoint(x: ax - 2.5, y: rect.minY))
        p.addCurve(to: CGPoint(x: ax + half, y: top),
                   control1: CGPoint(x: ax + 2.5, y: rect.minY), control2: CGPoint(x: ax + half * 0.45, y: top))
        p.addLine(to: CGPoint(x: body.maxX - r, y: top))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: top), tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: top), radius: r)
        p.addArc(tangent1End: CGPoint(x: body.minX, y: top), tangent2End: CGPoint(x: body.maxX, y: top), radius: r)
        p.closeSubpath()
        return p
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    @State private var bubbleWidth: CGFloat = 300

    var body: some View {
        let localArrow = model.arrowX.map { $0 - HUD.margin }
        HStack(spacing: 10) {
            if let symbol = model.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PeelColors.hot)
            } else {
                ProgressView().controlSize(.small)
            }
            // 一行放得下就紧贴文字；放不下才在最大宽度内换行（由 HUD.layout 量好后决定）
            if model.singleLine {
                label.fixedSize()
            } else {
                label.fixedSize(horizontal: false, vertical: true)
                    .frame(width: HUD.maxTextWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.top, localArrow == nil ? 0 : HUD.arrowHeight)
        .background {
            GeometryReader { geo in
                let shape = BubbleShape(arrowX: localArrow)
                shape.fill(.regularMaterial)
                    .overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 0.5))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { bubbleWidth = geo.size.width }
                    .onChange(of: geo.size.width) { bubbleWidth = $0 }
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        // 从尖角处“长”出来
        .scaleEffect(model.shown ? 1 : 0.6, anchor: anchorPoint(localArrow))
        .opacity(model.shown ? 1 : 0)
        .padding(HUD.margin)
    }

    private var label: some View { Self.styled(model.text) }

    private static func styled(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .monospacedDigit()
    }

    /// 量单行宽度用
    static func measureLabel(_ text: String) -> some View {
        styled(text).fixedSize()
    }

    private func anchorPoint(_ arrow: CGFloat?) -> UnitPoint {
        guard let arrow, bubbleWidth > 0 else { return .top }
        return UnitPoint(x: min(max(arrow / bubbleWidth, 0), 1), y: 0)
    }
}
