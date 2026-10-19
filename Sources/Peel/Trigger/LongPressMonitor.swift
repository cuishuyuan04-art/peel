import AppKit

/// 全局监听左键：按住不动达到设定时长就触发；期间只要移动或松开就取消，
/// 所以普通的拖动/点击完全不受影响（只监听，不拦截任何事件）。
final class LongPressMonitor {
    var onTrigger: ((NSPoint) -> Void)?

    /// 移动超过这个距离（点）就视为在拖动，取消长按
    private let moveTolerance: CGFloat = 6

    private var downMonitor: Any?
    private var poll: Timer?
    private var downPoint: NSPoint = .zero
    private var downTime: Date = .distantPast

    func start() {
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.mouseDown(event)
        }
    }

    private func mouseDown(_ event: NSEvent) {
        cancel()
        guard Settings.longPressEnabled, !WheelController.shared.isVisible else { return }
        // Ctrl+左键 = 右键菜单，不处理
        if event.modifierFlags.contains(.control) { return }

        downPoint = NSEvent.mouseLocation
        downTime = Date()
        poll = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let released = NSEvent.pressedMouseButtons & 1 == 0
        let p = NSEvent.mouseLocation
        let moved = hypot(p.x - downPoint.x, p.y - downPoint.y) > moveTolerance
        if released || moved {
            cancel()
            return
        }
        if Date().timeIntervalSince(downTime) >= Settings.holdDuration {
            cancel()
            onTrigger?(downPoint)
        }
    }

    private func cancel() {
        poll?.invalidate()
        poll = nil
    }
}
