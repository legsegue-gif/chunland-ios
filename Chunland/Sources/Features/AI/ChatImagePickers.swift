import SwiftUI
import UIKit

// MARK: - 拍照
//
// 用 UIImagePickerController 而不是 PhotosPicker：后者只能选已有照片，拍照必须走前者。
// 形态对齐 OpenMinis 的 CameraPicker（src/ios/Views/Chat/ChatInputBar.swift）。
//
// ⚠️ 模拟器没有相机 —— `isSourceTypeAvailable(.camera)` 为假时回落到相册，
// 否则在模拟器上会得到一个纯黑的空控制器，看起来像卡死。

struct CameraPicker: UIViewControllerRepresentable {
    /// 拍完回调原始 JPEG 数据；取消则不回调。
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
