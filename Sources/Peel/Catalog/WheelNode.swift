import Foundation

enum CompressLevel: Hashable {
    case light, medium, strong
}

/// 轮盘叶子节点触发的操作
enum PeelAction: Hashable {
    case convert(to: String)          // 目标扩展名
    case compress(CompressLevel)
    case compressTo(Int64?)           // 压到指定大小（字节，每个文件各自满足）；nil = 弹窗自定义
    case extractAudio(to: String)
    case mergeToPDF
    case splitPDF, redact, metadata
    case rotate(Int)                  // 顺时针角度：90 / -90 / 180
    case crop, addBackground, resize
    case cutout, idPhoto              // 抠图（透明 PNG）、证件照
    case watermark, sign              // 加水印（PDF / 图片）、签名（PDF）
    case zip
    case snap(SnapAction)             // 截图轮盘
}

/// 轮盘上的一个扇区；有 children 的是分类（悬停展开下一层），有 action 的是叶子
struct WheelNode: Identifiable {
    let id = UUID()
    var title: LText
    var symbol: String
    var detail: LText? = nil
    var children: [WheelNode] = []
    var action: PeelAction? = nil

    var isCategory: Bool { !children.isEmpty }
}
