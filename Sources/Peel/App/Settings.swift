import Foundation

enum Lang: String {
    case zh, en
}

/// 用户偏好（存在 UserDefaults）
enum Settings {
    private static let d = UserDefaults.standard

    /// 开发渲染时临时指定语言，不写入偏好
    static var langOverride: Lang?

    /// 没选过语言时跟随系统：系统首选语言是中文就用中文，否则英文
    static var lang: Lang {
        get { langOverride ?? Lang(rawValue: d.string(forKey: "lang") ?? "") ?? systemLang }
        set {
            d.set(newValue.rawValue, forKey: "lang")
            NotificationCenter.default.post(name: langChanged, object: nil)
        }
    }

    static let langChanged = Notification.Name("PeelLangChanged")

    private static var systemLang: Lang {
        (Locale.preferredLanguages.first ?? "").hasPrefix("zh") ? .zh : .en
    }

    static let defaultHold = 1.0
    static let defaultDwell = 0.7

    /// 长按触发时长（秒）
    static var holdDuration: Double {
        get { d.object(forKey: "holdDuration") as? Double ?? defaultHold }
        set { d.set(newValue, forKey: "holdDuration") }
    }

    /// 拖到分类扇区上停多久展开下一层（秒）
    static var dwellDuration: Double {
        get { d.object(forKey: "dwellDuration") as? Double ?? defaultDwell }
        set { d.set(newValue, forKey: "dwellDuration") }
    }

    /// 安装组件时用国内镜像；默认按系统地区判断
    static var useChinaMirror: Bool {
        get { d.object(forKey: "useChinaMirror") as? Bool ?? (Locale.current.region?.identifier == "CN") }
        set { d.set(newValue, forKey: "useChinaMirror") }
    }

    /// 截图快捷键（Shortcut.presets 的序号）
    static var snapShortcut: Shortcut {
        get { Shortcut.presets[min(max(0, d.integer(forKey: "snapShortcut")), Shortcut.presets.count - 1)] }
        set { d.set(Shortcut.presets.firstIndex(of: newValue) ?? 0, forKey: "snapShortcut") }
    }

    /// 打开轮盘的快捷键（Shortcut.wheelPresets 的序号）
    static var wheelShortcut: Shortcut {
        get { Shortcut.wheelPresets[min(max(0, d.integer(forKey: "wheelShortcut")), Shortcut.wheelPresets.count - 1)] }
        set { d.set(Shortcut.wheelPresets.firstIndex(of: newValue) ?? 0, forKey: "wheelShortcut") }
    }

    /// 上次保存截图的文件夹
    static var lastSnapFolder: URL? {
        get { d.url(forKey: "lastSnapFolder") }
        set { d.set(newValue, forKey: "lastSnapFolder") }
    }

    static var longPressEnabled: Bool {
        get { d.object(forKey: "longPressEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "longPressEnabled") }
    }

    /// 是否已经问过要不要一键安装组件（老用户升级后也问一次）
    static var didOfferComponents: Bool {
        get { d.bool(forKey: "didOfferComponents") }
        set { d.set(newValue, forKey: "didOfferComponents") }
    }

    static var didPromptPermissions: Bool {
        get { d.bool(forKey: "didPromptPermissions") }
        set { d.set(newValue, forKey: "didPromptPermissions") }
    }
}

/// 中英双语文本
struct LText: Hashable {
    let zh: String
    let en: String

    init(_ zh: String, _ en: String) {
        self.zh = zh
        self.en = en
    }

    /// 中英文相同（如格式名 PDF）
    init(_ same: String) {
        self.init(same, same)
    }

    var text: String { Settings.lang == .zh ? zh : en }
}

func t(_ zh: String, _ en: String) -> String {
    Settings.lang == .zh ? zh : en
}
