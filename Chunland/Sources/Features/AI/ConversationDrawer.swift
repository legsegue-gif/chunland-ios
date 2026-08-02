import SwiftUI
import ChunlandCore

// MARK: - 侧滑抽屉容器
//
// 把聊天界面包成底层，左侧叠加「历史会话」抽屉（仿 ChatGPT / Claude）。
// 入口策略：
//   · ☰ 按钮为主入口（确定性，必工作）—— 由外部 isOpen binding 驱动
//   · 左缘窄条捕获「右拖拉出」手势（增强，仅 22pt 宽，不挡聊天 ScrollView 主体）
//   · 遮罩 tap / 左拖关闭
// 用 .overlay 叠加而非 GeometryReader 包裹内容 —— 避免干扰聊天区的 safeArea / nav bar 布局。
struct ConversationDrawerContainer<Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder var content: () -> Content

    @GestureState private var drag: CGFloat = 0

    var body: some View {
        content()
            .overlay { drawerLayer }
    }

    private var drawerLayer: some View {
        GeometryReader { geo in
            let w = min(geo.size.width * 0.78, 360)
            let base: CGFloat = isOpen ? w : 0
            let shown = min(max(base + drag, 0), w)          // 当前露出宽度，clamp [0, w]
            let progress = w > 0 ? shown / w : 0

            ZStack(alignment: .leading) {
                // 遮罩：打开态可点击 / 左拖关闭
                Color.black
                    .opacity(0.35 * progress)
                    .ignoresSafeArea()
                    .allowsHitTesting(isOpen)
                    .onTapGesture { isOpen = false }
                    .gesture(closeGesture(width: w))

                // 抽屉本体：背景 material 铺满全屏（含状态栏 / home 区），
                // 但内容（header / list）守住 safe area，不被状态栏遮挡。
                ConversationListView(isOpen: $isOpen)
                    .frame(width: w)
                    .frame(maxHeight: .infinity)
                    .background {
                        Rectangle().fill(.regularMaterial).ignoresSafeArea()
                    }
                    .offset(x: shown - w)                    // 关闭 -w（移出左侧），打开 0

                // 左缘窄条：关闭态捕获右拖拉出，不覆盖聊天主体
                if !isOpen {
                    Color.clear
                        .frame(width: 22)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(edgeGesture(width: w))
                }
            }
            .animation(.snappy(duration: 0.28), value: isOpen)
        }
        // GeometryReader 本体留在 safe area 内 → 抽屉内容（header/list）自然避开状态栏；
        // 遮罩与 material 各自 ignoresSafeArea 向外铺满全屏。
    }

    // 关闭态：左缘右拖 → 超过阈值则打开
    private func edgeGesture(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($drag) { v, state, _ in state = max(0, v.translation.width) }
            .onEnded { v in
                if v.translation.width > w * 0.3 || v.predictedEndTranslation.width > w * 0.5 {
                    isOpen = true
                }
            }
    }

    // 打开态：遮罩左拖 → 超过阈值则关闭
    private func closeGesture(width w: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($drag) { v, state, _ in state = min(0, v.translation.width) }
            .onEnded { v in
                if v.translation.width < -w * 0.3 || v.predictedEndTranslation.width < -w * 0.5 {
                    isOpen = false
                }
            }
    }
}

// MARK: - 会话列表（抽屉内容）

struct ConversationListView: View {
    @Binding var isOpen: Bool
    @EnvironmentObject var orchestrator: AIOrchestrator
    @State private var showClearConfirm = false

    private var store: ConversationStore { .shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.conversations.isEmpty {
                emptyState
            } else {
                list
                Divider()
                clearAllButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack {
            Text("历史对话").font(.headline)
            Spacer()
            Button {
                orchestrator.startNewConversation()
                isOpen = false
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .medium))
            }
            .accessibilityLabel("新对话")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var list: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { conv in
                        row(conv)
                            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { delete(conv) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private func row(_ conv: AIConversation) -> some View {
        Button {
            orchestrator.loadConversation(id: conv.id)
            isOpen = false
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.title.isEmpty ? ConversationStore.untitled : conv.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(conv.updatedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                conv.id == store.activeId
                    ? Color.accentColor.opacity(0.14)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("还没有历史对话")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // 底部「清空全部对话」—— 危险操作，红色 + 二次确认
    private var clearAllButton: some View {
        Button(role: .destructive) {
            showClearConfirm = true
        } label: {
            Label("清空全部对话", systemImage: "trash")
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .tint(.red)
        .confirmationDialog("确认清空全部对话？",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("清空全部", role: .destructive) {
                orchestrator.deleteAllConversations()
                isOpen = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有历史对话将被永久删除，无法恢复。")
        }
    }

    // MARK: 删除（删当前会话则自动切到下一条 / 开新会话）

    private func delete(_ conv: AIConversation) {
        let wasActive = conv.id == store.activeId
        store.delete(conv)
        guard wasActive else { return }
        if let next = store.conversations.first {
            orchestrator.loadConversation(id: next.id)
        } else {
            orchestrator.startNewConversation()
        }
    }

    // MARK: 时间分组（store.conversations 已按 updatedAt 倒序，分组保序）

    private struct Group { let title: String; let items: [AIConversation] }

    private var groups: [Group] {
        let cal = Calendar.current
        var today: [AIConversation] = []
        var yesterday: [AIConversation] = []
        var earlier: [AIConversation] = []
        for c in store.conversations {
            if cal.isDateInToday(c.updatedAt) { today.append(c) }
            else if cal.isDateInYesterday(c.updatedAt) { yesterday.append(c) }
            else { earlier.append(c) }
        }
        var result: [Group] = []
        if !today.isEmpty { result.append(Group(title: "今天", items: today)) }
        if !yesterday.isEmpty { result.append(Group(title: "昨天", items: yesterday)) }
        if !earlier.isEmpty { result.append(Group(title: "更早", items: earlier)) }
        return result
    }
}
