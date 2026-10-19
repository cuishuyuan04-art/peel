import Foundation

/// 音频 / 视频（ffmpeg）
enum MediaEngine {
    typealias Progress = (Double) -> Void

    struct Info {
        var duration: Double = 0
        var videoCodec: String?
        var audioCodec: String?
        var audioBitrate: Int?   // bit/s
        var hasVideo: Bool { videoCodec != nil }
        var hasAudio: Bool { audioCodec != nil }
    }

    /// GIF 最长截取多少秒（再长体积会非常大）
    static let gifMaxSeconds: Double = 30

    // MARK: - 探测

    static func probe(_ url: URL) throws -> Info {
        guard let ffprobe = Shell.which("ffprobe") else { throw PeelError("缺少 FFmpeg", "FFmpeg missing") }
        let json: String
        do {
            json = try Shell.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_streams", "-show_format", url.path])
        } catch {
            throw PeelError("无法读取「\(url.lastPathComponent)」", "Can't read “\(url.lastPathComponent)”")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return Info() }
        var info = Info()
        if let f = obj["format"] as? [String: Any], let d = f["duration"] as? String {
            info.duration = Double(d) ?? 0
        }
        for s in obj["streams"] as? [[String: Any]] ?? [] {
            let codec = s["codec_name"] as? String
            let disposition = s["disposition"] as? [String: Any]
            let isCover = (disposition?["attached_pic"] as? Int) == 1
            switch s["codec_type"] as? String {
            case "video" where !isCover && info.videoCodec == nil:
                info.videoCodec = codec
            case "audio" where info.audioCodec == nil:
                info.audioCodec = codec
                info.audioBitrate = (s["bit_rate"] as? String).flatMap { Int($0) }
            default: break
            }
        }
        return info
    }

    // MARK: - 运行 ffmpeg（带进度）

    private static func ffmpeg(_ args: [String], duration: Double, progress: Progress?) throws {
        guard let exe = Tool.ffmpeg.path else { throw PeelError("缺少 FFmpeg", "FFmpeg missing") }
        let base = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
        try Shell.stream(exe, base + args) { line in
            guard duration > 0, let progress, line.hasPrefix("out_time_us="),
                  let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress(min(1, max(0, us / 1_000_000 / duration)))
        }
    }

    // MARK: - 视频

