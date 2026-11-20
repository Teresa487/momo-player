import Foundation

/// 本地目录的文件提供者。
///
/// 参照 SenPlayer 用的 amosavian/FileProvider 的做法：把「一个根目录」包成
/// provider 对象，外部只管问它要目录内容，不用反复处理 security-scoped 权限。
///
/// 与之前实现的关键差别：
/// - 权限在 provider 生命周期内一直持有，不顺手中断
/// - 目录列举一开始就完成，全部拿到才回调，不做分批
final class LocalFileProvider {
    let root: URL
    /// 是否是外部目录（需要 security-scoped 授权）
    private let needsScope: Bool
    private var scoped = false
    private let queue = DispatchQueue(label: "momo.scan", qos: .userInitiated)

    init(root: URL, needsScope: Bool = true) {
        self.root = root
        self.needsScope = needsScope
        if needsScope {
            scoped = root.startAccessingSecurityScopedResource()
        }
        Log.event("provider", "创建 provider root=\(root.path) scoped=\(scoped)")
    }

    /// 释放权限，provider 不再可用
    func close() {
        if scoped {
            root.stopAccessingSecurityScopedResource()
            scoped = false
            Log.event("provider", "已释放 \(root.lastPathComponent) 的权限")
        }
    }

    deinit {
        close()
    }

    /// 递归列出全部可播放文件
    func listPlayable(
        triggerCloudDownload: Bool = true,
        completion: @escaping (Result<[MediaItem], Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let items = self.enumerate(triggerCloudDownload: triggerCloudDownload)
            DispatchQueue.main.async { completion(.success(items)) }
        }
    }

    private func enumerate(triggerCloudDownload: Bool) -> [MediaItem] {
        // 上游 FileProvider 的 LocalFileProvider 同样用 NSFileCoordinator 包住读取，
        // 避免和系统或其他 App 的读写撞车，iCloud 目录尤其需要。
        var result: [MediaItem] = []
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(readingItemAt: root, options: .withoutChanges, error: &coordError) { _ in
            result = self.walk(triggerCloudDownload: triggerCloudDownload)
        }
        if let e = coordError {
            Log.event("provider", "协调读取失败: \(e.localizedDescription)")
        }
        return result
    }

    private func walk(triggerCloudDownload: Bool) -> [MediaItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .nameKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileSizeKey,
        ]

        // 用 enumerator 递归，而不是 contentsOfDirectory 只取一层
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                Log.event("provider", "跳过 \(url.lastPathComponent): \(error.localizedDescription)")
                return true
            }
        ) else {
            Log.event("provider", "enumerator 创建失败")
            return []
        }

        var result: [MediaItem] = []
        var visited = 0
        var nonPlayable = 0

        for case let url as URL in en {
            visited += 1
            guard MediaKind.isPlayable(url) else {
                nonPlayable += 1
                continue
            }

            let rv = try? url.resourceValues(forKeys: Set(keys))

            if let isFile = rv?.isRegularFile, !isFile {
                continue
            }

            var status: MediaItem.CloudStatus = .current
            if rv?.isUbiquitousItem == true {
                switch rv?.ubiquitousItemDownloadingStatus {
                case .current, .downloaded:
                    status = .current
                case .notDownloaded:
                    if triggerCloudDownload {
                        do {
                            try fm.startDownloadingUbiquitousItem(at: url)
                            status = .downloading
                            Log.event("provider", "触发下载 \(url.lastPathComponent)")
                        } catch {
                            Log.event("provider", "下载失败 \(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    } else {
                        status = .notDownloaded
                    }
                default:
                    status = .notDownloaded
                }
            }

            result.append(MediaItem(url: url, name: url.lastPathComponent, cloudStatus: status))
        }

        Log.event("provider", "遍历 \(visited) 项，扩展名不符 \(nonPlayable)，可播放 \(result.count)")
        result.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return result
    }
}
