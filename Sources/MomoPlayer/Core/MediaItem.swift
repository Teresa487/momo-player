import Foundation

/// 一条可播放的媒体记录
struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    /// 云端文件的下载状态，非云端恒为 .current
    let cloudStatus: CloudStatus

    enum CloudStatus {
        case current        // 本地已有
        case downloading    // 云端，正在下载
        case notDownloaded  // 仅在云端
    }

    /// 去掉扩展名的显示名
    var displayName: String {
        (name as NSString).deletingPathExtension
    }
}

enum MediaKind {
    /// 常见视频扩展名。和 SenPlayer 一样，不依赖 UTType，
    /// 避免个别容器被系统判定为未知类型而漏掉。
    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "m4v", "flv", "webm", "wmv",
        "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "rmvb", "rm",
        "3gp", "ogv", "asf", "divx", "f4v", "m2v", "iso",
    ]

    static let audioExtensions: Set<String> = [
        "mp3", "aac", "flac", "wav", "m4a", "ogg", "opus", "wma",
        "ape", "alac", "aiff", "dsf", "dff",
    ]

    static func isPlayable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext) || audioExtensions.contains(ext)
    }
}
