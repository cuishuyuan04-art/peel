import Foundation

/// 轮盘弹出时在后台把每个压缩档位实际跑一遍，标出真实大小；
/// 结果文件留在临时目录，用户选中那一档时直接拿来用，不用再压一次
final class Estimator {
    static let shared = Estimator()

    /// 每档：原文件 → 压好的临时文件
    private(set) var results: [CompressLevel: [URL: URL]] = [:]
    private var token = UUID()

    /// 太大或太多就不预估，避免轮盘一弹出就占满 CPU
    private let maxTotalBytes: Int64 = 300 * 1024 * 1024
    private let maxFiles = 30

    func start(files: [URL], update: @escaping (CompressLevel, Int64) -> Void) {
        cancel()
        let kinds = Set(files.map(FileKind.of))
        guard !files.isEmpty, files.count <= maxFiles, kinds.count == 1, let kind = kinds.first else { return }
        // 依赖没装好时不预估（显示的是估算值）
        guard Deps.required(for: .compress(.light), files: files).isEmpty else { return }

        let my = token
        if kind == .video || kind == .audio {
            startMedia(files: files, kind: kind, token: my, update: update)
            return
        }
        guard kind == .image || kind == .pdf, Catalog.totalSize(files) <= maxTotalBytes else { return }
        for level in [CompressLevel.light, .medium, .strong] {
            DispatchQueue.global(qos: .utility).async {
                var map: [URL: URL] = [:]
                var total: Int64 = 0
                for src in files {
                    guard self.token == my else { return }
                    let original = Output.size(src)
                    do {
                        let out = try Estimator.compressToTemp(src, level: level)
                        let size = Output.size(out)
                        map[src] = out
                        total += min(size, original)
                    } catch {
                        total += original
                    }
                }
                DispatchQueue.main.async {
                    guard self.token == my else { return }
                    self.results[level] = map
                    update(level, total)
                }
            }
        }
    }

    /// 音视频不整段预压（太慢）：视频截中间几秒试压后按时长推算，音频按码率直接算。
    /// 三档依次跑，避免同时开三个编码器
    private func startMedia(files: [URL], kind: FileKind, token my: UUID,
                            update: @escaping (CompressLevel, Int64) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            for level in [CompressLevel.light, .medium, .strong] {
                var total: Int64 = 0
                for src in files {
                    guard self.token == my else { return }
                    let original = Output.size(src)
                    let est = (try? kind == .video
                        ? MediaEngine.estimateVideo(src, level: level)
                        : MediaEngine.estimateAudio(src, level: level)) ?? original
                    total += min(est, original)
                }
                DispatchQueue.main.async {
                    guard self.token == my else { return }
                    update(level, total)
                }
            }
        }
    }

    /// 取出某档已压好的文件（取走后不再保留）
    func take(_ level: CompressLevel, for src: URL) -> URL? {
        results[level]?.removeValue(forKey: src)
    }

    /// 压缩到临时目录，返回结果文件（图片可能换了扩展名）
    static func compressToTemp(_ src: URL, level: CompressLevel,
                               progress: MediaEngine.Progress? = nil) throws -> URL {
        let tmp = try Output.tempDir().appendingPathComponent(src.lastPathComponent)
        switch FileKind.of(src) {
        case .video:
            let out = tmp.deletingPathExtension().appendingPathExtension(MediaEngine.compressedVideoExt(src))
            try MediaEngine.compressVideo(src, level: level, dst: out, progress: progress)
            return out
        case .audio:
            let out = tmp.deletingPathExtension().appendingPathExtension(MediaEngine.compressedAudioExt(src))
            try MediaEngine.compressAudio(src, level: level, dst: out, progress: progress)
            return out
        case .pdf:
            try PDFEngine.compress(src, level: level, to: tmp)
            return tmp
        case .image:
            return try ImageEngine.compress(src, level: level, to: tmp)
        default:
            throw PeelError.notYet
        }
    }

    func cancel() {
        token = UUID()
        results = [:]
    }
}
