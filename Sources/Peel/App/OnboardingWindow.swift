import AppKit
import ApplicationServices
import Carbon
import SwiftUI

/// 使用引导：先选语言，之后按所选语言依次介绍用法、开权限、装组件、几种打开方式。
/// 第一次启动自动打开，之后可从菜单栏“使用引导…”再打开。
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private static var current: OnboardingWindow?
    private let window: NSWindow

    /// startAt：从第几步开始（开发截图用）
    static func open(startAt: Int = 0) {
        if let current {
            NSApp.activate(ignoringOtherApps: true)
            current.window.makeKeyAndOrderFront(nil)
            return
        }
        let holder = OnboardingWindow(startAt: startAt)
        current = holder
        NSApp.activate(ignoringOtherApps: true)
        holder.window.makeKeyAndOrderFront(nil)
    }

    private init(startAt: Int) {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        let size = NSSize(width: 640, height: 560)
        window.contentView = NSHostingView(rootView: OnboardingView(step: Step(rawValue: startAt) ?? .language, finish: { [weak window] in window?.close() })
            .frame(width: size.width, height: size.height))
        window.setContentSize(size)
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        Settings.didPromptPermissions = true
        Settings.didOfferComponents = true
        if OnboardingWindow.current === self { OnboardingWindow.current = nil }
    }
}

private enum Step: Int, CaseIterable {
    case language, welcome, permissions, components, ready
}

