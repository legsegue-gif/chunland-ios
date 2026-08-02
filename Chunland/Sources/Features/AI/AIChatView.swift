import SwiftUI
import ChunlandCore
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// 可复用的聊天主体（消息列表 + 输入栏 + 图片输入 + HITL 确认）。
// 由「AI 助手」tab（AIView，外包抽屉/导航栏）与各页面唤起的底部面板（AIChatSheet）共用。
// 不含导航栏 / 历史抽屉 / 会话生命周期（bootstrap / startScopedConversation）—— 那些由外层负责。
struct AIChatView: View {
    @EnvironmentObject var orchestrator: AIOrchestrator
    @State private var aiReport: AIReportItem?
    // 空态「立即配置」按钮的动作：tab 弹 AISetupSheet，页面面板自行处理。
    var onConfigure: () -> Void

    @State private var input = ""
    @FocusState private var inputFocused: Bool
    // 滚动仲裁：用户上滑看历史 → 停止自动跟底；滚回底部 / 自己发新消息 → 恢复跟随。
    // 没有它，流式期间每次 token 写回都会把用户硬拽回底部（聊天 UI 大忌）。
    @State private var autoFollow = true
    // 图片输入
    @State private var pendingImages: [PendingImage] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 空态与有消息态共用同一个滚动容器（与 ChatGPT / Claude / X 一致）——
                // 空态也是滚动容器，因此下拉手势随时能收起键盘，不存在"空态卡死"
                if !orchestrator.isConfigured {
                    emptyState
                } else if visibleMessages.isEmpty {
                    // 欢迎语是 View 层装饰（不进对话历史，避免模型把它当自己说过的话复读）
                    welcomeBlock
                } else {
                    messageContent
                }
            }
            // 下拉交互式收起键盘 —— 跟手、可回弹，和 iMessage 同一手感
            .scrollDismissesKeyboard(.interactively)
            // 用户往下拖（往旧消息方向滚）→ 停止跟底。simultaneousGesture 只旁听、不抢
            // ScrollView 自身手势；恢复跟随由底部锚点 onAppear（滚回底部）或发新消息触发。
            .simultaneousGesture(
                DragGesture().onChanged { v in
                    if v.translation.height > 12 { autoFollow = false }
                }
            )
            .onChange(of: orchestrator.messages.count) { _, _ in
                // 自己发的消息 → 强制恢复跟随（新一轮回复从头看）
                if orchestrator.messages.last?.role == "user" { autoFollow = true }
                guard autoFollow else { return }
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: orchestrator.isThinking) { _, _ in
                guard autoFollow else { return }
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // 流式 token 累积时 messages.count 不变 —— 监听末位 content 长度变化以跟随滚动
            .onChange(of: orchestrator.messages.last?.content?.count ?? 0) { _, _ in
                guard autoFollow else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            // 停跟期间右下角悬浮「回到底部」——点击恢复跟随
            .overlay(alignment: .bottomTrailing) {
                if !autoFollow {
                    Button {
                        autoFollow = true
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color(.systemGray4).opacity(0.6), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 10)
                    .accessibilityLabel("回到底部")
                }
            }
        }
        // ★ HITL 确认窗（aiAutoConfirm=false 时由 orchestrator.pendingIntent 触发）
        .confirmationDialog(
            orchestrator.pendingIntent?.summary ?? "",
            isPresented: Binding(
                get: { orchestrator.pendingIntent != nil },
                set: { if !$0 { orchestrator.cancelIntent() } }
            ),
            titleVisibility: .visible,
            presenting: orchestrator.pendingIntent
        ) { _ in
            Button("确认执行") { orchestrator.confirmIntent() }
            Button("取消", role: .cancel) { orchestrator.cancelIntent() }
        } message: { _ in
            Text("此操作会修改你的数据。")
        }
        // 输入栏吸附底部 —— 系统 keyboard avoidance 自动把它顶到键盘正上方
        .safeAreaInset(edge: .bottom) { inputBar }
        .sheet(item: $aiReport) { item in
            ReportSheet(targetType: .aiMessage, snapshot: item.text)
        }
    }

    // MARK: - Sub-views

    // 空对话态（未配置 / 已配置但还没发消息共用）。containerRelativeFrame 让它撑满
    // ScrollView 可视高度，Spacer 才能上下居中；高度不足时溢出可滚动，且仍是滚动容器 → 下拉收键盘
    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 40)
            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundStyle(Color.accentColor)
            Text("配置 AI 助手").font(.title2).bold()
            Text("请先在右上角设置你的 AI API Key，\n即可开始代购咨询。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("立即配置") { onConfigure() }
                .buttonStyle(.borderedProminent)
            Spacer(minLength: 40)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical)
    }

    // 用户可见消息（system / tool 帧不上屏）
    private var visibleMessages: [ChatMessage] {
        orchestrator.messages.filter { $0.role != "tool" && $0.role != "system" }
    }

    // 会话为空时的欢迎语 —— 视觉上与 assistant 消息同款（全宽左对齐）
    private var welcomeBlock: some View {
        Text(orchestrator.welcomeText)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 12)
    }

    private var messageContent: some View {
        LazyVStack(spacing: 12) {
            ForEach(visibleMessages) { msg in
                MessageBubble(message: msg, onReport: {
                    aiReport = AIReportItem(text: msg.content ?? "")
                })
                    .id(msg.id)
            }
            if orchestrator.isThinking {
                ThinkingBubble()
            }
            // 底部锚点兼「已在底部」哨兵：滚回底部（LazyVStack 实例化它）→ 恢复跟随
            Color.clear.frame(height: 1).id("bottom")
                .onAppear { autoFollow = true }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var inputBar: some View {
        // 悬浮圆角输入栏（对齐 ChatGPT / X：胶囊 + 实心圆发送钮）。leading 是 + 图片入口。
        VStack(spacing: 8) {
            // 待发图片横排预览（带删除）
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingImages) { pendingThumbnail($0) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
            }
            HStack(alignment: .center, spacing: 4) {
                plusButton
                // 多行输入：return 键作换行（对齐 ChatGPT / Claude / X）。
                // 不设 .submitLabel(.send) —— axis:.vertical 下 return 固定插入换行、
                // onSubmit 永不触发，设了只会让键帽误显成"发送"。发送只走右侧圆钮。
                TextField("问我想买什么…", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.vertical, 10)

                sendOrStopButton
                    .padding(.trailing, 6)
            }
            .padding(.leading, 4)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.systemGray6))
            )
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
        .photosPicker(isPresented: $showPhotos, selection: $photoItems,
                      maxSelectionCount: 4, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { addImage($0) }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { handleFileImport($0) }
        .onChange(of: photoItems) { _, items in loadPhotoItems(items) }
    }

    // + 图片入口（拍照 / 相册 / 文件）；满 4 张禁用
    private var plusButton: some View {
        Menu {
            Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
            Button { showPhotos = true } label: { Label("相册", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("文件", systemImage: "folder") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(pendingImages.count >= 4 ? Color(.systemGray3) : .secondary)
                .frame(width: 34, height: 34)
        }
        .disabled(pendingImages.count >= 4)
    }

    private func pendingThumbnail(_ img: PendingImage) -> some View {
        Image(uiImage: img.image)
            .resizable()
            .scaledToFill()
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Button {
                    pendingImages.removeAll { $0.id == img.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white, .black.opacity(0.55))
                }
                .offset(x: 5, y: -5)
            }
    }

    // MARK: - 图片采集

    private func addImage(_ ui: UIImage) {
        guard pendingImages.count < 4, let p = ImageEncoding.makePending(from: ui) else { return }
        pendingImages.append(p)
    }

    private func loadPhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items where pendingImages.count < 4 {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    addImage(ui)
                }
            }
            photoItems = []
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls where pendingImages.count < 4 {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url), let ui = UIImage(data: data) {
                addImage(ui)
            }
        }
    }

    // 生成中 → 实心圆停止按钮（点击中断）；否则 → 发送箭头钮
    @ViewBuilder
    private var sendOrStopButton: some View {
        if orchestrator.isResponding {
            Button {
                orchestrator.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor)
                    .clipShape(Circle())
            }
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(canSend ? .white : Color(.systemGray))
                    .frame(width: 32, height: 32)
                    .background(canSend ? Color.accentColor : Color(.systemGray4))
                    .clipShape(Circle())
            }
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        (!input.trimmingCharacters(in: .whitespaces).isEmpty || !pendingImages.isEmpty)
            && !orchestrator.isResponding
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespaces)
        let imgs = pendingImages.map(\.dataURL)
        guard !text.isEmpty || !imgs.isEmpty, !orchestrator.isResponding else { return }
        input = ""
        pendingImages = []
        inputFocused = false          // 发送即收键盘，生成中键盘保持隐藏（对齐三家）
        Task { await orchestrator.send(text, images: imgs) }
    }
}

