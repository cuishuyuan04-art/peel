import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 开发用：逐帧渲染宣传演示动画（不用实拍）。轮盘、提示气泡都用 App 里真实的界面代码画。
///   Peel --demo 输出文件夹 [--en|--zh]
/// 输出 frame-0000.png …（1920×1080），再用 ffmpeg 合成视频 / GIF。
enum DemoMovie {
    static let fps = 30.0
    static let duration = 7.6
    static let canvas = CGSize(width: 1280, height: 720)

    // 场景布局（点，左上角为原点）
    static let window = CGRect(x: 170, y: 40, width: 940, height: 588)
    static let source = CGPoint(x: 640, y: 380)      // Report.docx 图标中心
    static let output = CGPoint(x: 960, y: 380)
    /// 轮盘放大一点，在画面里更醒目
    static let wheelZoom: CGFloat = 1.28      // 生成的 Report.pdf
    static let start = CGPoint(x: 1030, y: 560)      // 光标起点

    @MainActor
    static func run(outDir: URL) {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // 轮盘中心要显示真实的文件图标和名字，放一个空的示例文件
        let file = outDir.appendingPathComponent("Report.docx")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        WheelView.offscreen = true
        let wheel = WheelController.shared
        let frames = Int(duration * fps)
        // --frames 45,95：只渲染这几帧（调样式时用）
        let args = CommandLine.arguments
        let only = args.firstIndex(of: "--frames").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            .map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        for i in 0..<frames where only?.contains(i) ?? true {
            let t = Double(i) / fps
            let s = State.at(t)
            wheel.debugDemo(files: [file], hover: s.hover, dwell: 0)
            let renderer = ImageRenderer(content: DemoScene(state: s, wheel: wheel, file: file)
                .frame(width: canvas.width, height: canvas.height))
            renderer.scale = 1.5
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            let url = outDir.appendingPathComponent(String(format: "frame-%04d.png", i))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        print("wrote \(frames) frames to \(outDir.path)")
    }

    // MARK: - 时间线

    struct State {
        var cursor: CGPoint
        var pressed = false          // 文件被选中
        var wheelScale: Double = 0   // 0 = 不显示
        var wheelOpacity: Double = 0
        var hover: Int?
        var ghost: Double = 0        // 拖着走的文件图标
        var output: Double = 0       // 生成的 PDF 出现（0→1，带回弹）
        var hud: Double = 0
        var hold: Double = 0         // 按住的进度环（0→1）
        var burst: Double = 0        // 完成时的小星星（0→1）
        var caption: (Int, Double) = (0, 0)   // 第几句、透明度

        static func at(_ t: Double) -> State {
            let pdfSector = CGPoint(x: source.x, y: source.y - 122 * wheelZoom)
            var s = State(cursor: start)

            // 光标移到文件上
            s.cursor = lerp(start, source, ease(clamp((t - 0.2) / 0.9)))
            s.pressed = t >= 1.15
            s.hold = t >= 1.15 && t < 2.15 ? clamp((t - 1.15) / 0.85) : 0

            // 按住约 1 秒后弹出轮盘
            let pop = t - 2.0
            if pop >= 0 {
                s.wheelScale = 0.72 + 0.28 * springOut(clamp(pop / 0.45))
                s.wheelOpacity = clamp(pop / 0.12)
                s.ghost = clamp(pop / 0.15)
            }
            // 拖到 PDF 扇区
            let drag = ease(clamp((t - 2.75) / 0.8))
            if t >= 2.75 { s.cursor = lerp(source, pdfSector, drag) }
            if hypot(s.cursor.x - source.x, s.cursor.y - source.y) > (WheelMetrics.innerR + 6) * wheelZoom, t < 4.2 { s.hover = 0 }
            // 松手：轮盘收起
            let release = t - 4.2
            if release >= 0 {
                s.wheelScale = 1 - 0.15 * clamp(release / 0.16)
                s.wheelOpacity = 1 - clamp(release / 0.16)
                s.ghost = 1 - clamp(release / 0.12)
                s.pressed = false
            }
            // 光标松手后稍微挪开
            if t >= 4.4 { s.cursor = lerp(pdfSector, CGPoint(x: 1010, y: 520), ease(clamp((t - 4.4) / 0.9))) }
            // 转换完成：PDF 出现 + 气泡
            s.output = springOut(clamp((t - 4.9) / 0.5))
            s.hud = clamp((t - 4.95) / 0.25) * (1 - clamp((t - 7.2) / 0.25))
            s.burst = t >= 4.9 && t < 5.7 ? (t - 4.9) / 0.8 : 0

            // 字幕
            let lines: [(Double, Double)] = [(0.9, 2.6), (2.6, 4.6), (4.6, 7.6)]
            for (i, (a, b)) in lines.enumerated() where t >= a && t < b {
                s.caption = (i, min(clamp((t - a) / 0.25), i == lines.count - 1 ? 1 : clamp((b - t) / 0.25)))
            }
            return s
        }
    }

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// 带一点回弹的弹出
    static func springOut(_ x: Double) -> Double {
        guard x < 1 else { return 1 }
        return 1 - exp(-6 * x) * cos(x * 9.5)
    }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }

