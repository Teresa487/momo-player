import SwiftUI
import UniformTypeIdentifiers

/// 系统文件夹选择器。
///
/// 用 `UIDocumentPickerViewController` 而不是 SwiftUI 的 `fileImporter`：
/// 前者能返回可用于长期访问的 security-scoped URL，后者拿到的权限容易失效。
///
/// 只能选文件夹：混入文件类型会让系统按「选文件」处理，
/// 选中文件夹时确定按钮不可用。
///
/// `UIDocumentPickerViewController` 选完会自己 dismiss（是它内部的 dismiss，
/// SwiftUI 收不到通知），所以这里必须显式回调 `onFinish`，
/// 由调用方把 `isPresented` 置回 false，否则会留一层空白 sheet 盖住界面。
struct DirectoryPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    /// 选中或取消都会调用，用于关闭 sheet
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // 只能是 .folder。混入 .movie 之类的文件类型后，系统会按「选择文件」
        // 处理，选中文件夹时「打开」按钮就是灰的，点不了。
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        Log.event("picker", "创建文件夹选择器")
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onFinish: () -> Void

        init(onPick: @escaping (URL) -> Void, onFinish: @escaping () -> Void) {
            self.onPick = onPick
            self.onFinish = onFinish
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            Log.event("picker", "选中 \(urls.count) 项")
            defer { onFinish() }

            guard let url = urls.first else {
                Log.event("picker", "返回为空")
                return
            }
            Log.event("picker", "url=\(url.path)")
            Log.event("picker", "scheme=\(url.scheme ?? "nil") isFileURL=\(url.isFileURL)")

            // 这里不要碰 startAccessing/stopAccessing。
            // 一旦 stop，后续生成 bookmark 时拿到的就不带安全范围信息，
            // 重启后无法还原。权限交给 FolderStore.add 独占处理。
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Log.event("picker", "用户取消")
            onFinish()
        }
    }
}
