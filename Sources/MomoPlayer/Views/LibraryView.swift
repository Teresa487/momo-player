import SwiftUI
import UniformTypeIdentifiers

/// 媒体库：管理多个已添加的目录，浏览其中的视频
struct LibraryView: View {
    @State private var folders: [FolderStore.Entry] = []
    @State private var activeFolder: FolderStore.Entry?
    @State private var items: [MediaItem] = []
    @State private var provider: LocalFileProvider?
    @State private var monitor = DirectoryMonitor()
    @State private var loading = false
    @State private var errorText: String?
    /// 挂载成功后待打开的目录；sheet 收起前不能动列表，先记下来
    @State private var pendingMountPath: String?
    /// sheet 未收起时不能直接弹 alert，先存下来，等 onDismiss 再显示
    @State private var pendingErrorText: String?
    @State private var showingPicker = false
    @State private var playingIndex: PlayIndex?
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !folders.isEmpty { folderBar }
                content
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingPicker = true } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 16) {
                        Button { showLog = true } label: { Image(systemName: "ladybug") }
                        if let f = activeFolder {
                            Menu {
                                Button("刷新") { open(f) }
                                Button("移除此目录", role: .destructive) {
                                    FolderStore.remove(f.path)
                                    activeFolder = nil
                                    reloadFolders()
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPicker, onDismiss: afterPickerDismissed) {
                DirectoryPicker(
                    onPick: { url in mount(url) },
                    onFinish: { showingPicker = false }
                )
            }
            .sheet(isPresented: $showLog) { LogView() }
            .fullScreenCover(item: $playingIndex) { p in
                PlayerView(playlist: items, startIndex: p.value).ignoresSafeArea()
            }
            .alert("出错了", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: { Text(errorText ?? "") }
            .onAppear(perform: reloadFolders)
        }
    }

    private var titleText: String {
        guard let f = activeFolder else { return "Momo" }
        return URL(fileURLWithPath: f.path).lastPathComponent
    }

    /// 目录切换条
    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(folders) { f in
                    let name = URL(fileURLWithPath: f.path).lastPathComponent
                    let active = activeFolder?.path == f.path
                    Button {
                        open(f)
                    } label: {
                        Text(name)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(active ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundStyle(active ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.secondary.opacity(0.05))
    }

    @ViewBuilder
    private var content: some View {
        if folders.isEmpty {
            emptyState
        } else if loading {
            VStack(spacing: 14) {
                ProgressView()
                Text("正在读取目录……").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "film").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("这个目录里没有可播放的文件").foregroundStyle(.secondary)
                Button("看日志") { showLog = true }.font(.footnote)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 62))
                .foregroundStyle(.tint)
            Text("添加一个文件夹").font(.headline)
            Text("添加后会记住这个位置，下次打开直接可用。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingPicker = true
            } label: {
                Text("选择文件夹").padding(.horizontal, 22).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Button {
                showLog = true
            } label: {
                Label("查看日志", systemImage: "ladybug").font(.footnote)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                Button {
                    Log.event("flow", "播放 [\(idx + 1)/\(items.count)] \(item.url.path)")
                    playingIndex = PlayIndex(value: idx)
                } label: {
                    row(item: item)
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(item: MediaItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: MediaKind.audioExtensions.contains(item.url.pathExtension.lowercased())
                  ? "music.note" : "film")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(1).foregroundStyle(.primary)
                if item.cloudStatus == .downloading {
                    Text("云端文件，正在下载").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }

    // MARK: - 动作

    /// 挂载一个新选中的目录。
    ///
    /// 只做保存并记下待打开的目录，不碰 `showingPicker`、不在这里 `open`：
    /// - sheet 的关闭由 `DirectoryPicker.onFinish` 统一处理
    /// - 打开目录会改列表状态，必须等 sheet 收起后做，否则和转场打架
    private func mount(_ url: URL) {
        Log.event("flow", "① 收到选择: \(url.path)")

        guard FolderStore.add(url) else {
            Log.event("flow", "② 保存失败，终止")
            pendingErrorText = "无法记住这个目录的权限，换个位置试试"
            return
        }
        Log.event("flow", "② 保存成功")
        pendingMountPath = url.path
    }

    /// sheet 收起后统一处理：先打开新挂载的目录，没有待办再看要不要弹错误
    private func afterPickerDismissed() {
        if let path = pendingMountPath {
            pendingMountPath = nil
            folders = FolderStore.load()
            if let entry = folders.first(where: { $0.path == path }) {
                Log.event("flow", "③ 准备打开")
                open(entry)
            } else {
                Log.event("flow", "③ 列表里找不到刚加的目录")
                pendingErrorText = "目录已保存，但读取不到，请稍后重试"
            }
        }

        // alert 要等 sheet 完全收起再弹，否则会挂在转场上被吞掉
        guard let text = pendingErrorText else { return }
        pendingErrorText = nil
        errorText = text
    }

    private func reloadFolders() {
        folders = FolderStore.load()
        Log.event("flow", "当前共有 \(folders.count) 个已保存目录")
        if let cur = activeFolder, folders.contains(where: { $0.path == cur.path }) {
            open(cur)
        } else if let first = folders.first {
            open(first)
        } else {
            activeFolder = nil
            items = []
            monitor.stop()
            provider?.close()
            provider = nil
        }
    }

    /// 自动刷新用：不显示加载态，避免列表闪烁
    private func rescanQuietly(_ entry: FolderStore.Entry) {
        guard let p = provider else { return }
        p.listPlayable { result in
            if case .success(let list) = result {
                items = list
                Log.event("flow", "自动刷新完成 \(list.count) 项")
            }
        }
    }

    private func open(_ entry: FolderStore.Entry) {
        activeFolder = entry
        loading = true
        items = []

        provider?.close()
        provider = nil

        guard let url = FolderStore.resolve(entry) else {
            loading = false
            errorText = "无法打开这个目录，请重新添加"
            return
        }

        // 权限统一由 provider 在自身生命周期内申请与释放，
        // resolve 不再自己 start，避免两边 start/stop 计数错配。
        let p = LocalFileProvider(root: url, needsScope: true)
        provider = p

        // startAccessing 返回 false 不代表失败（沙盒内目录本来就不用授权），
        // 真正读一下才能确定。读不到就是授权失效，让用户重新挂载。
        guard p.isReadable() else {
            loading = false
            p.close()
            provider = nil
            Log.event("flow", "目录不可访问，bookmark 可能已失效: \(url.path)")
            errorText = "这个目录的访问权限已失效，请重新添加"
            return
        }

        Log.event("flow", "开始读取 \(url.path)")

        // 目录里增删文件时自动刷新。已经在监听同一目录就不要重建，
        // 否则每次刷新都拆一次监听，事件会丢。
        if monitor.url?.path != url.path {
            monitor.start(url: url) { [self] in
                Log.event("flow", "监测到目录变化，自动刷新")
                rescanQuietly(entry)
            }
        }

        p.listPlayable { result in
            loading = false
            switch result {
            case .success(let list):
                items = list
                Log.event("flow", "读取完成 \(list.count) 项")
            case .failure(let error):
                errorText = error.localizedDescription
                Log.event("flow", "读取失败: \(error.localizedDescription)")
            }
        }
    }
}

/// fullScreenCover(item:) 要求 Identifiable，Int 本身不满足
private struct PlayIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

/// 日志页
struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty { Text("暂无日志").foregroundStyle(.secondary) }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清空") { Log.clear(); lines = [] }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { lines = Log.snapshot() }
        }
    }
}