    /// 视频转 MP4 / MOV / GIF，写到 dst
    static func convertVideo(_ src: URL, to ext: String, dst: URL, progress: Progress?) throws {
        let info = try probe(src)
        guard info.hasVideo else { throw PeelError("「\(src.lastPathComponent)」里没有画面", "No video in “\(src.lastPathComponent)”") }

        if ext == "gif" {
            let length = min(info.duration, gifMaxSeconds)
            let filter = "fps=12,scale='min(480,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"
            try ffmpeg(["-t", String(gifMaxSeconds), "-i", src.path, "-filter_complex", filter, "-loop", "0", dst.path],
                       duration: length, progress: progress)
            return
        }

        // H.264/H.265 + AAC/MP3 只换封装，几乎瞬间完成、不损失画质
        let copyVideo = ["h264", "hevc"].contains(info.videoCodec ?? "")
        let copyAudio = !info.hasAudio || ["aac", "mp3", "alac"].contains(info.audioCodec ?? "")
        var args = ["-i", src.path, "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0"]
        if copyVideo && copyAudio {
            args += ["-c", "copy"]
            if info.videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }   // 让 QuickTime / 预览能播放
        } else {
            args += ["-c:v", "libx264", "-crf", "20", "-preset", "faster", "-pix_fmt", "yuv420p",
                     "-c:a", "aac_at", "-b:a", "160k"]
        }
        args += ["-movflags", "+faststart", dst.path]
        try ffmpeg(args, duration: info.duration, progress: progress)
    }

    private struct VideoLevel {
        let crf: Int
        let shortSide: Int?   // 短边上限（横屏限高、竖屏限宽）
        let audio: String
    }

    private static func videoLevel(_ level: CompressLevel) -> VideoLevel {
        switch level {
        case .light: return VideoLevel(crf: 23, shortSide: nil, audio: "128k")
        case .medium: return VideoLevel(crf: 26, shortSide: 1080, audio: "96k")
        case .strong: return VideoLevel(crf: 30, shortSide: 720, audio: "64k")
        }
    }

    private static func videoCompressArgs(_ level: CompressLevel, hasAudio: Bool) -> [String] {
        let p = videoLevel(level)
        var args = ["-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
                    "-c:v", "libx264", "-crf", String(p.crf), "-preset", "faster", "-pix_fmt", "yuv420p"]
        if let s = p.shortSide {
            args += ["-vf", "scale='if(gte(iw,ih),-2,min(iw,\(s)))':'if(gte(iw,ih),min(ih,\(s)),-2)'"]
        }
        if hasAudio { args += ["-c:a", "aac_at", "-b:a", p.audio] }
        return args + ["-movflags", "+faststart"]
    }

    /// 压缩后的扩展名：MP4/MOV 保持，其余（AVI/MKV/WebM）输出 MP4
    static func compressedVideoExt(_ src: URL) -> String {
        let ext = FileKind.normalizedExt(src)
        return ext == "mov" ? "mov" : "mp4"
    }

    static func compressVideo(_ src: URL, level: CompressLevel, dst: URL, progress: Progress?) throws {
        let info = try probe(src)
        try ffmpeg(["-i", src.path] + videoCompressArgs(level, hasAudio: info.hasAudio) + [dst.path],
                   duration: info.duration, progress: progress)
    }

    /// 从视频中间截一小段试压，按比例推算整段大小
    static func estimateVideo(_ src: URL, level: CompressLevel) throws -> Int64 {
        let info = try probe(src)
        guard info.duration > 0 else { return Output.size(src) }
        let sample = min(4, info.duration)
        let start = max(0, info.duration / 2 - sample / 2)
        let tmp = try Output.tempDir().appendingPathComponent("sample.mp4")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        try ffmpeg(["-ss", String(start), "-t", String(sample), "-i", src.path]
                   + videoCompressArgs(level, hasAudio: info.hasAudio) + [tmp.path],
                   duration: 0, progress: nil)
        return Int64(Double(Output.size(tmp)) / sample * info.duration)
    }

    static func extractAudio(_ src: URL, to ext: String, dst: URL, progress: Progress?) throws {
        let info = try probe(src)
        guard info.hasAudio else { throw PeelError("「\(src.lastPathComponent)」没有声音", "No audio in “\(src.lastPathComponent)”") }
        try ffmpeg(["-i", src.path, "-vn", "-map", "0:a:0", "-map_metadata", "0"] + audioCodecArgs(ext, info: info, bitrate: nil)
                   + [dst.path], duration: info.duration, progress: progress)
    }

    // MARK: - 音频

    /// 目标格式的编码参数；bitrate 为 nil 时用高质量默认值，源格式相同则直接复制
    private static func audioCodecArgs(_ ext: String, info: Info, bitrate: String?) -> [String] {
        switch ext {
        case "mp3":
            if let bitrate { return ["-c:a", "libmp3lame", "-b:a", bitrate] }
            return ["-c:a", "libmp3lame", "-q:a", "2"]
        default: // m4a
            if bitrate == nil, info.audioCodec == "aac" { return ["-c:a", "copy"] }
            return ["-c:a", "aac_at", "-b:a", bitrate ?? "192k"]
        }
    }

    static func convertAudio(_ src: URL, to ext: String, dst: URL, progress: Progress?) throws {
        let info = try probe(src)
        guard info.hasAudio else { throw PeelError("「\(src.lastPathComponent)」没有声音", "No audio in “\(src.lastPathComponent)”") }
        try ffmpeg(["-i", src.path, "-vn", "-map", "0:a:0", "-map_metadata", "0"] + audioCodecArgs(ext, info: info, bitrate: nil)
                   + [dst.path], duration: info.duration, progress: progress)
    }

    private static func audioBitrate(_ level: CompressLevel) -> Int {
        switch level {
        case .light: return 128_000
        case .medium: return 96_000
        case .strong: return 64_000
        }
    }

    /// 压缩后的扩展名：MP3 保持 MP3，其余（WAV/FLAC/AAC…）输出 M4A
    static func compressedAudioExt(_ src: URL) -> String {
        FileKind.normalizedExt(src) == "mp3" ? "mp3" : "m4a"
    }

    static func compressAudio(_ src: URL, level: CompressLevel, dst: URL, progress: Progress?) throws {
        let info = try probe(src)
        let rate = "\(audioBitrate(level) / 1000)k"
        try ffmpeg(["-i", src.path, "-vn", "-map", "0:a:0", "-map_metadata", "0"]
                   + audioCodecArgs(dst.pathExtension.lowercased(), info: info, bitrate: rate)
                   + [dst.path], duration: info.duration, progress: progress)
    }

    /// 音频按码率直接算
    static func estimateAudio(_ src: URL, level: CompressLevel) throws -> Int64 {
        let info = try probe(src)
        return Int64(Double(audioBitrate(level)) / 8 * info.duration)
    }
}
