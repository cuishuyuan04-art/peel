import Foundation

enum FileKind: Hashable {
    case document, presentation, spreadsheet, pdf, image, video, audio, other

    static func of(_ url: URL) -> FileKind {
        switch normalizedExt(url) {
        case "doc", "docx", "pages", "rtf", "txt", "odt", "md", "html":
            return .document
        case "ppt", "pptx", "key", "odp":
            return .presentation
        case "xls", "xlsx", "numbers", "csv", "ods":
            return .spreadsheet
        case "pdf":
            return .pdf
        case "jpg", "png", "heic", "webp", "tiff", "bmp", "gif":
            return .image
        case "mp4", "mov", "avi", "mkv", "webm":
            return .video
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff":
            return .audio
        default:
            return .other
        }
    }

    /// 统一同义扩展名（jpeg→jpg，heif→heic …）
    static func normalizedExt(_ url: URL) -> String {
        let e = url.pathExtension.lowercased()
        switch e {
        case "jpeg", "jpe": return "jpg"
        case "heif": return "heic"
        case "tif": return "tiff"
        case "htm": return "html"
        case "m4v": return "mp4"
        case "aif": return "aiff"
        default: return e
        }
    }
}
