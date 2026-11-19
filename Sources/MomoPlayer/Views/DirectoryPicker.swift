import SwiftUI
import UniformTypeIdentifiers

/// 系统文件选择器。
///
/// 用 `UIDocumentPickerViewController` 而不是 SwiftUI 的 `fileImporter`：
/// 前者能返回可用于长期访问的 security-scoped URL，后者拿到的权限容易失效。
///
/// 允许同时选文件夹和单个视频文件 —— 只给 `.folder` 的话，
/// 用户想把某个视频单独加进来就选不了。
struct DirectoryPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // 文件夹 + 常见视频类型，两者都能选
        var types: [UTType] = [.folder]
        types.append(contentsOf: [
            .movie, .video, .mpeg4Movie, .quickTimeMovie, .audio, .mp3, .mpeg2Video,
        ])
        // 去重，避免重复类型导致系统报错
        var seen = Set<String>()
        let unique = types.filter { seen.insert($0.identifier).inserted }

        Log.event("picker", "创建选择器，类型: \(unique.map(\.identifier).joined(separator: ","))")

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: unique,
            asCopy: false
        )
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            Log.event("picker", "选中 \(urls.count) 项")
            guard let url = urls.first else {
                Log.event("picker", "返回为空")
                return
            }
            Log.event("picker", "url=\(url.path)")
            Log.event("picker", "scheme=\(url.scheme ?? "nil") isFileURL=\(url.isFileURL)")

            // 立刻验证权限，把结果记下来
            let ok = url.startAccessingSecurityScopedResource()
            Log.event("picker", "startAccessing = \(ok)")
            if ok {
                url.stopAccessingSecurityScopedResource()
            }

            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Log.event("picker", "用户取消")
        }
    }
}
