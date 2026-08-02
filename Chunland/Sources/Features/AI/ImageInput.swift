import SwiftUI
import UIKit

// MARK: - 待发送图片附件（Phase 2）

struct PendingImage: Identifiable, Equatable {
    let id = UUID()
    let image: UIImage      // 已压缩的图（缩略图预览 + 发出后回显都用它）
    let dataURL: String     // "data:image/jpeg;base64,…"，直接进 OpenAI vision content

    static func == (l: PendingImage, r: PendingImage) -> Bool { l.id == r.id }
}

// MARK: - 图片编码（压缩 / 缩放 / base64）

enum ImageEncoding {
    static let maxDimension: CGFloat = 1024   // 最长边上限，控制 base64 体积
    static let jpegQuality: CGFloat = 0.7

    /// 缩放 + jpeg 压缩 + base64，产出可直接发送的 PendingImage
    static func makePending(from image: UIImage) -> PendingImage? {
        let scaled = scaleDown(image, maxDim: maxDimension)
        guard let jpeg = scaled.jpegData(compressionQuality: jpegQuality) else { return nil }
        let url = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        return PendingImage(image: scaled, dataURL: url)
    }

    static func scaleDown(_ image: UIImage, maxDim: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDim, longest > 0 else { return image }
        let scale = maxDim / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// 从 data URL（或纯 base64）解码出 UIImage —— MessageBubble 回显已发图用
    static func decode(_ dataURL: String) -> UIImage? {
        let base64 = dataURL.contains(",") ? String(dataURL.split(separator: ",").last ?? "") : dataURL
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - 相机（UIImagePickerController 包装；模拟器无相机，需真机）

struct CameraPicker: UIViewControllerRepresentable {
    var onPicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onPicked(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
