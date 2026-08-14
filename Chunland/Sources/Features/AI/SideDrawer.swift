import SwiftUI

// MARK: - 跟手侧边抽屉
//
// 为什么不用 `.sheet`：sheet 是从底部升起的模态层，只能点按钮唤起 —— 没有
// 「从左边缘拖出来」这件事，也就没有跟手位移。OpenMinis 用 NavigationSplitView
// 拿到系统原生的边缘手势，但那要求侧栏位于导航根部；本项目的 AI 是 tab 内的一页，
// 把 SplitView 塞进 tab 会和 MainTabView 的三身份布局打架。
// 所以自绘：位移跟手、松手按「拖过半程或甩得够快」决定吸附方向。
//
// ⚠️ 只给 tab 主对话用，**不给页面 ✨ 的 sheet 用**：那层自己已有下拉关闭手势，
// 再叠一个右滑会互相抢；而且进店 ✨ 是 scoped 会话，本来就没有「历史列表」的概念。

struct SideDrawer<Content: View, Drawer: View>: View {

    @Binding var isOpen: Bool
    /// 抽屉宽度占屏幕的比例。留一截给主内容，用户才看得出「盖在上面」而不是换了页。
    var widthRatio: CGFloat = 0.82
    @ViewBuilder var content: () -> Content
    @ViewBuilder var drawer: () -> Drawer

    /// 拖动中的实时位移（0 = 关闭位）。与 isOpen 分开存，否则松手回弹会闪。
    @State private var dragX: CGFloat = 0

    /// 边缘起手区宽度。太窄了拖不出来，太宽了会吃掉内容区的横向滑动。
    private let edgeWidth: CGFloat = 20
    /// 甩动判定阈值（点/秒）。慢速拖动看位移，快速轻扫看速度 —— 只看位移的话，
    /// 快速小幅度轻扫会被判成「没拖够」而弹回，手感发滞。
    private let flickVelocity: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * widthRatio
            let offset = currentOffset(width: width)
            // 0（全关）→ 1（全开）。遮罩透明度与位移同步，拖到一半就是一半的暗度。
            let progress = (offset + width) / width

            ZStack(alignment: .leading) {
                content()

                if progress > 0.001 {
                    Color.black.opacity(0.35 * progress)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        // 拖遮罩也能关：手指已经在屏幕上时，还要求他去点一下才关很别扭
                        .gesture(dragGesture(width: width))
                }

                // 完全关闭时**不渲染**，而不是只把它 offset 到屏幕外：
                // 抽屉内容自带 NavigationStack（title/searchable/toolbar），留在视图树里
                // 它的 toolbar 会与宿主页面的合并 —— 表现是抽屉明明关着，顶部却挂着
                // 它的「关闭」按钮和搜索框。
                // 判据带上 dragX：手指一动就挂载，于是滑入过程照样跟手。
                if isOpen || dragX != 0 {
                    drawer()
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(Color(.systemBackground))
                        .offset(x: offset)
                        .gesture(dragGesture(width: width))
                }
            }
            // 左边缘起手区：只在关闭时挂，开着时由遮罩与抽屉自己处理手势
            .overlay(alignment: .leading) {
                if !isOpen {
                    Color.clear
                        .frame(width: edgeWidth)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(width: width))
                }
            }
        }
    }

    private func currentOffset(width: CGFloat) -> CGFloat {
        let base = isOpen ? 0 : -width
        return min(0, max(-width, base + dragX))
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                // 只吃横向意图：竖向为主时不动抽屉，否则列表滚动会被抽屉抢走
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                let translation = value.translation.width
                let velocity = value.predictedEndTranslation.width - translation
                let opened: Bool
                if abs(velocity) > flickVelocity {
                    opened = velocity > 0          // 甩的方向说了算
                } else {
                    opened = currentOffset(width: width) > -width / 2
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    dragX = 0
                    isOpen = opened
                }
            }
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            dragX = 0
            isOpen = false
        }
    }
}