// MARK: - Message Bubble

private struct AIReportItem: Identifiable {
    let id = UUID()
    let text: String
}

private struct MessageBubble: View {
    let message: ChatMessage
    var onReport: (() -> Void)? = nil

    var body: some View {
        if message.role == "user" {
            userBubble
        } else {
            assistantBlock
        }
    }

    // user：靠右蓝气泡 + 头像
    private var userBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                // 已发图片（多图各自一张缩略图，靠右）
                if let images = message.images, !images.isEmpty {
                    ForEach(images, id: \.self) { url in
                        if let ui = ImageEncoding.decode(url) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: 200, maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                if let content = message.content, !content.isEmpty {
                    Text(content)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .cornerRadius(16)
                        .textSelection(.enabled)
                }
            }
            Image(systemName: "person.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    // assistant：全宽左对齐纯文本，无背景无头像（对齐 ChatGPT / Claude / X）
    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 模型思考过程（该 endpoint 支持 reasoning_content 时显示）
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ThinkingPanel(reasoning: reasoning)
            }

            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                // tool 调用指示器 —— 保留小灰底 chip
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                    Text(toolCalls.map { friendlyToolName($0.function.name) }.joined(separator: "、"))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
                .cornerRadius(12)
            } else if let content = message.content, !content.isEmpty {
                // LLM 输出天然是 markdown —— 轻量块级渲染（user 气泡仍纯文本，用户输入不解析）
                MarkdownText(text: content)
                    .foregroundStyle(.primary)
                // 举报入口：显式低调按钮。不用 .contextMenu —— 长按会被上面 textSelection 抢走、点不出来。
                if onReport != nil {
                    Button {
                        onReport?()
                    } label: {
                        Label("举报", systemImage: "flag")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func friendlyToolName(_ name: String) -> String {
        AIToolName(rawValue: name)?.friendlyName ?? name
    }
}

// 可折叠的"思考过程"面板 —— 仅当 message.reasoning 非空时由 MessageBubble 调用
private struct ThinkingPanel: View {
    let reasoning: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption2)
                    Text("思考过程")
                        .font(.caption)
                        .bold()
                    Text("(\(reasoning.count) 字)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                Text(reasoning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color(.systemGray6).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(.systemGray4).opacity(0.5), lineWidth: 0.5)
        )
        .cornerRadius(12)
    }
}

private struct ThinkingBubble: View {
    @State private var dotCount = 1
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Circle())
            Text(String(repeating: "•", count: dotCount))
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(16)
            Spacer(minLength: 60)
        }
        .onReceive(timer) { _ in dotCount = dotCount % 3 + 1 }
    }
}
