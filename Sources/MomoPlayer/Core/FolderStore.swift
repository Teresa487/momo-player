import Foundation

/// 记住用户选过的目录。
///
/// 关键点：security-scoped URL 只在当前进程内有效，App 重启后必须重新授权。
/// 正确做法是把 URL 转成 bookmark 持久化，下次取回时先 resolve 再
/// startAccessing —— 这就是 SenPlayer 里 `bookmarkData` 的用途。
struct FolderStore {
    private static let key = "momo.rootBookmarks"

    struct Entry: Codable, Identifiable {
        var id: String { path }
        let path: String
        let bookmark: Data
        let addedAt: Date
    }

    static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [Entry]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 新增或更新一个目录
    @discardableResult
    static func add(_ url: URL) -> Bool {
        // 生成 bookmark 的瞬间必须已经持有访问权限
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var list = load()
            list.removeAll { $0.path == url.path }
            list.append(Entry(path: url.path, bookmark: data, addedAt: Date()))
            save(list)
            Log.event("store", "已保存目录 \(url.path)，共 \(list.count) 个")
            return true
        } catch {
            Log.event("store", "生成 bookmark 失败: \(error.localizedDescription)")
            return false
        }
    }

    static func remove(_ path: String) {
        var list = load()
        list.removeAll { $0.path == path }
        save(list)
        Log.event("store", "移除目录 \(path)，剩余 \(list.count) 个")
    }

    /// 把 bookmark 还原成可用 URL，并已开启安全访问。
    /// 调用方用完后必须调用 `stopAccess`。
    static func resolve(_ entry: Entry) -> (URL, Bool)? {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: entry.bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            // stale 说明 bookmark 过期（比如目录被移动），需要重新授权
            if stale {
                Log.event("store", "bookmark 已过期: \(entry.path)")
            }
            let ok = url.startAccessingSecurityScopedResource()
            Log.event("store", "还原 \(entry.path) 访问权限=\(ok) stale=\(stale)")
            return (url, ok)
        } catch {
            Log.event("store", "还原 bookmark 失败 \(entry.path): \(error.localizedDescription)")
            return nil
        }
    }
}
