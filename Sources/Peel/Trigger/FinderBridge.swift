import AppKit
import ApplicationServices

enum FinderError: Error {
    case notAuthorized   // 没有“自动化 → Finder”权限
    case timeout         // Finder 正忙（比如鼠标还按着），没及时回应
    case failed(String)
}

enum FinderBridge {
    static let finderID = "com.apple.finder"

    private static let selectionScript = """
    tell application "Finder"
        set out to ""
        repeat with i in (get selection)
            set out to out & POSIX path of (i as alias) & linefeed
        end repeat
        return out
    end tell
    """

    /// 读取 Finder 当前选中的文件。走 osascript 子进程，方便加超时：
    /// 鼠标按住时 Finder 可能处在拖动跟踪循环里，暂时不处理 Apple Event。
    static func fetchSelection(timeout: TimeInterval, completion: @escaping (Result<[URL], FinderError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSelectionScript(timeout: timeout)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func runSelectionScript(timeout: TimeInterval) -> Result<[URL], FinderError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", selectionScript]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return .failure(.failed(error.localizedDescription)) }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return .failure(.timeout)
        }

        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            if stderr.contains("-1743") || stderr.contains("-10004") { return .failure(.notAuthorized) }
            return .failure(.failed(stderr))
        }
        let urls = stdout
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
        return .success(urls)
    }

    /// 用辅助功能 API 判断按下的位置是不是 Finder 里的一个文件（而不是标题栏、边栏、空白处）。
    /// 返回 nil 表示无法判断（没授权或 Finder 没响应），调用方按“是”处理。
    static func isOverFinderItem(_ p: NSPoint) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)

        // AX 坐标原点在主屏左上角
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(primaryHeight - p.y), &hit) == .success,
              let element = hit else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == finderID else { return false }

        let itemRoles: Set<String> = ["AXImage", "AXTextField", "AXStaticText", "AXCell", "AXRow", "AXGroup"]
        guard itemRoles.contains(string(element, kAXRoleAttribute)) else { return false }

        let containers: Set<String> = ["AXList", "AXOutline", "AXBrowser", "AXTable", "AXScrollArea"]
        var foundContainer = false
        var current = element
        for _ in 0..<8 {
            guard let parent = parentOf(current) else { break }
            let role = string(parent, kAXRoleAttribute)
            let label = (string(parent, kAXDescriptionAttribute) + string(parent, kAXIdentifierAttribute)).lowercased()
            if role == "AXToolbar" || label.contains("sidebar") || label.contains("边栏") {
                return false
            }
            if containers.contains(role) { foundContainer = true }
            current = parent
        }
        return foundContainer
    }

    /// 用辅助功能读出鼠标下那个文件的路径（不向 Finder 发 Apple Event，不会打断它的拖动跟踪）。
    /// 优先读元素自带的 AXURL；没有时用“所在窗口的文件夹 + 显示的文件名”拼出来。读不出返回 nil
    static func fileUnderCursor(_ p: NSPoint) -> URL? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(primaryHeight - p.y), &hit) == .success,
              let element = hit else { return nil }

        // 元素及其上几层：直接带文件 URL 的最准确；顺便收集显示的名字、找所在窗口
        var names: [String] = []
        var folder: URL?
        var current: AXUIElement? = element
        for depth in 0..<8 {
            guard let el = current else { break }
            if depth < 4 {
                if let url = fileURL(el, kAXURLAttribute) { return url }
                names += [kAXTitleAttribute, kAXValueAttribute, kAXFilenameAttribute].map { string(el, $0) }
                for child in children(el).prefix(6) {
                    if let url = fileURL(child, kAXURLAttribute) { return url }
                    names += [kAXTitleAttribute, kAXValueAttribute].map { string(child, $0) }
                }
            }
            if string(el, kAXRoleAttribute) == kAXWindowRole {
                folder = fileURL(el, kAXDocumentAttribute, directory: true)
                break
            }
            current = parentOf(el)
        }
        // 桌面上的图标不在任何窗口里
        let dir = folder ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard let dir else { return nil }

        let fm = FileManager.default
        for name in names where !name.isEmpty && !name.contains("/") {
            let direct = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: direct.path) { return direct }
            // 访达隐藏了扩展名：按不带扩展名的名字找，唯一时才用
            let matches = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.deletingPathExtension().lastPathComponent == name }
            if matches.count == 1 { return matches[0] }
        }
        NSLog("Peel: couldn't resolve file under cursor; names=\(names.filter { !$0.isEmpty }) folder=\(dir.path)")
        return nil
    }

    private static func fileURL(_ el: AXUIElement, _ attr: String, directory: Bool = false) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success, let v = value else { return nil }
        var url: URL?
        if CFGetTypeID(v) == CFURLGetTypeID() {
            url = (v as! CFURL) as URL
        } else if let s = v as? String {
            url = s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s)
        }
        guard let url, url.isFileURL else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return directory == isDir.boolValue ? url : nil
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success,
              let arr = value as? [AXUIElement] else { return [] }
        return arr
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func parentOf(_ el: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    // MARK: - 权限

    static func openAccessibilitySettings() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
