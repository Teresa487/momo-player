import Foundation
import os

/// 全链路日志。统一走这里，方便在 Xcode 控制台或「日志」App 里过滤。
enum Log {
    private static let subsystem = "com.momo.player"

    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let picker = Logger(subsystem: subsystem, category: "picker")
    static let player = Logger(subsystem: subsystem, category: "player")

    /// 同时写进内存缓冲，界面上能直接看到最近日志，
    /// 免得用户还要连电脑看控制台。
    private static let lock = NSLock()
    private static var buffer: [String] = []

    static func event(_ category: String, _ message: String) {
        let line = "[\(category)] \(message)"
        lock.lock()
        buffer.append(line)
        if buffer.count > 300 { buffer.removeFirst(buffer.count - 300) }
        lock.unlock()
        print(line)
    }

    static func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    static func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }
}
