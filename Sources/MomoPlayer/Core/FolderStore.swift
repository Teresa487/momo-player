import Foundation

/// 记住用户选过的目录。
///
/// security-scoped URL 只在当前进程内有效，App 重启后必须重新授权。
/// 做法是把 URL 转成 bookmark 持久化，下次取回时先 resolve 再
/// startAccessing —— 与 SenPlayer 用 `bookmarkData` 的思路一致。
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
            Log.event("store", "UserDefaults 里没有 \(key)")
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
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        Log.event("store", "添加 \(url.path) scoped=\(scoped)")

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

    /// 把 bookmark 还原成可用 URL。返回的 URL 已开启安全访问，
    /// 调用方用完必须 stopAccess。
    static func resolve(_ entry: Entry) -> (URL, Bool)? {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: entry.bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let ok = url.startAccessingSecurityScopedResource()
            Log.event("store", "还原 \(entry.path) 权限=\(ok) stale=\(stale)")
            // stale 说明 bookmark 需重建，顺手更新
            if stale, ok {
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
            return (url, ok)
        } catch {
            Log.event("store", "还原失败 \(entry.path): \(error.localizedDescription)")
            return nil
        }
    }
}
