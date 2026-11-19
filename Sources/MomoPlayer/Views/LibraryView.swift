import SwiftUI
import UniformTypeIdentifiers

/// 媒体库：选目录或单个文件、列出可播放项、点开播放
struct LibraryView: View {
    @State private var items: [MediaItem] = []
    @State private var folderURL: URL?
    @State private var scanning = false
    @State private var errorText: String?
    @State private var showingPicker = false
    @State private var playing: MediaItem?
    @State private var showLog = false

    var body: some View {
        NavigationStack {
            Group {
                if scanning {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在扫描……")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPicker = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 14) {
                        if folderURL != nil {
                            Button("刷新") { Task { await rescan() } }
                        }
                        // 日志入口：出问题时能直接看到发生了什么
                        Button {
                            showLog = true
                        } label: {
                            Image(systemName: "ladybug")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPicker) {
                DirectoryPicker { url in
                    Task { await load(url) }
                }
            }
            .sheet(isPresented: $showLog) {
                LogView()
            }
            .fullScreenCover(item: $playing) { item in
                PlayerView(item: item)
                    .ignoresSafeArea()
            }
            .alert("出错了", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private var title: String {
        folderURL?.lastPathComponent ?? "MomoPlayer"
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 62))
                .foregroundStyle(.tint)
            Text("选择一个文件夹")
                .font(.headline)
            Text("选好后会递归列出里面所有可播放的文件，\n包括子目录。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingPicker = true
            } label: {
                Text("选择").padding(.horizontal, 22).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)

            Button {
                showLog = true
            } label: {
                Label("查看日志", systemImage: "ladybug")
                    .font(.footnote)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        List(items) { item in
            Button {
                Log.event("player", "点击播放: \(item.url.path)")
                playing = item
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon(for: item))
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if item.cloudStatus == .downloading {
                            Text("云端文件，正在下载")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
    }

    private func icon(for item: MediaItem) -> String {
        MediaKind.audioExtensions.contains(item.url.pathExtension.lowercased())
            ? "music.note"
            : "film"
    }

    // MARK: - 加载

    private func load(_ url: URL) async {
        Log.event("scan", "=== 新选择: \(url.path) ===")
        folderURL = url

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        Log.event("scan", "exists=\(exists) isDir=\(isDir.boolValue)")

        await rescan()
    }

    private func rescan() async {
        guard let url = folderURL else { return }
        scanning = true
        defer { scanning = false }
        do {
            let found = try await DirectoryScanner.scan(url)
            items = found
            Log.event("scan", "扫描完成，共 \(found.count) 项")
            if found.isEmpty {
                errorText = "这个目录里没有找到可播放的音视频文件"
            }
        } catch {
            Log.event("scan", "扫描失败: \(error.localizedDescription)")
            errorText = error.localizedDescription
            items = []
        }
    }
}

/// 日志查看页
struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if lines.isEmpty {
                        Text("暂无日志").foregroundStyle(.secondary)
                    }
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
                    Button("清空") {
                        Log.clear()
                        lines = []
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                lines = Log.snapshot()
            }
        }
    }
}
