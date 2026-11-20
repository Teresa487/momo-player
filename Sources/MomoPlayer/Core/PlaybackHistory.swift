import Foundation

/// 播放进度记忆。
///
/// 按文件路径存：文件大小 + 修改时间做校验，文件换了就丢弃旧记录，
/// 避免同名不同片续播到错误位置。
struct PlaybackHistory {
    private static let key = "momo.playbackHistory"

    struct Record: Codable {
        let path: String
        let position: TimeInterval
        let duration: TimeInterval
        let size: Int64
        let modified: Date?
        let updatedAt: Date

        /// 看完的定义：剩不到 30 秒或超过 95%
        var isFinished: Bool {
            guard duration > 0 else { return false }
            return duration - position < 30 || position / duration > 0.95
        }
    }

    static func all() -> [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return map
    }

    static func record(for url: URL) -> Record? {
        all()[url.path]
    }

    /// 保存进度。位置太靠前（<5 秒）不记，避免误触留下垃圾记录。
    static func save(url: URL, position: TimeInterval, duration: TimeInterval) {
        guard duration > 0, position > 5 else { return }

        var map = all()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs?[.modificationDate] as? Date

        map[url.path] = Record(
            path: url.path,
            position: position,
            duration: duration,
            size: size,
            modified: modified,
            updatedAt: Date()
        )

        // 只保留最近 200 条，防止无限增长
        if map.count > 200 {
            let sorted = map.values.sorted { $0.updatedAt > $1.updatedAt }
            map = Dictionary(uniqueKeysWithValues: sorted.prefix(200).map { ($0.path, $0) })
        }

        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 取续播位置，文件已变则返回 nil
    static func resumePosition(for url: URL) -> TimeInterval? {
        guard let r = record(for: url), !r.isFinished else { return nil }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attrs?[.modificationDate] as? Date

        // 大小对不上说明换了文件
        if r.size > 0, size > 0, r.size != size {
            Log.event("history", "文件已变，丢弃进度: \(url.lastPathComponent)")
            return nil
        }
        if let a = r.modified, let b = modified, abs(a.timeIntervalSince(b)) > 2 {
            Log.event("history", "修改时间变了，丢弃进度: \(url.lastPathComponent)")
            return nil
        }
        Log.event("history", "续播 \(url.lastPathComponent) 从 \(Int(r.position))s")
        return r.position
    }

    static func remove(for url: URL) {
        var map = all()
        map.removeValue(forKey: url.path)
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
