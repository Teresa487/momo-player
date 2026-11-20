import SwiftUI
import UniformTypeIdentifiers

/// 媒体库：管理多个已添加的目录，浏览其中的视频
struct LibraryView: View {
    @State private var folders: [FolderStore.Entry] = []
    @State private var activeFolder: FolderStore.Entry?
    @State private var items: [MediaItem] = []
    @State private var provider: LocalFileProvider?
    @State private var loading = false
    @State private var errorText: String?
    @State private var showingPicker = false
    @State private var playing: MediaItem?
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
            .sheet(isPresented: $showingPicker) {
                DirectoryPicker { url in
                    Log.event("flow", "选中目录 \(url.path)")
                    if FolderStore.add(url) {
                        reloadFolders()
                        if let entry = FolderStore.load().first(where: { $0.path == url.path }) {
                            open(entry)
                        }
                    } else {
                        errorText = "无法记住这个目录的权限，换个位置试试"
                    }
                }
            }
            .sheet(isPresented: $showLog) { LogView() }
            .fullScreenCover(item: $playing) { item in
                PlayerView(item: item).ignoresSafeArea()
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
        List(items) { item in
            Button {
                Log.event("flow", "播放 \(item.url.path)")
                playing = item
            } label: {
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
        }
        .listStyle(.plain)
    }

    // MARK: - 动作

    private func reloadFolders() {
        folders = FolderStore.load()
        Log.event("flow", "已保存 \(folders.count) 个目录")
        if let cur = activeFolder, folders.contains(where: { $0.path == cur.path }) {
            open(cur)
        } else if let first = folders.first {
            open(first)
        } else {
            activeFolder = nil
            items = []
        }
    }

    private func open(_ entry: FolderStore.Entry) {
        activeFolder = entry
        loading = true
        items = []

        provider?.close()
        provider = nil

        guard let (url, ok) = FolderStore.resolve(entry) else {
            loading = false
            errorText = "无法打开这个目录，请重新添加"
            return
        }

        let p = LocalFileProvider(root: url, needsScope: !ok)
        provider = p
        Log.event("flow", "开始读取 \(url.path)")

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
