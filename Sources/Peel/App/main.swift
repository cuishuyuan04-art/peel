import AppKit

// 开发用的命令行测试：不启动 App，后台线程执行完直接结束
let cliArgs = Array(CommandLine.arguments.dropFirst())
if let first = cliArgs.first, CLI.commands.contains(first) {
    DispatchQueue.global(qos: .userInitiated).async {
        _ = CLI.run(cliArgs)
        fflush(stdout)
        _exit(0)
    }
    dispatchMain()
}
// 轮盘 / 图标渲染：要在主线程上画，但同样不需要启动 App
if let first = cliArgs.first, ["--render", "--icon", "--icon-variants", "--ghost"].contains(first) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { _ = DebugRender.runIfRequested() }
        exit(0)
    }
    dispatchMain()
}

// 宣传演示动画：逐帧渲染（Peel --demo 输出文件夹 [--en|--zh]）
if cliArgs.first == "--demo", cliArgs.count >= 2 {
    if cliArgs.contains("--en") { Settings.langOverride = .en }
    if cliArgs.contains("--zh") { Settings.langOverride = .zh }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { DemoMovie.run(outDir: URL(fileURLWithPath: cliArgs[1])) }
        exit(0)
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
