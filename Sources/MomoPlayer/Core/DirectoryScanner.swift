import Foundation

/// 扫描用户在「文件」里选中的目录。
///
/// 两个关键点，直接决定列表是否完整：
/// 1. 必须持有 security-scoped 权限，否则读取会在中途静默失败；
/// 2. 递归枚举并等全部收集完再返回，不能边扫描边刷新 UI。
enum DirectoryScanner {
    enum ScanError: LocalizedError {
        case permissionDenied
        case notDirectory

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "没有访问该文件夹的权限，请重新选择"
            case .notDirectory:
                return "选择的路径不是文件夹"
            }
        }
    }

    /// 递归扫描目录，返回全部可播放文件。
    /// - Parameter triggerCloudDownload: 遇到仅在云端的文件时是否触发下载
    static func scan(
        _ directory: URL,
        triggerCloudDownload: Bool = true
    ) async throws -> [MediaItem] {
        // security-scoped 权限必须成对使用
        let scoped = directory.startAccessingSecurityScopedResource()
        defer {
            if scoped { directory.stopAccessingSecurityScopedResource() }
        }

        // 没拿到权限就别继续了，否则枚举会返回空数组而非报错
        if !scoped {
            // 沙盒内目录（Documents 等）本来就不需要授权，这里放行
            let inSandbox = directory.path.contains(NSHomeDirectory())
            if !inSandbox {
                throw ScanError.permissionDenied
            }
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw ScanError.notDirectory
        }

        return await withCheckedContinuation { continuation in
            // 扫描放到后台队列，避免大目录卡住主线程
            DispatchQueue.global(qos: .userInitiated).async {
                let items = enumerateAll(directory, triggerCloudDownload: triggerCloudDownload)
                continuation.resume(returning: items)
            }
        }
    }

    private static func enumerateAll(
        _ directory: URL,
        triggerCloudDownload: Bool
    ) -> [MediaItem] {
        let fm = FileManager.default

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .nameKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                // 单个文件读失败不能中断整体扫描
                print("[scan] 跳过 \(url.lastPathComponent): \(error.localizedDescription)")
                return true
            }
        ) else {
            return []
        }

        var result: [MediaItem] = []

        for case let fileURL as URL in enumerator {
            guard MediaKind.isPlayable(fileURL) else { continue }

            let values = try? fileURL.resourceValues(forKeys: Set(keys))

            // 只要普通文件，跳过目录或特殊文件
            if let regular = values?.isRegularFile, !regular { continue }

            var status: MediaItem.CloudStatus = .current

            if values?.isUbiquitousItem == true {
                switch values?.ubiquitousItemDownloadingStatus {
                case .current:
                    status = .current
                case .downloaded:
                    status = .current
                case .notDownloaded:
                    status = .notDownloaded
                    // 云端未下载的文件读不出内容，先触发下载
                    if triggerCloudDownload {
                        try? fm.startDownloadingUbiquitousItem(at: fileURL)
                        status = .downloading
                    }
                default:
                    status = .notDownloaded
                }
            }

            result.append(MediaItem(url: fileURL, name: fileURL.lastPathComponent, cloudStatus: status))
        }

        // 按名称自然排序，第 2 集排在 第 10 集 前面
        result.sort { a, b in
            a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        return result
    }
}
