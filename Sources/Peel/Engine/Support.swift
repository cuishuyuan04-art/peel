import Foundation

struct PeelError: Error {
    let message: LText

    init(_ zh: String, _ en: String) {
        message = LText(zh, en)
    }

    static let notYet = PeelError("这个功能会在后续阶段加入", "Coming in a later stage")
    static let cancelled = PeelError("已取消", "Cancelled")
}

/// 当前正在执行的任务（在 Jobs.queue 上跑），可以从菜单栏取消
enum Jobs {
    /// 所有用户任务都在这个串行队列上执行，一次一个
    static let queue = DispatchQueue(label: "peel.jobs", qos: .userInitiated)
    private static let key = DispatchSpecificKey<Bool>()
    private static let lock = NSLock()
    private static var process: Process?
    private static var cancelled = false
    private static var currentLabel: LText?

    static func setUp() { queue.setSpecific(key: key, value: true) }

    /// 是否在任务队列里（只有任务里的子进程才能被取消）
    static var onJobQueue: Bool { DispatchQueue.getSpecific(key: key) == true }

    static var label: LText? { locked { currentLabel } }
    static var isCancelled: Bool { locked { cancelled } }

    static func begin(_ label: LText) { locked { currentLabel = label; cancelled = false } }
    static func end() { locked { currentLabel = nil; process = nil } }
    static func attach(_ p: Process?) { locked { process = p } }

    static func cancel() {
        locked {
            cancelled = true
            process?.terminate()
        }
    }

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 运行命令行工具
enum Shell {
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    private static func makeProcess(_ exe: String, _ args: [String], cwd: URL?, env extraEnv: [String: String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env.merge(extraEnv) { _, new in new }
        p.environment = env
        return p
    }

    private static func finish(_ p: Process, exe: String, output: String) throws {
        if Jobs.onJobQueue {
            Jobs.attach(nil)
            if Jobs.isCancelled { throw PeelError.cancelled }
        }
        guard p.terminationStatus == 0 else {
            let name = (exe as NSString).lastPathComponent
            NSLog("Peel: \(name) failed (\(p.terminationStatus)): \(output)")
            throw ToolFailure(tool: name, status: p.terminationStatus, output: output)
        }
    }

    /// timeout：超过这么多秒就终止进程并报“超时”
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:],
                    timeout: TimeInterval? = nil) throws -> String {
        let p = makeProcess(exe, args, cwd: cwd, env: env)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        if Jobs.onJobQueue { Jobs.attach(p) }
        var timedOut = false
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning {
                    timedOut = true
                    p.terminate()
                }
            }
        }
        // 先读完输出再等退出，避免输出太多把管道塞满
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if timedOut {
            if Jobs.onJobQueue { Jobs.attach(nil) }
            throw PeelError("处理超时", "Timed out")
        }
        try finish(p, exe: exe, output: output)
        return output
    }

    /// 逐行读取标准输出（用于 ffmpeg 的进度），标准错误收集起来用于报错
    static func stream(_ exe: String, _ args: [String], onLine: @escaping (String) -> Void) throws {
        let p = makeProcess(exe, args, cwd: nil, env: [:])
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            buffer.append(h.availableData)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                onLine(line)
            }
        }
        try p.run()
        if Jobs.onJobQueue { Jobs.attach(p) }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        try finish(p, exe: exe, output: String(decoding: errData, as: UTF8.self))
    }

    /// 在 PATH 里找可执行文件
    static func which(_ name: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        let dirs = searchPath.split(separator: ":").map(String.init)
        for candidate in extra + dirs.map({ "\($0)/\(name)" }) where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}

struct ToolFailure: Error {
    let tool: String
    let status: Int32
    let output: String
}

/// 输出文件命名：放在原文件旁边，重名时像 Finder 一样加序号
enum Output {
    static let fm = FileManager.default

    static func unique(_ url: URL) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// 与 src 同目录、同名、换扩展名（可加后缀）
    static func sibling(of src: URL, ext: String, suffix: String = "") -> URL {
        let base = src.deletingPathExtension().lastPathComponent + suffix
        let url = src.deletingLastPathComponent().appendingPathComponent(base)
        return unique(ext.isEmpty ? url : url.appendingPathExtension(ext))
    }

    static var compressedSuffix: String { t("_压缩", "_compressed") }

    /// Peel 自己的临时目录（只放中间文件，不放用户文件）
    private static var tempRoot: URL {
        fm.temporaryDirectory.appendingPathComponent("Peel", isDirectory: true)
    }

    /// 启动时清掉上次留下的中间文件
    static func cleanTemp() {
        try? fm.removeItem(at: tempRoot)
    }

    /// 每个任务一个临时目录
    static func tempDir() throws -> URL {
        let dir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 把临时文件移到最终位置
    @discardableResult
    static func place(_ tmp: URL, at dst: URL) throws -> URL {
        do {
            try fm.moveItem(at: tmp, to: dst)
        } catch {
            throw PeelError("无法写入「\(dst.deletingLastPathComponent().lastPathComponent)」文件夹",
                            "Can't write to “\(dst.deletingLastPathComponent().lastPathComponent)”")
        }
        return dst
    }

    /// 直接读文件系统（URL.resourceValues 会缓存，文件重写后读到旧大小）
    static func size(_ url: URL) -> Int64 {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static var appSupport: URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peel", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
