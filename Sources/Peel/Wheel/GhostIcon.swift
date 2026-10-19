import AppKit

/// 长按弹出轮盘后，跟着光标走的文件图标（Finder 没有开始拖动时，让人看得到“拖着文件”）。
/// 在扇区上松手时，图标飞进扇区并淡出。
final class GhostIcon {
    private var panel: NSPanel?
    private let size: CGFloat = 56
    /// 图标相对光标的偏移：放在光标右下一点，不挡住正在指向的扇区
    private var offset: CGPoint { CGPoint(x: 8, y: -size + 12) }

    var isVisible: Bool { panel?.isVisible ?? false }
    private var flying = false

    func show(files: [URL], at point: NSPoint) {
        guard !files.isEmpty else { return }
        flying = false
        let p = panel ?? makePanel()
        (p.contentView as? NSImageView)?.image = Self.image(for: files, size: size)
        p.setFrame(frame(at: point), display: true)
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 0.92 }
        }
    }

    func move(to point: NSPoint) {
        guard let p = panel, p.isVisible else { return }
        p.setFrameOrigin(frame(at: point).origin)
    }

    func hide() {
        guard let p = panel, p.isVisible, !flying else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 },
                                             completionHandler: { p.orderOut(nil) })
    }

    /// 松手在扇区上：飞到扇区位置、缩小并淡出
    func fly(to target: NSPoint) {
        guard let p = panel, p.isVisible else { return }
        flying = true
        let s: CGFloat = 20
        let end = NSRect(x: target.x - s / 2, y: target.y - s / 2, width: s, height: s)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(end, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            self.flying = false
        })
    }

    private func frame(at point: NSPoint) -> NSRect {
        NSRect(x: point.x + offset.x, y: point.y + offset.y, width: size, height: size)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu            // 在轮盘之上
        p.ignoresMouseEvents = true      // 不挡鼠标、不挡拖放
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSImageView(frame: p.contentLayoutRect)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        p.contentView = view
        panel = p
        return p
    }

    /// 单个文件用它的图标；多个文件叠两层并标上数量
    static func image(for files: [URL], size: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: files[0].path)
        icon.size = NSSize(width: size, height: size)
        guard files.count > 1 else { return icon }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width * 0.82
            icon.draw(in: NSRect(x: rect.width - s, y: rect.height - s, width: s, height: s),
                      from: .zero, operation: .sourceOver, fraction: 0.55)
            icon.draw(in: NSRect(x: 0, y: rect.height - s - 6, width: s, height: s))
            // 数量角标
            let text = "\(files.count)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                                        .foregroundColor: NSColor.white]
            let ts = text.size(withAttributes: attrs)
            let d = max(18, ts.width + 8)
            let badge = NSRect(x: rect.width - d, y: 0, width: d, height: 18)
            NSColor(red: 0.97, green: 0.4, blue: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9).fill()
            text.draw(at: NSPoint(x: badge.midX - ts.width / 2, y: badge.midY - ts.height / 2), withAttributes: attrs)
            return true
        }
    }
}
