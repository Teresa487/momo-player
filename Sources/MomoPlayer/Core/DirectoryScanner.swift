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
    static func scan(
        _ directory: URL,
        triggerCloudDownload: Bool = true,
        keepAccess: Bool = false
    ) async throws -> [MediaItem] {
        Log.event("scan", "开始扫描: \(directory.path)")
        Log.event("scan", "isFileURL=\(directory.isFileURL) scheme=\(directory.scheme ?? "nil")")

        let scoped = directory.startAccessingSecurityScopedResource()
        Log.event("scan", "startAccessingSecurityScopedResource = \(scoped)")

        // 扫描期间释放权限；如果要保留（比如为了播放）就交给调用方
        defer {
            if scoped && !keepAccess {
                directory.stopAccessingSecurityScopedResource()
                Log.event("scan", "已释放 security-scoped 权限")
            }
        }

        if !scoped {
            let inSandbox = directory.path.contains(NSHomeDirectory())
            Log.event("scan", "未获授权，是否沙盒内路径: \(inSandbox)")
            if !inSandbox {
                throw ScanError.permissionDenied
            }
        }

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir)
        Log.event("scan", "exists=\(exists) isDirectory=\(isDir.boolValue)")

        guard exists, isDir.boolValue else {
            throw ScanError.notDirectory
        }

        return await withCheckedContinuation { continuation in
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
                Log.event("scan", "跳过 \(url.lastPathComponent): \(error.localizedDescription)")
                return true
            }
        ) else {
            Log.event("scan", "创建 enumerator 失败")
            return []
        }

        var result: [MediaItem] = []
        var total = 0
        var skippedByExt = 0

        for case let fileURL as URL in enumerator {
            total += 1
            guard MediaKind.isPlayable(fileURL) else {
                skippedByExt += 1
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: Set(keys))

            if let regular = values?.isRegularFile, !regular {
                Log.event("scan", "非普通文件，跳过: \(fileURL.lastPathComponent)")
                continue
            }

            var status: MediaItem.CloudStatus = .current

            if values?.isUbiquitousItem == true {
                switch values?.ubiquitousItemDownloadingStatus {
                case .current, .downloaded:
                    status = .current
                case .notDownloaded:
                    status = .notDownloaded
                    if triggerCloudDownload {
                        do {
                            try fm.startDownloadingUbiquitousItem(at: fileURL)
                            status = .downloading
                            Log.event("scan", "触发云端下载: \(fileURL.lastPathComponent)")
                        } catch {
                            Log.event("scan", "触发下载失败 \(fileURL.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                default:
                    status = .notDownloaded
                }
            }

            result.append(MediaItem(url: fileURL, name: fileURL.lastPathComponent, cloudStatus: status))
        }

        Log.event("scan", "遍历条目 \(total) 个，扩展名不符 \(skippedByExt) 个，可播放 \(result.count) 个")

        result.sort { a, b in
            a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        for item in result.prefix(10) {
            Log.event("scan", "  发现 \(item.name) [\(item.cloudStatus)]")
        }
        return result
    }
}
