import Foundation

/// 记住用户选过的目录。
///
/// security-scoped URL 只在当前进程内有效，App 重启后必须重新授权。
/// 做法是把 URL 转成 bookmark 持久化，下次取回时先 resolve，再由
/// `LocalFileProvider` 统一申请并持有一段访问权限 —— 与 SenPlayer 用
/// `bookmarkData` 的思路一致。

struct FolderStore {
    private static let key = "momo.rootBookmarks"

    struct Entry: Codable, Identifiable {
        var id: String { path }
        let path: String
        let bookmark: Data
        let addedAt: Date
    }

    // MARK: - 读写

    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            Log.event("store", "还没保存过目录")
            return []
        }
        do {
            let list = try JSONDecoder().decode([Entry].self, from: data)
            Log.event("store", "读取到 \(list.count) 个目录")
            return list
        } catch {
            Log.event("store", "解析失败: \(error.localizedDescription)")
            return []
        }
    }

    static func save(_ list: [Entry]) {
        do {
            let data = try JSONEncoder().encode(list)
            UserDefaults.standard.set(data, forKey: key)
            // 立刻同步，避免进程被杀时丢数据
            UserDefaults.standard.synchronize()
            Log.event("store", "写入 \(list.count) 个目录，\(data.count) 字节")
        } catch {
            Log.event("store", "编码失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 增删

    /// 新增或更新一个目录。
    ///
    /// 注意不要用 .minimalBookmark —— 那个选项生成的 bookmark 不含
    /// 安全范围信息，iOS 上还原后拿不到访问权限。用默认选项即可。
    @discardableResult
    static func add(_ url: URL) -> Bool {
        // 生成 bookmark 的瞬间必须已经持有访问权限
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        Log.event("store", "添加 \(url.path) scoped=\(scoped)")

        // 对应 SenPlayer 的「仅支持挂载文件夹」：选择器声明了 .folder，
        // 但个别系统版本仍可能返回文件 URL，这里再校验一次。
        // resourceValues 拿不到时回退到 FileManager 判断，避免误拒合法目录。
        let isDir: Bool
        if let v = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
            isDir = v
        } else {
            var flag: ObjCBool = false
            isDir = FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
                && flag.boolValue
        }
        guard isDir else {
            Log.event("store", "不是文件夹，拒绝挂载: \(url.path)")
            return false
        }

        do {
            let data = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            Log.event("store", "bookmark 生成成功 \(data.count) 字节")

            var list = load()
            list.removeAll { $0.path == url.path }
            list.append(Entry(path: url.path, bookmark: data, addedAt: Date()))
            save(list)
            return true
        } catch {
            Log.event("store", "bookmark 生成失败: \(error.localizedDescription)")
            return false
        }
    }

    static func remove(_ path: String) {
        var list = load()
        list.removeAll { $0.path == path }
        save(list)
        Log.event("store", "移除 \(path)，剩余 \(list.count) 个")
    }

    /// 把 bookmark 还原成 URL。
    ///
    /// 这里**不**申请访问权限：权限由 `LocalFileProvider` 在自身生命周期内
    /// 持有，谁 start 谁 stop。以前这里 start 一次、provider 再按 `ok` 决定
    /// 要不要 start，两边会产生引用计数错配 —— 返回 true 时不 stop（泄漏），
    /// 返回 false 时 provider 又 start 一次（叠一层还是没权限）。
    ///
    /// 返回 nil 表示 bookmark 已彻底失效，调用方应引导用户重新挂载。
    static func resolve(_ entry: Entry) -> URL? {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: entry.bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            Log.event("store", "还原 \(entry.path) stale=\(stale)")

            // stale 说明 bookmark 需重建。重建同样需要权限，临时借一次。
            if stale {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                if let newData = try? url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    var list = load()
                    if let i = list.firstIndex(where: { $0.path == entry.path }) {
                        list[i] = Entry(path: entry.path, bookmark: newData, addedAt: entry.addedAt)
                        save(list)
                        Log.event("store", "已刷新过期的 bookmark")
                    }
                }
            }
            return url
        } catch {
            Log.event("store", "还原失败 \(entry.path): \(error.localizedDescription)")
            return nil
        }
    }
}
