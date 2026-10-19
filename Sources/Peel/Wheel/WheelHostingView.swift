import AppKit
import SwiftUI

/// 盖在轮盘最上层的透明接收层：负责接收 Finder 拖来的文件和鼠标事件。
/// 单独放在最上面，这样下面的毛玻璃、扇区等画面元素不会挡住拖放
/// （系统判断“文件拖到了谁身上”时，先找到的是这一层）。
final class WheelInputView: NSView, NSDraggingSource {
    weak var controller: WheelController?
    private var tracking: NSTrackingArea?
    /// 在截图缩略图上按下的位置（移动一点就开始拖缩略图）
    private var snapPress: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// y 向下、原点左上（与 SwiftUI 一致）
    override var isFlipped: Bool { true }

    private func local(_ windowPoint: NSPoint) -> CGPoint {
        convert(windowPoint, from: nil)
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
    }

    // MARK: - 拖放（返回 .copy：Finder 不会移动或删除原文件）

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragEntered(urls: fileURLs(sender))
        controller?.hover(at: local(sender.draggingLocation))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.hover(at: local(sender.draggingLocation))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.dragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.drop(at: local(sender.draggingLocation), urls: fileURLs(sender)) ?? false
    }

    // MARK: - 鼠标（点击模式）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard controller?.mode == .click else { return }
        controller?.hover(at: local(event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        guard controller?.mode == .click else { return }
        controller?.dragExited()
    }

    override func mouseDown(with event: NSEvent) {
        let p = local(event.locationInWindow)
        if controller?.canDragSnapshot(at: p) == true {
            snapPress = p          // 可能是拖缩略图，也可能只是点一下，等移动或松开再判断
            return
        }
        controller?.click(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = snapPress, let c = controller, let file = c.snapshotFile else { return }
        let p = local(event.locationInWindow)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        snapPress = nil

        // 拖的是截图文件本身：放进访达文件夹就存到那里，放进微信 / 邮件就直接发出去
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let thumb = c.snapshotImage ?? NSImage()
        let w: CGFloat = 110
        let h = thumb.size.width > 0 ? w * thumb.size.height / thumb.size.width : w
        item.setDraggingFrame(NSRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), contents: thumb)
        c.snapshotDragBegan()
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard snapPress != nil else { return }
        snapPress = nil
        controller?.click(at: local(event.locationInWindow))
    }

    // MARK: - 拖出截图缩略图（NSDraggingSource）

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.snapshotDragEnded(operation: operation)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
