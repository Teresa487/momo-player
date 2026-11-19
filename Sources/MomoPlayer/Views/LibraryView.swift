import SwiftUI
import UniformTypeIdentifiers

/// 媒体库：选目录、列出视频、点开播放
struct LibraryView: View {
    @State private var items: [MediaItem] = []
    @State private var folderURL: URL?
    @State private var scanning = false
    @State private var errorText: String?
    @State private var showingPicker = false
    @State private var playing: MediaItem?

    var body: some View {
        NavigationStack {
            Group {
                if scanning {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在扫描目录……")
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
                if folderURL != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("刷新") {
                            Task { await rescan() }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPicker) {
                DirectoryPicker { url in
                    Task { await load(url) }
                }
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
            Text("点右上角选择存放视频的目录，\n会递归列出里面所有可播放的文件。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingPicker = true
            } label: {
                Text("选择文件夹")
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        List(items) { item in
            Button {
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
        folderURL = url
        await rescan()
    }

    private func rescan() async {
        guard let url = folderURL else { return }
        scanning = true
        defer { scanning = false }
        do {
            items = try await DirectoryScanner.scan(url)
            if items.isEmpty {
                errorText = "这个目录里没有找到可播放的音视频文件"
            }
        } catch {
            errorText = error.localizedDescription
            items = []
        }
    }
}
