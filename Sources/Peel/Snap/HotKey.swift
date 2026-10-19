import AppKit
import Carbon

/// 快捷键预设
struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32   // Carbon 修饰键
    let label: String

    /// 截图
    static let presets: [Shortcut] = [
        Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧S"),
        Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧A"),
        Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧A"),
        Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), label: "⌘⇧2"),
    ]

    /// 为选中的文件打开轮盘
    static let wheelPresets: [Shortcut] = [
        Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧P"),
        Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧Space"),
        Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥P"),
    ]
}

/// 全局快捷键（Carbon，不需要额外权限）。每个用途一个编号，可以同时注册多个
final class HotKey {
    static let shared = HotKey()

    enum Slot: UInt32 { case snap = 1, wheel = 2 }

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    func register(_ slot: Slot, _ shortcut: Shortcut, action: @escaping () -> Void) {
        installHandler()
        if let old = refs[slot.rawValue] { UnregisterEventHotKey(old) }
        refs[slot.rawValue] = nil
        actions[slot.rawValue] = action

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5045_454C), id: slot.rawValue)   // 'PEEL'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[slot.rawValue] = ref
        } else {
            Log.write("hotkey \(shortcut.label) register failed: \(status)")
            HUD.shared.show(t("快捷键 \(shortcut.label) 被其他软件占用了，可以在菜单里换一个",
                              "\(shortcut.label) is taken by another app — pick another in the menu"),
                            symbol: "exclamationmark.triangle.fill", duration: 4)
        }
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let n = id.id
            DispatchQueue.main.async { HotKey.shared.fire(n) }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