private struct OnboardingView: View {
    @State var step: Step
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .language: LanguageStep { step = .welcome }
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep()
                case .components: ComponentsStep()
                case .ready: ReadyStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)

            if step != .language { footer }
        }
        .tint(PeelColors.ring)
    }

    private var footer: some View {
        HStack {
            Button(t("上一步", "Back")) { go(-1) }
            Spacer()
            HStack(spacing: 7) {
                ForEach(Step.allCases.dropFirst(), id: \.self) { s in
                    Circle().fill(s == step ? PeelColors.ring : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step == .ready {
                Button(t("开始使用", "Get Started"), action: finish)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(t("跳过", "Skip"), action: finish).buttonStyle(.borderless).foregroundStyle(.secondary)
                Button(t("下一步", "Next")) { go(1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(20)
    }

    private func go(_ d: Int) {
        if let s = Step(rawValue: step.rawValue + d) { step = s }
    }
}

// MARK: - 1. 语言

private struct LanguageStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
            Text("Welcome to Peel · 欢迎使用 Peel")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Choose your language · 请选择语言").foregroundStyle(.secondary)
            HStack(spacing: 16) {
                choice("中文", sub: "简体中文", lang: .zh)
                choice("English", sub: "English", lang: .en)
            }
            .padding(.top, 8)
            Text("You can change it later from the menu bar icon › 语言 / Language")
                .font(.callout).foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func choice(_ title: String, sub: String, lang: Lang) -> some View {
        Button {
            Settings.lang = lang
            next()
        } label: {
            VStack(spacing: 4) {
                Text(title).font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(sub).font(.callout).foregroundStyle(.secondary)
            }
            .frame(width: 190, height: 96)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Settings.lang == lang ? PeelColors.ring : Color.secondary.opacity(0.25),
                              lineWidth: Settings.lang == lang ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 2. 欢迎 + 演示

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 14) {
            Text(t("按住文件，转换就在手边", "Hold a file. The tools come to you."))
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(t("在访达里按住文件不动 1 秒，旁边会弹出轮盘；继续拖到扇区上松手，就会在原文件旁边生成副本，原文件不会被改动。",
                   "In Finder, press and hold a file for a second — a wheel pops up. Drag onto a sector and release; the result is saved as a copy next to the original."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AnimatedGIF(name: Settings.lang == .zh ? "demo-zh" : "demo-en")
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            Spacer(minLength: 0)
        }
    }
}

/// 播放打包在 App 里的 GIF（Resources/Onboarding）
private struct AnimatedGIF: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        let url = Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: "Onboarding")
        v.image = url.flatMap { NSImage(contentsOf: $0) }
    }
}

// MARK: - 3. 权限（实时显示是否已开启）

private struct PermissionsStep: View {
    @State private var accessibility = false
    @State private var finder = FinderPermission.unknown
    @State private var screen = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("开启权限", "Grant permissions"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(t("macOS 需要你手动允许。开好后这里会自动打勾，不用重启 Peel。",
                   "macOS asks you to allow these yourself. Each row ticks itself once it's on — no restart needed."))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                row(icon: "hand.point.up.left.fill", title: t("辅助功能（推荐）", "Accessibility (recommended)"),
                    detail: t("让长按更准：只有按住文件才弹出轮盘，按住标题栏、空白处不会误触。",
                              "Makes long-press precise: the wheel only appears when you hold a file, not the title bar or empty space."),
                    granted: accessibility) { FinderBridge.openAccessibilitySettings() }
                Divider()
                row(icon: "folder.fill", title: t("控制“访达”", "Control Finder"),
                    detail: t("读取你选中的文件。点“开启”后在弹窗里选“好”。", "Reads which files are selected. Click Allow, then OK in the dialog."),
                    granted: finder == .granted) {
                    if finder == .denied { FinderBridge.openAutomationSettings() }
                    else { FinderBridge.fetchSelection(timeout: 60) { _ in refresh() } }
                }
                Divider()
                row(icon: "camera.viewfinder", title: t("屏幕录制（可选）", "Screen Recording (optional)"),
                    detail: t("只有截图功能需要。开启后需要重新打开 Peel 才生效。", "Only for screenshots. Takes effect after reopening Peel."),
                    granted: screen) {
                    if !CGRequestScreenCaptureAccess() {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
            Spacer(minLength: 0)
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        accessibility = AXIsProcessTrusted()
        finder = FinderPermission.current
        screen = CGPreflightScreenCaptureAccess()
    }

    private func row(icon: String, title: String, detail: String, granted: Bool,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(PeelColors.ring).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label(t("已开启", "On"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.weight(.semibold))
            } else {
                Button(t("开启", "Allow"), action: action)
            }
        }
        .padding(14)
    }
}

/// “控制访达”的授权状态（不弹窗询问）
private enum FinderPermission {
    case granted, denied, unknown

    static var current: FinderPermission {
        var target = AEAddressDesc()
        let id = FinderBridge.finderID
        let status: OSStatus = id.withCString { ptr in
            guard AECreateDesc(DescType(typeApplicationBundleID), ptr, strlen(ptr), &target) == noErr else { return -1 }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        }
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .unknown
        }
    }
}

// MARK: - 4. 组件

private struct ComponentsStep: View {
    @State private var installing = Setup.isInstalling
    @State private var mirror = Settings.useChinaMirror
    @State private var tick = 0
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let missing = Setup.missing
        VStack(alignment: .leading, spacing: 16) {
            Text(t("转换组件", "Components"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(t("Word / PPT 转换、PDF 压缩、音视频等功能要用到这些免费工具。照片压缩、图片转换、PDF 合并拆分不需要，现在就能用。",
                   "Office conversion, PDF compression, audio & video use these free tools. Photo compression, image conversion and PDF merge/split work without them."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    HStack(spacing: 8) {
                        Image(systemName: tool.isInstalled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(tool.isInstalled ? Color.green : Color.secondary)
                        Text(tool.displayName).fontWeight(.medium)
                        Text(tool.purpose.text).foregroundStyle(.secondary)
                    }
                }
            }
            .id(tick)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))

            if missing.isEmpty {
                Label(t("全部已安装", "All installed"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else if installing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(t("正在后台安装，可以继续下一步；进度会显示在菜单栏图标下方。",
                           "Installing in the background — feel free to continue. Progress shows under the menu bar icon."))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Button(t("一键安装（约 \(Setup.approxSize(missing))）", "Install All (about \(Setup.approxSize(missing)))")) {
                        Settings.useChinaMirror = mirror
                        installing = true
                        Setup.install(missing) { _ in installing = false; tick += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Toggle(t("使用国内镜像", "Use mirrors in mainland China"), isOn: $mirror)
                        .padding(.leading, 8)
                }
                Text(t("也可以以后在菜单栏图标 › 组件… 里安装。", "You can also install them later from the menu bar icon › Components…."))
                    .font(.callout).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .onReceive(timer) { _ in installing = Setup.isInstalling; tick += 1 }
    }
}

// MARK: - 5. 几种打开方式

private struct ReadyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("准备好了 🍊", "You're all set 🍊"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(t("Peel 住在屏幕右上角的菜单栏里，没有主窗口。打开轮盘有三种方式：",
                   "Peel lives in the menu bar — there's no main window. Three ways to open the wheel:"))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                row("hand.tap.fill", t("长按", "Long-press"),
                    t("在访达里按住文件不动 1 秒", "Hold a file in Finder for a second"))
                Divider()
                row("keyboard", Settings.wheelShortcut.label,
                    t("在访达里选中文件后按快捷键", "Select files in Finder, then press the shortcut"))
                Divider()
                row("contextualmenu.and.cursorarrow", t("右键", "Right-click"),
                    t("右键文件 › 服务 › 用 Peel 处理", "Right-click a file › Services › Process with Peel"))
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 6) {
                Label(t("截图：按 \(Settings.snapShortcut.label) 框选，然后保存、复制、识别文字或钉在屏幕上",
                        "Screenshots: press \(Settings.snapShortcut.label), select an area, then save, copy, extract text or pin it"),
                      systemImage: "camera.viewfinder")
                Label(t("时长、快捷键在菜单栏图标 › 设置…；语言在 › 语言 / Language",
                        "Timings and shortcuts: menu bar icon › Settings…; language: › 语言 / Language"),
                      systemImage: "gearshape")
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(PeelColors.ring).frame(width: 26)
            Text(title).font(.headline).frame(width: 110, alignment: .leading)
            Text(detail).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
    }
}
