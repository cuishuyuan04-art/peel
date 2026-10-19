import AppKit
import SwiftUI

enum HitZone: Equatable {
    case center
    case sector(Int)
}

final class WheelController: ObservableObject {
    static let shared = WheelController()

    enum Mode { case drag, click }

    /// 拖动模式：长按后继续拖着文件到扇区松手
    /// 点击模式：长按后原地松手，轮盘留着，点扇区执行
    @Published private(set) var mode: Mode = .drag
    @Published private(set) var stack: [WheelNode] = []
    @Published private(set) var hovered: HitZone?
    @Published private(set) var appeared = false
    @Published private(set) var files: [URL] = []
    /// 各压缩档位实际压出来的总大小（后台预估完成后填入）
    @Published private(set) var estimates: [CompressLevel: Int64] = [:]

    var current: WheelNode? { stack.last }
    var isVisible: Bool { panel?.isVisible ?? false }

    /// 悬停进度（0→1），走满时展开下一层 / 回到上一层
    @Published private(set) var dwellProgress: Double = 0
    /// 每次跳转后的冷却时间，防止连续乱跳
    private let jumpCooldown: TimeInterval = 0.25
    /// 进度条满格后停留多久再跳转
    private let fullHold: TimeInterval = 0.08
    private var lastJump: Date = .distantPast

    private var panel: WheelPanel?
    /// 跟着光标走的文件图标
    private let ghost = GhostIcon()

    // 截图轮盘：中心显示缩略图，缩略图可以拖到扇区或拖出轮盘
    @Published private(set) var snapshotImage: NSImage?
    private(set) var snapshotFile: URL?
    private var isDraggingSnapshot = false
    private var snapshotDroppedInside = false
    private var hideToken: UUID?
    private var dwellTimer: Timer?
    private var dwellBlocked: HitZone?
    private var releasePoll: Timer?
    private var dragEverEntered = false
    private var dropped = false
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?

    // MARK: - 显示 / 隐藏

