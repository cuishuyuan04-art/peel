import AppKit
import SwiftUI

/// 编辑功能的设置窗口（裁剪、改尺寸、加背景、元数据、拆分、涂黑）
final class EditorWindow: NSObject, NSWindowDelegate {
    private static var current: EditorWindow?
    private let window: NSWindow

    static func open(_ action: PeelAction, file: URL, title: LText) {
        current?.window.close()

        let holder = EditorWindow(title: "\(title.text) · \(file.lastPathComponent)")
        let done: () -> Void = { [weak holder] in holder?.window.close() }
        let view: AnyView
        let size: NSSize
        switch action {
        case .crop:
            view = AnyView(CropEditor(src: file, done: done)); size = NSSize(width: 760, height: 640)
        case .resize:
            view = AnyView(ResizeEditor(src: file, done: done)); size = NSSize(width: 460, height: 400)
        case .addBackground:
            view = AnyView(BackgroundEditor(src: file, done: done)); size = NSSize(width: 760, height: 640)
        case .metadata where FileKind.of(file) == .pdf:
            view = AnyView(PDFMetaEditor(src: file, done: done)); size = NSSize(width: 480, height: 470)
        case .metadata:
            view = AnyView(PhotoMetaEditor(src: file, done: done)); size = NSSize(width: 460, height: 420)
        case .splitPDF:
            view = AnyView(SplitEditor(src: file, done: done)); size = NSSize(width: 460, height: 360)
        case .watermark:
            view = AnyView(WatermarkEditor(src: file, done: done)); size = NSSize(width: 820, height: 660)
        case .sign:
            view = AnyView(SignEditor(src: file, done: done)); size = NSSize(width: 900, height: 720)
        case .idPhoto:
            view = AnyView(IDPhotoEditor(src: file, done: done)); size = NSSize(width: 820, height: 660)
        case .redact:
            view = AnyView(RedactEditor(src: file, done: done)); size = NSSize(width: 780, height: 720)
        default:
            return
        }
        holder.window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        holder.window.setContentSize(size)
        holder.window.center()
        current = holder
        NSApp.activate(ignoringOtherApps: true)
        holder.window.makeKeyAndOrderFront(nil)
    }

    private init(title: String) {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        if EditorWindow.current === self { EditorWindow.current = nil }
    }
}

/// 设置窗口的统一框架：内容 + 底部按钮
struct EditorFrame<Content: View>: View {
    var applyTitle: String? = t("生成", "Create")
    var canApply = true
    var note: String? = nil
    var onApply: () -> Void = {}
    let done: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if let note {
                    Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(applyTitle == nil ? t("关闭", "Close") : t("取消", "Cancel"), action: done)
                    .keyboardShortcut(.cancelAction)
                if let applyTitle {
                    Button(applyTitle) {
                        onApply()
                        done()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(PeelColors.ring)
                    .disabled(!canApply)
                }
            }
            .controlSize(.large)
            .padding(16)
        }
        .tint(PeelColors.ring)
    }
}

/// 一组可选的小按钮（比例、颜色等）
struct ChipPicker<T: Equatable>: View {
    let options: [(String, T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { i in
                let (label, value) = options[i]
                let on = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(on ? PeelColors.ring : Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 颜色色块：选中时外面一圈橙色。圆圈画在色块自己的范围内，不会凸出去被旁边的边缘裁掉
struct ColorSwatch: View {
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .stroke(PeelColors.ring, lineWidth: 2.5)
                .opacity(selected ? 1 : 0)
            Circle()
                .fill(color)
                .overlay(Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                .padding(5)
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
        .onTapGesture(perform: action)
    }
}

/// 读取图片：预览图（限制大小）+ 转正后的原图像素尺寸
struct LoadedImage {
    let preview: NSImage
    let pixelSize: CGSize
    let hasAlpha: Bool

    static func load(_ url: URL, maxPixel: Int = 1600) -> LoadedImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              let img = try? ImageEngine.load(url, maxPixel: maxPixel) else { return nil }
        let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
        let size = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        return LoadedImage(preview: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)),
                           pixelSize: size, hasAlpha: ImageEngine.hasAlpha(img))
    }
}

/// 等比放进容器后的显示区域
func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return box }
    let s = min(box.width / size.width, box.height / size.height)
    let w = size.width * s, h = size.height * s
    return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
}

/// 透明图片下面垫的棋盘格
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color.gray.opacity(0.18)))
                }
            }
        }
    }
}
