import SwiftUI
import UIKit

// UIActivityViewController 的手动包装 —— List 行上的 ShareLink 在 iPad 实测会弹出即收，换手动锚定解决。
// 用法：挂在任意 View 的 .background 上，配合一个 Bool Binding 触发。
struct ActivityShareView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let items: [Any]

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented, uiViewController.presentedViewController == nil else { return }
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        activityVC.completionWithItemsHandler = { _, _, _, _ in
            isPresented = false
        }
        // iPad 强制走 popover，锚定到本 host controller 自己的 view
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = uiViewController.view
            popover.sourceRect = CGRect(x: uiViewController.view.bounds.midX,
                                         y: uiViewController.view.bounds.midY,
                                         width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        uiViewController.present(activityVC, animated: true)
    }
}