    func show(at point: NSPoint, files: [URL], mode: Mode, root: WheelNode? = nil) {
        let panel = ensurePanel()
        hideToken = nil
        self.mode = mode
        if let root {
            // 截图等自定义轮盘：不按文件类型生成，也不预估压缩
            Estimator.shared.cancel()
            self.files = files
            estimates = [:]
            stack = [root]
        } else {
            snapshotImage = nil
            snapshotFile = nil
            load(files)
        }
        hovered = nil
        dwellBlocked = nil
        dragEverEntered = false
        dropped = false
        appeared = false

        let size = WheelMetrics.size
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX), vf.maxX - size)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - size)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { self.appeared = true }
        }

        Log.write("wheel shown mode=\(mode) files=\(files.map(\.lastPathComponent))")
        if mode == .drag {
            startTracking()
        } else {
            enterClickMode()
        }
    }

    func hide() {
        releasePoll?.invalidate(); releasePoll = nil
        cancelDwell()
        removeMonitors()
        ghost.hide()
        if snapshotFile != nil { SnapController.shared.wheelClosed() }
        Estimator.shared.cancel()
        guard let panel, panel.isVisible, hideToken == nil else { return }
        // 扇区先收回中心，再关掉窗口；期间如果又弹出了新轮盘就不再关
        let token = UUID()
        hideToken = token
        withAnimation(.easeIn(duration: 0.18)) { appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard self.hideToken == token else { return }
            self.hideToken = nil
            panel.orderOut(nil)
            self.stack = []
            self.files = []
            self.snapshotImage = nil
            self.snapshotFile = nil
        }
    }

    // MARK: - 文件来源

    /// 截图轮盘：在鼠标处弹出，点选操作；中心缩略图可以拖走
    func showSnapshot(at point: NSPoint, file: URL, image: NSImage, sizeLabel: String) {
        snapshotImage = image
        snapshotFile = file
        isDraggingSnapshot = false
        show(at: point, files: [file], mode: .click, root: Catalog.snapRoot(sizeLabel: sizeLabel))
    }

    func canDragSnapshot(at p: CGPoint) -> Bool {
        snapshotFile != nil && hit(p) == .center
    }

    func snapshotDragBegan() {
        isDraggingSnapshot = true
        snapshotDroppedInside = false
    }

    /// 缩略图拖动结束：拖到了轮盘外（访达文件夹、微信等）就算处理完，收起轮盘
    func snapshotDragEnded(operation: NSDragOperation) {
        isDraggingSnapshot = false
        cancelDwell()
        guard !snapshotDroppedInside, operation != [] else { return }
        SnapController.shared.draggedOut()
        hide()
    }

    /// 轮盘还是占位（没读到文件）时，用读到的文件填上
    func fillIfEmpty(_ urls: [URL]) {
        guard isVisible, files.isEmpty, stack.count <= 1, !urls.isEmpty else { return }
        load(urls)
    }

    /// 换一批文件：重建轮盘，并在后台实际跑一遍各压缩档位
    private func load(_ urls: [URL]) {
        files = urls
        if ghost.isVisible { ghost.show(files: urls, at: NSEvent.mouseLocation) }
        stack = [Catalog.root(for: urls)]
        estimates = [:]
        Estimator.shared.start(files: urls) { [weak self] level, bytes in
            self?.estimates[level] = bytes
        }
    }

    /// 压缩档位显示的说明：预估跑完后显示真实大小和比例，否则显示粗略估算
    func detailText(for node: WheelNode) -> String? {
        guard case .compress(let level)? = node.action, let bytes = estimates[level] else {
            return node.detail?.text
        }
        let original = Catalog.totalSize(files)
        guard original > 0, bytes < original else { return t("已最小", "Already small") }
        let pct = Int((1 - Double(bytes) / Double(original)) * 100)
        // 视频是截一段试压推算的，标成约数
        let approx = files.contains { FileKind.of($0) == .video } ? "≈ " : ""
        return "\(approx)\(Catalog.formatBytes(bytes)) · -\(pct)%"
    }

    // MARK: - 拖动事件（来自 WheelInputView）

    func dragEntered(urls: [URL]) {
        if !dragEverEntered { Log.write("finder drag entered: \(urls.map(\.lastPathComponent))") }
        dragEverEntered = true
        ghost.hide()
        // 拖动的文件是最准确的来源
        if !urls.isEmpty, Set(urls) != Set(files), stack.count <= 1 {
            load(urls)
        }
    }

    func dragExited() {
        setHovered(nil)
    }

    func drop(at p: CGPoint, urls: [URL]) -> Bool {
        Log.write("drop zone=\(String(describing: hit(p))) urls=\(urls.map(\.lastPathComponent))")
        let zone = hit(p)
        if isDraggingSnapshot {
            snapshotDroppedInside = true
            guard case .sector(let i)? = zone else { return false }
            activateSector(i)
            return true
        }
        dropped = true
        releasePoll?.invalidate(); releasePoll = nil
        if !urls.isEmpty { files = urls }
        switch zone {
        case .sector(let i)?:
            activateSector(i)
            return true
        case .center?:
            // 在下一层时拖回中心松手：回到上一层，轮盘留着可以点；在第一层：收起
            if stack.count > 1 {
                pop()
                enterClickMode()
            } else {
                hide()
            }
            return true
        case nil:
            hide()
            return false
        }
    }

    // MARK: - 鼠标事件（点击模式）

    func hover(at p: CGPoint) {
        setHovered(hit(p))
    }

    func click(at p: CGPoint) {
        switch hit(p) {
        case .sector(let i)?:
            activateSector(i)
        case .center?:
            if stack.count > 1 { pop() } else { hide() }
        case nil:
            hide()
        }
    }

    // MARK: - 导航

    private func activateSector(_ i: Int) {
        guard let node = current, node.children.indices.contains(i) else { return }
        let target = node.children[i]
        if case .snap(let action)? = target.action {
            // 先收起轮盘再执行（“选择位置…”会弹出保存窗口）
            let snap = SnapController.shared
            snap.willPerform()
            hide()
            DispatchQueue.main.async { snap.perform(action) }
            return
        }
        if target.isCategory {
            push(target)
            enterClickMode()
        } else if target.action != nil {
            guard !files.isEmpty else { return }
            let path = (stack.dropFirst().map(\.title) + [target.title])
            ActionRunner.run(target, path: path, files: files)
            hide()
        }
    }

    private func push(_ node: WheelNode) {
        cancelDwell()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { stack.append(node) }
        dwellBlocked = hovered   // 光标还停在原处，不要连续展开
        lastJump = Date()
    }

    private func pop() {
        guard stack.count > 1 else { return }
        cancelDwell()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { _ = stack.popLast() }
        dwellBlocked = hovered
        lastJump = Date()
    }

    private func setHovered(_ zone: HitZone?) {
        guard zone != hovered else { return }
        hovered = zone
        cancelDwell()
        if zone == dwellBlocked { return }
        dwellBlocked = nil
        guard mode == .drag || isDraggingSnapshot, let zone, let node = current else { return }

        switch zone {
        case .center where stack.count > 1:
            scheduleDwell { self.pop() }
        case .sector(let i) where node.children.indices.contains(i) && node.children[i].isCategory:
            let child = node.children[i]
            scheduleDwell { self.push(child) }
        default:
            break
        }
    }

    /// 先等跳转冷却结束，再逐帧推进进度条；画到满格后稍停一下才执行，
    /// 进度条和跳转用同一个计时器，保证“看到跑满”再跳
    private func scheduleDwell(_ action: @escaping () -> Void) {
        let wait = max(0, jumpCooldown - Date().timeIntervalSince(lastJump))
        let duration = Settings.dwellDuration
        let start = Date().addingTimeInterval(wait)
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let elapsed = Date().timeIntervalSince(start)
            guard elapsed > 0 else { return }
            if elapsed < duration {
                self.dwellProgress = elapsed / duration
                return
            }
            self.dwellProgress = 1
            timer.invalidate()
            // 满格停留一下再跳
            self.dwellTimer = Timer.scheduledTimer(withTimeInterval: self.fullHold, repeats: false) { _ in action() }
        }
        RunLoop.main.add(dwellTimer!, forMode: .common)
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        dwellProgress = 0
    }

    // MARK: - 命中测试（视图坐标，y 向下，原点左上）

    func hit(_ p: CGPoint) -> HitZone? {
        let c = WheelMetrics.size / 2
        let dx = p.x - c, dy = p.y - c
        let r = hypot(dx, dy)
        if r < WheelMetrics.innerR { return .center }
        guard r <= WheelMetrics.outerR + 14, let node = current, !node.children.isEmpty else { return nil }
        let n = node.children.count
        let step = 360.0 / Double(n)
        let deg = atan2(Double(dy), Double(dx)) * 180 / .pi
        var a = (deg + 90 + step / 2).truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return .sector(Int(a / step) % n)
    }

    // MARK: - 模式切换

    /// 拖动模式下轮询鼠标是否松开（拖动期间全局鼠标事件不一定送达）
    /// 长按弹出后，鼠标还按着：Peel 自己跟踪鼠标（像轮盘菜单），不依赖 Finder 开始拖动。
    /// 移到扇区上高亮、停留展开下一层；在扇区上松手执行，在别处松手收回。
    /// 如果 Finder 照常开始了拖动，文件拖进轮盘时由拖放事件处理，两种方式都能用。
    private func startTracking() {
        releasePoll?.invalidate()
        releasePoll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let point = self.viewPoint(NSEvent.mouseLocation)
            if NSEvent.pressedMouseButtons & 1 != 0 {
                if self.dragEverEntered {
                    // Finder 已经在拖文件（它自己会画拖动图标），由拖放事件更新悬停
                    self.ghost.hide()
                } else {
                    self.hover(at: point)
                    // 让人看到“拖着文件”：图标跟着光标走
                    if self.ghost.isVisible {
                        self.ghost.move(to: NSEvent.mouseLocation)
                    } else if !self.files.isEmpty {
                        self.ghost.show(files: self.files, at: NSEvent.mouseLocation)
                    }
                }
                return
            }
            self.releasePoll?.invalidate(); self.releasePoll = nil
            self.handleRelease(at: point)
        }
        RunLoop.main.add(releasePoll!, forMode: .common)
    }

    /// 扇区文字位置的屏幕坐标（文件图标飞向这里）
    private func screenPoint(ofSector i: Int, count: Int) -> NSPoint {
        guard let frame = panel?.frame else { return NSEvent.mouseLocation }
        let M = WheelMetrics.self
        let rad = (-90 + Double(i) * 360 / Double(count)) * .pi / 180
        let r = (M.innerR + M.outerR) / 2
        return NSPoint(x: frame.minX + M.size / 2 + r * CGFloat(cos(rad)),
                       y: frame.maxY - (M.size / 2 + r * CGFloat(sin(rad))))
    }

    /// 屏幕坐标 → 轮盘视图坐标（原点左上）
    private func viewPoint(_ screen: NSPoint) -> CGPoint {
        guard let frame = panel?.frame else { return .zero }
        return CGPoint(x: screen.x - frame.minX, y: frame.maxY - screen.y)
    }

    private func handleRelease(at point: CGPoint) {
        if dropped { return }
        if dragEverEntered {
            // Finder 的拖放正在进行：稍等放下事件；没放到轮盘上（比如拖去别处移动文件）就收回
            Log.write("release during finder drag")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if !self.dropped { self.hide() } }
            return
        }
        let zone = hit(point)
        Log.write("release zone=\(String(describing: zone))")
        // 松手在操作扇区上：文件图标飞进扇区；其他情况直接收起
        if case .sector(let i)? = zone, let node = current, node.children.indices.contains(i),
           !node.children[i].isCategory {
            ghost.fly(to: screenPoint(ofSector: i, count: node.children.count))
        } else {
            ghost.hide()
        }
        switch zone {
        case .sector(let i)?:
            releaseOnSector(i)
        case .center? where stack.count > 1:
            pop()
            enterClickMode()
        default:
            hide()
        }
    }

    /// 在扇区上松手：分类就展开（轮盘留着可以点），操作就执行。
    /// 松手后 Finder 已经空闲，这时读取选中的文件是安全的（多选也能拿全）
    private func releaseOnSector(_ i: Int) {
        guard let node = current, node.children.indices.contains(i) else { return hide() }
        let target = node.children[i]
        if target.isCategory {
            push(target)
            enterClickMode()
            return
        }
        guard target.action != nil else { return hide() }
        let path = stack.dropFirst().map(\.title) + [target.title]
        let fallback = files
        hide()
        FinderBridge.fetchSelection(timeout: 2) { result in
            var urls = fallback
            if case .success(let selected) = result, !selected.isEmpty { urls = selected }
            Log.write("run \(target.title.en) on \(urls.map(\.lastPathComponent)) (selection: \(result))")
            guard !urls.isEmpty else {
                HUD.shared.show(t("没有读到选中的文件，请再试一次", "Couldn't read the selected file — try again"),
                                symbol: "exclamationmark.triangle.fill", duration: 3)
                return
            }
            ActionRunner.run(target, path: path, files: urls)
        }
    }

    private func enterClickMode() {
        mode = .click
        cancelDwell()
        panel?.makeKey()
        guard outsideClickMonitor == nil else { return }
        // 点轮盘以外的地方关闭
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        // Esc 关闭
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.hide(); return nil }
            return e
        }
    }

    private func removeMonitors() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }

    /// 仅供 DebugRender 使用：截图轮盘
    func debugSnapshot(file: URL, open: Int?, hover: Int?) {
        snapshotFile = file
        snapshotImage = NSImage(contentsOf: file)
        files = [file]
        stack = [Catalog.snapRoot(sizeLabel: "1280×720")]
        if let open, let node = current, node.children.indices.contains(open) { stack.append(node.children[open]) }
        hovered = hover.map { $0 < 0 ? .center : .sector($0) }
        appeared = true
    }

    /// 仅供演示动画使用：直接设定悬停的扇区和外圈进度
    func debugDemo(files: [URL], hover: Int?, dwell: Double) {
        if self.files != files {
            self.files = files
            stack = [Catalog.root(for: files)]
        }
        hovered = hover.map { .sector($0) }
        dwellProgress = dwell
        appeared = true
    }

    /// 仅供 DebugRender 使用
    func debugSetup(files: [URL], open: Int?, hover: Int?) {
        self.files = files
        stack = [Catalog.root(for: files)]
        if let open, let node = current, node.children.indices.contains(open) {
            stack.append(node.children[open])
        }
        hovered = hover.map { $0 < 0 ? .center : .sector($0) }
        dwellProgress = hover == nil ? 0 : 0.6
        appeared = true
    }

    private func ensurePanel() -> WheelPanel {
        if let panel { return panel }
        let size = WheelMetrics.size
        let p = WheelPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // 浮动层级：在 Finder 窗口之上，并且能接收拖放（菜单层级的窗口可能不接收）
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        // 底层画轮盘，最上层盖一个透明的接收层（拖放、鼠标都由它接）
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let container = NSView(frame: bounds)
        let host = NSHostingView(rootView: WheelView(controller: self))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        let input = WheelInputView(frame: bounds)
        input.autoresizingMask = [.width, .height]
        input.controller = self
        container.addSubview(host)
        container.addSubview(input)
        p.contentView = container
        panel = p
        return p
    }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
