import Foundation

/// 监听目录变化，有增删就回调。
///
/// 做法照 amosavian/FileProvider 的 LocalFileMonitor：
/// 用 DispatchSource 监听目录的 .write 事件，带 0.2 秒防抖，
/// 避免拷贝大量文件时被回调淹没。
final class DirectoryMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let queue = DispatchQueue(label: "momo.monitor", qos: .utility)
    private var lastFire: TimeInterval = 0
    private let debounce: TimeInterval = 0.2

    private(set) var url: URL?

    /// 开始监听。同一目录重复调用会先停掉旧的。
    func start(url: URL, onChange: @escaping () -> Void) {
        stop()

        let fd = url.withUnsafeFileSystemRepresentation { rep -> CInt in
            guard let rep else { return -1 }
            return open(rep, O_EVTONLY)
        }
        guard fd >= 0 else {
            Log.event("monitor", "无法监听 \(url.path)（open 失败）")
            return
        }

        descriptor = fd
        self.url = url

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            // 防抖：0.2 秒内的连续事件只处理一次
            if now < self.lastFire + self.debounce { return }
            self.lastFire = now

            // 改名或删除说明目录本身没了，通知后停止监听
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                Log.event("monitor", "目录被移动或删除，停止监听")
                DispatchQueue.main.async { onChange() }
                self.stop()
                return
            }

            Log.event("monitor", "目录有变化")
            DispatchQueue.main.async { onChange() }
        }

        src.setCancelHandler { [weak self] in
            if let fd = self?.descriptor, fd >= 0 {
                close(fd)
                self?.descriptor = -1
            }
        }

        source = src
        src.resume()
        Log.event("monitor", "开始监听 \(url.path)")
    }

    func stop() {
        source?.cancel()
        source = nil
        url = nil
    }

    deinit {
        stop()
    }
}