    static let captions: [LText] = [
        LText("在访达里按住一个文件", "Press and hold a file in Finder"),
        LText("拖到想要的格式上，松手", "Drag onto a format and let go"),
        LText("完成：PDF 就在原文件旁边，原文件不变", "Done — the PDF lands right next to the original"),
    ]
}

// MARK: - 画面（扁平卡通风格；轮盘用 App 里真实的界面）

private enum Ink {
    static let line = Color(red: 0.29, green: 0.16, blue: 0.08)       // 深棕描边
    static let paper = Color(red: 1.0, green: 0.965, blue: 0.92)      // 奶油底
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.2)
}

private struct DemoScene: View {
    let state: DemoMovie.State
    @ObservedObject var wheel: WheelController
    let file: URL

    var body: some View {
        let W = DemoMovie.window
        ZStack(alignment: .topLeading) {
            Ink.paper
            // 背景里几团柔和的色块
            Circle().fill(Color(red: 1, green: 0.78, blue: 0.55).opacity(0.55)).frame(width: 420).position(x: 120, y: 110)
            Circle().fill(Color(red: 1, green: 0.66, blue: 0.7).opacity(0.45)).frame(width: 360).position(x: 1190, y: 640)
            Circle().fill(Color(red: 0.75, green: 0.85, blue: 1).opacity(0.5)).frame(width: 220).position(x: 1180, y: 90)

            CartoonWindow(state: state)
                .frame(width: W.width, height: W.height)
                .position(x: W.midX, y: W.midY)

            // 按住时指尖一圈进度
            if state.hold > 0 {
                Circle().trim(from: 0, to: state.hold)
                    .stroke(Ink.orange, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 190, height: 190)
                    .position(DemoMovie.source)
            }

            ZStack {
                WheelView(controller: wheel)
                // 和卡通风格一致的粗描边
                Circle().strokeBorder(Ink.line, lineWidth: 3.5)
                    .frame(width: (WheelMetrics.outerR + 18) * 2 + 4, height: (WheelMetrics.outerR + 18) * 2 + 4)
            }
                .scaleEffect(state.wheelScale * DemoMovie.wheelZoom)
                .opacity(state.wheelOpacity)
                .position(DemoMovie.source)

            // 跟着手走的小文件
            DocIcon(ext: "DOCX", color: .docx, size: 0.75)
                .rotationEffect(.degrees(-8))
                .opacity(state.ghost)
                .position(x: state.cursor.x + 56, y: state.cursor.y + 36)

            Hand(pressed: state.pressed).position(x: state.cursor.x + 8, y: state.cursor.y + 31)

            // 完成：小星星 + 气泡
            if state.burst > 0 { Burst(progress: state.burst).position(DemoMovie.output) }
            DoneBubble()
                .scaleEffect(0.5 + 0.5 * state.hud, anchor: .bottom)
                .opacity(state.hud)
                .position(x: DemoMovie.output.x - 20, y: DemoMovie.output.y - 145)

            Text(DemoMovie.captions[state.caption.0].text)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Ink.line)
                .opacity(state.caption.1)
                .frame(width: DemoMovie.canvas.width)
                .position(x: DemoMovie.canvas.width / 2, y: 676)
        }
        .frame(width: DemoMovie.canvas.width, height: DemoMovie.canvas.height)
        .environment(\.colorScheme, .light)
    }
}

/// 粗描边 + 硬投影的窗口卡片
private struct CartoonWindow: View {
    let state: DemoMovie.State

    var body: some View {
        let W = DemoMovie.window
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Ink.line).offset(x: 9, y: 9)
            shape.fill(Color.white)
            // 标题栏
            HStack(spacing: 10) {
                ForEach([Color(red: 1, green: 0.42, blue: 0.38), Color(red: 1, green: 0.78, blue: 0.3),
                         Color(red: 0.4, green: 0.82, blue: 0.45)], id: \.self) { c in
                    Circle().fill(c).overlay(Circle().strokeBorder(Ink.line, lineWidth: 2.5)).frame(width: 18, height: 18)
                }
                Spacer()
                Text(t("我的文件", "My Files")).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Ink.line)
                Spacer()
                Spacer().frame(width: 74)
            }
            .padding(.horizontal, 24)
            .frame(width: W.width, height: 64)
            Rectangle().fill(Ink.line).frame(width: W.width, height: 3.5).offset(y: 64)

            let rel = { (x: CGFloat) in CGPoint(x: x - W.minX, y: DemoMovie.source.y - W.minY) }
            FileItem(name: "Photo.jpg", ext: "JPG", color: .jpg, selected: false).position(rel(320))
            FileItem(name: "Budget.xlsx", ext: "XLSX", color: .xlsx, selected: false).position(rel(480))
            FileItem(name: "Report.docx", ext: "DOCX", color: .docx, selected: state.pressed).position(rel(640))
            FileItem(name: "Notes.txt", ext: "TXT", color: .txt, selected: false).position(rel(800))
            FileItem(name: "Report.pdf", ext: "PDF", color: .pdf, selected: false)
                .scaleEffect(0.3 + 0.7 * state.output)
                .opacity(min(1, state.output * 2.5))
                .position(rel(DemoMovie.output.x))
        }
        .clipShape(Rectangle().offset(x: 0, y: 0).size(width: W.width + 20, height: W.height + 20))
        .overlay(shape.strokeBorder(Ink.line, lineWidth: 4))
    }
}

