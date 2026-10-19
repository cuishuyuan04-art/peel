import AppKit

/// 钉在屏幕上的截图：浮在最上层。拖动移动；滚轮 / 触控板双指滑动或捏合缩放；双击关闭；右键有更多操作
final class PinWindow: NSPanel {
    private static var pins: [PinWindow] = []
    fileprivate let image: NSImage
    /// 原始显示大小（缩放以它为基准）
    private let baseSize: NSSize
    private var scale: CGFloat = 1

    static func show(_ image: NSImage) {
        let pin = PinWindow(image: image)
        pins.append(pin)
        pin.orderFrontRegardless()
    }

    private init(image: NSImage) {
        self.image = image
        // 截图是视网膜像素：按屏幕缩放显示成原本的大小，太大时先缩小到屏幕的六成以内
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let backing = screen?.backingScaleFactor ?? 2
        let rep = image.representations.first
        var size = NSSize(width: CGFloat(rep?.pixelsWide ?? Int(image.size.width)) / backing,
                          height: CGFloat(rep?.pixelsHigh ?? Int(image.size.height)) / backing)
        if let vf = screen?.visibleFrame {
            let fit = min(1, vf.width * 0.6 / size.width, vf.height * 0.6 / size.height)
            size = NSSize(width: size.width * fit, height: size.height * fit)
        }
        baseSize = size
        let mouse = NSEvent.mouseLocation
        let frame = NSRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        contentView = PinView(pin: self, frame: NSRect(origin: .zero, size: size))
    }

    override var canBecomeKey: Bool { true }

    /// 以窗口中心为基准缩放到指定比例
    fileprivate func zoom(to newScale: CGFloat) {
        let s = min(5, max(0.15, newScale))
        guard abs(s - scale) > 0.001 else { return }
        scale = s
        let f = frame
        let w = baseSize.width * s, h = baseSize.height * s
        setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
    }

    fileprivate func zoom(by factor: CGFloat) { zoom(to: scale * factor) }
    fileprivate func actualSize() { zoom(to: 1) }

    fileprivate func closePin() {
        orderOut(nil)
        PinWindow.pins.removeAll { $0 === self }
    }

    fileprivate func copyImage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        HUD.shared.show(t("已复制到剪贴板", "Copied to clipboard"), symbol: "doc.on.clipboard.fill")
    }
}

/// 显示截图并处理所有鼠标操作（系统的图片控件会吞掉鼠标事件，导致窗口拖不动、缩放不了）
private final class PinView: NSView {
    weak var pin: PinWindow?

    init(pin: PinWindow, frame: NSRect) {
        self.pin = pin
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = pin.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer?.contentsGravity = .resize
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            pin?.closePin()
        } else {
            window?.performDrag(with: event)   // 按住拖动窗口
        }
    }

    /// 滚轮或触控板双指上下滑动：缩放
    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        let factor: CGFloat = event.hasPreciseScrollingDeltas
            ? 1 + max(-0.2, min(0.2, dy * 0.01))      // 触控板：跟手的细腻缩放
            : (dy > 0 ? 1.1 : 0.9)                     // 鼠标滚轮：一格一档
        pin?.zoom(by: factor)
    }

    /// 触控板双指捏合：缩放
    override func magnify(with event: NSEvent) {
        pin?.zoom(by: 1 + event.magnification)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(BlockMenuItem(title: t("复制", "Copy")) { [weak self] in self?.pin?.copyImage() })
        menu.addItem(BlockMenuItem(title: t("恢复原始大小", "Actual Size")) { [weak self] in self?.pin?.actualSize() })
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem(title: t("关闭", "Close")) { [weak self] in self?.pin?.closePin() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
