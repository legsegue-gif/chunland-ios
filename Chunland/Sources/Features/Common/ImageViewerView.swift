import SwiftUI
import UIKit

// MARK: - 胶囊圆点分页指示器（Reddit 风格；商品图册与全屏看图器共用）

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? .white : .white.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.35), in: Capsule())
    }
}

// MARK: - 全屏看图器（Reddit 风格）

// 黑底翻页 + 双击/捏合缩放 + 未放大时下滑关闭（背景跟手渐隐）。
// 页码与调用方共享绑定：在看图器里翻到第几张，关闭后画廊停在同一张。
struct ImageViewerView: View {
    let urls: [String]
    @Binding var index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0
    @State private var isZoomed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(backgroundOpacity)

            TabView(selection: $index) {
                ForEach(urls.indices, id: \.self) { i in
                    ZoomableRemoteImage(urlString: urls[i], isActive: i == index, isZoomed: $isZoomed)
                        .ignoresSafeArea()
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .simultaneousGesture(dismissDrag)

            chrome
                .opacity(backgroundOpacity)
        }
        .statusBarHidden()
        .onChange(of: index) { isZoomed = false }   // 换页从 1x 开始（离开页由 updateUIView 重置）
    }

    // 顶部：关闭 + 页码计数；底部：胶囊圆点
    private var chrome: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                }
                Spacer()
                if urls.count > 1 {
                    Text("\(index + 1)/\(urls.count)")
                        .font(.subheadline).bold().monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.45), in: Capsule())
                }
            }
            .padding(.horizontal, 16)

            Spacer()

            if urls.count > 1 {
                PageDots(count: urls.count, current: index)
                    .padding(.bottom, 12)
            }
        }
    }

    // 未放大时、纵向主导且向下的拖动才进入关闭跟手（不与横向翻页抢手势）；
    // 松手过阈值即关，否则弹回。
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                guard !isZoomed else { return }
                let t = v.translation
                if dragOffset > 0 || (t.height > 0 && abs(t.height) > abs(t.width) * 1.2) {
                    dragOffset = max(t.height, 0)
                }
            }
            .onEnded { _ in
                if dragOffset > 120 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    private var backgroundOpacity: Double {
        max(1 - Double(dragOffset) / 600, 0.4)
    }
}

// MARK: - UIScrollView 缩放容器

// 缩放/平移/回弹走 UIScrollView 原生物理（不手写 MagnificationGesture 手势数学）。
// 未放大时 scroll view 无可滚内容、不消费手势 → 外层翻页和下滑关闭正常；
// 放大后平移由 scroll view 接管 → 不会误翻页。
private struct ZoomableRemoteImage: UIViewRepresentable {
    let urlString: String
    let isActive: Bool            // 当前显示页才回写 isZoomed；离开页重置缩放
    @Binding var isZoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.delegate = context.coordinator
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear

        let imageView = UIImageView(frame: scroll.bounds)
        imageView.contentMode = .scaleAspectFit
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
        ])
        context.coordinator.spinner = spinner

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        context.coordinator.load(urlString)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if !isActive, scroll.zoomScale > 1 {
            scroll.setZoomScale(1, animated: false)   // 离开页重置，回看时从 1x 开始
        }
        context.coordinator.load(urlString)
    }

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableRemoteImage
        weak var imageView: UIImageView?
        weak var spinner: UIActivityIndicatorView?
        var task: Task<Void, Never>?
        private var loadedURL: String?

        init(_ parent: ZoomableRemoteImage) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if parent.isActive {
                parent.isZoomed = scrollView.zoomScale > 1.01
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                // 以点击点为中心放大到 2.5x
                let point = gesture.location(in: imageView)
                let w = scroll.bounds.width / 2.5
                let h = scroll.bounds.height / 2.5
                scroll.zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h),
                            animated: true)
            }
        }

        func load(_ urlString: String) {
            guard loadedURL != urlString else { return }
            loadedURL = urlString
            task?.cancel()
            guard let url = URL(string: urlString) else {
                showFailure()
                return
            }
            task = Task { @MainActor [weak self] in
                var image: UIImage?
                if let (data, _) = try? await URLSession.shared.data(from: url) {
                    image = UIImage(data: data)
                }
                guard let self, !Task.isCancelled else { return }
                self.spinner?.stopAnimating()
                if let image {
                    self.imageView?.image = image
                } else {
                    self.showFailure()
                }
            }
        }

        private func showFailure() {
            spinner?.stopAnimating()
            imageView?.image = UIImage(systemName: "photo")
            imageView?.tintColor = .systemGray
            imageView?.contentMode = .center
        }
    }
}