private extension Color {
    static let docx = Color(red: 0.25, green: 0.5, blue: 0.95)
    static let pdf = Color(red: 0.93, green: 0.3, blue: 0.27)
    static let jpg = Color(red: 0.25, green: 0.72, blue: 0.5)
    static let xlsx = Color(red: 0.13, green: 0.58, blue: 0.33)
    static let txt = Color(red: 0.6, green: 0.6, blue: 0.64)
}

private struct FileItem: View {
    let name: String
    let ext: String
    let color: Color
    let selected: Bool

    var body: some View {
        VStack(spacing: 12) {
            DocIcon(ext: ext, color: color, size: 1.3)
                .scaleEffect(selected ? 1.06 : 1)
            Text(name)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? .white : Ink.line)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(selected ? Color.docx : .clear, in: Capsule())
        }
    }
}

/// 扁平的文件图标：折角纸 + 彩色标签
private struct DocIcon: View {
    let ext: String
    let color: Color
    let size: CGFloat

    var body: some View {
        let w = 78 * size, h = 98 * size, fold = 24 * size, lw = 3.5 * max(size, 0.7)
        ZStack(alignment: .topLeading) {
            Page(fold: fold).fill(Color.white)
            Page(fold: fold).stroke(Ink.line, style: StrokeStyle(lineWidth: lw, lineJoin: .round))
            // 折角
            Path { p in
                p.move(to: CGPoint(x: w - fold, y: 0))
                p.addLine(to: CGPoint(x: w - fold, y: fold))
                p.addLine(to: CGPoint(x: w, y: fold))
            }
            .stroke(Ink.line, style: StrokeStyle(lineWidth: lw, lineJoin: .round))
            // 几行字
            VStack(alignment: .leading, spacing: 7 * size) {
                ForEach([0.55, 0.42, 0.5], id: \.self) { k in
                    Capsule().fill(Ink.line.opacity(0.18)).frame(width: w * k, height: 5 * size)
                }
            }
            .offset(x: 13 * size, y: 22 * size)
            Text(ext)
                .font(.system(size: 15 * size, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 7 * size).padding(.vertical, 3 * size)
                .background(color, in: RoundedRectangle(cornerRadius: 6 * size))
                .overlay(RoundedRectangle(cornerRadius: 6 * size).strokeBorder(Ink.line, lineWidth: 2.5 * max(size, 0.7)))
                .offset(x: -10 * size, y: h - 36 * size)
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }
}

private struct Page: Shape {
    let fold: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let rad: CGFloat = 8
        p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.maxX - rad, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rad), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// 卡通手：白色手指 + 深棕描边（按下时稍微缩小）
private struct Hand: View {
    let pressed: Bool

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) / 8 * 2 * .pi
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Ink.line)
                    .offset(x: cos(a) * 3, y: sin(a) * 3)
            }
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color.white)
        }
        .scaleEffect(pressed ? 0.9 : 1, anchor: .topLeading)
        .shadow(color: Ink.line.opacity(0.25), radius: 0, x: 3, y: 4)
    }
}

/// 完成时向四周散开的小星星
private struct Burst: View {
    let progress: Double

    var body: some View {
        let colors: [Color] = [Ink.orange, .pdf, Color(red: 1, green: 0.8, blue: 0.2), .docx]
        ZStack {
            ForEach(0..<10, id: \.self) { i in
                let a = Double(i) / 10 * 2 * .pi + 0.3
                let d = 50 + 70 * DemoMovie.ease(progress)
                Image(systemName: i % 2 == 0 ? "star.fill" : "circle.fill")
                    .font(.system(size: i % 2 == 0 ? 20 : 10))
                    .foregroundStyle(colors[i % colors.count])
                    .offset(x: cos(a) * d, y: sin(a) * d)
                    .opacity(1 - progress)
            }
        }
    }
}

private struct DoneBubble: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.orange)
            Text(t("已生成「Report.pdf」", "Created “Report.pdf”"))
                .foregroundStyle(Ink.line)
        }
        .font(.system(size: 18, weight: .bold, design: .rounded))
        .fixedSize()
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 3))
        .background(Capsule().fill(Ink.line).offset(x: 4, y: 5))
    }
}
