import SwiftUI
import PhotosUI
import ChunlandCore

// MARK: - 聊天主体（新会话模型）
//
// 与旧 AIChatView 的差别不在样子，在底下：消费 `AIChatSession` 的
// `ChatDisplayMessage`，因而拿到了旧实现没有的三样东西 ——
// 工具块（可回看、可展开）、系统提示消息（降级/压缩通知）、批量确认。
//
// 滚动仲裁沿用既有做法（上滑停跟 + 回底恢复 + 流式跟随）：
// 那套逻辑本身没问题，重写只会平白引入回归。

struct AgentChatView: View {

    @Bindable var session: AIChatSession
    /// 空态「去配置」的动作，由外层决定是弹 sheet 还是跳页面。
    var onConfigure: () -> Void = {}

    @State private var input = ""
    @FocusState private var inputFocused: Bool
    /// 待发送的图片。选中即落盘（MediaStore 内容寻址），这里只留引用 ——
    /// 绝不把字节拿在内存里等发送。
    @State private var pendingMedia: [MediaRef] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isAttaching = false
    // 三种图片来源各自的呈现开关（「+」菜单触发）
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    /// 上滑看历史时停止自动跟底 —— 没有它，流式期间每个 token 都会把用户拽回底部。
    @State private var autoFollow = true

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            composer
        }
        .sheet(item: confirmationBinding) { batch in
            MutationConfirmSheet(intents: batch.intents) { approved in
                session.resolveConfirmation(approved: approved)
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in
            Task { await attach(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                Task { await attach(data: data, mime: "image/jpeg") }
            }
            .ignoresSafeArea()
        }
        // 只收图片：三种来源最终都是一张图，收其它类型会让下游多出一条无人处理的分支
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await attach(fileURLs: urls) }
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.messages.isEmpty {
                        welcomeBlock
                    } else {
                        ForEach(session.messages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear {
                            // 底部锚点重新可见 = 用户滚回来了 → 恢复跟随
                            if !autoFollow { autoFollow = true }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            // 只旁听手势、不抢 ScrollView 自己的处理
            .simultaneousGesture(
                DragGesture().onChanged { value in
                    if value.translation.height > 12 { autoFollow = false }
                }
            )
            .onChange(of: session.messages.count) { _, _ in
                // 自己发的消息一定要跟到底
                if session.messages.last?.role == .user { autoFollow = true }
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: streamingTick) { _, _ in
                scrollToBottom(proxy, animated: false)
            }
            // 键盘弹出会把可视区压矮，而此时不会有新消息、也不会有流式增量 ——
            // 上面两个 onChange 都不触发，最后几行就被键盘盖住。
            // 延迟一拍是必须的：键盘动画约 0.25s，立刻滚动量算的是旧高度，仍然差一截。
            .onChange(of: inputFocused) { _, focused in
                guard focused else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    scrollToBottom(proxy, animated: true)
                }
            }
        }
    }

    /// 流式内容长度 —— 变化即触发跟随滚动。
    ///
    /// 直接观察最后一条消息的文本长度，而不是给每个块加 onChange：
    /// 块是引用类型，数量也在变，逐块观察反而更容易漏。
    private var streamingTick: Int {
        session.messages.last?.plainText.count ?? 0
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard autoFollow else { return }
        if animated {
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: - 单条消息

    @ViewBuilder
    private func messageRow(_ message: ChatDisplayMessage) -> some View {
        switch message.role {
        case .user:
            userBubble(message)
        case .assistant:
            assistantBody(message)
        case .system:
            systemNote(message)
        }
    }

    private func userBubble(_ message: ChatDisplayMessage) -> some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.media.isEmpty {
                    mediaStrip(message.media)
                }
                if !message.plainText.isEmpty {
                    Text(message.plainText)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func assistantBody(_ message: ChatDisplayMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(message.blocks) { block in
                switch block {
                case .text(let textBlock):
                    if textBlock.isThinking {
                        AgentThinkingBlockView(text: textBlock.text)
                    } else if !textBlock.text.isEmpty {
                        MarkdownText(text: textBlock.text)
                    }
                case .tool(let toolBlock):
                    AgentToolBlockView(block: toolBlock)
                }
            }

            if message.isStreaming && message.blocks.isEmpty {
                thinkingIndicator
            }

            if let error = message.error {
                errorNote(error, resumable: message.isResumable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 系统提示：降级通知、上下文压缩。
    ///
    /// 视觉上刻意弱化 —— 它是解释性的，不该和对话内容抢注意力。
    private func systemNote(_ message: ChatDisplayMessage) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption2)
            Text(message.plainText)
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }

    private func errorNote(_ text: String, resumable: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: resumable ? "arrow.clockwise.circle" : "exclamationmark.triangle")
                .font(.caption)
            Text(text)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(resumable ? Color.secondary : Color.red)
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("思考中…").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func mediaStrip(_ media: [MediaRef]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(media, id: \.id) { ref in
                    // 本地文件直接读，不走网络图片缓存那条链
                    if let image = UIImage(contentsOfFile: MediaStore.fileURL(for: ref).path) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .frame(maxHeight: 72)
    }

    // MARK: - 空态

    private var welcomeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            // 欢迎语是 View 层装饰 —— 绝不作为 assistant 消息进历史，
            // 否则模型会把它当成「自己说过的话」照抄（复读根因）
            Text(session.welcomeText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    // MARK: - 输入栏

    private var composer: some View {
        VStack(spacing: 6) {
            if !pendingMedia.isEmpty { pendingStrip }
            composerRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var pendingStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pendingMedia, id: \.id) { ref in
                    ZStack(alignment: .topTrailing) {
                        if let image = UIImage(contentsOfFile: MediaStore.fileURL(for: ref).path) {
                            Image(uiImage: image)
                                .resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Button {
                            pendingMedia.removeAll { $0.id == ref.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .padding(2)
                    }
                }
            }
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 输入区：文本框在上、工具行在下，整体包在一个圆角容器里。
    ///
    /// 按钮**在框内**而不是左右各挂一个 —— 左中右三段平级时，文本多行展开会把两侧按钮
    /// 顶得忽上忽下，且横向空间被按钮吃掉。容器内上下分行是 OpenMinis 的做法，
    /// 文本区永远占满宽度，工具行位置恒定。
    private var composerRow: some View {
        VStack(spacing: 6) {
            TextField("说点什么…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .textFieldStyle(.plain)
                .disabled(session.isResponding)

            HStack(spacing: 12) {
                attachmentMenuButton
                Spacer(minLength: 0)
                if session.isResponding {
                    Button {
                        session.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("停止")
                } else {
                    Button {
                        let text = input
                        let media = pendingMedia
                        input = ""
                        pendingMedia = []
                        session.send(text, media: media)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && pendingMedia.isEmpty)
                    .accessibilityLabel("发送")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// 「+」菜单：三种图片来源（对齐 OpenMinis 的 Take Photo / Choose Photos / Add File）。
    ///
    /// 三者最终都落成同一种东西 —— 一张图的 MediaRef，差别只在从哪儿拿字节。
    private var attachmentMenuButton: some View {
        Menu {
            Button {
                showCamera = true
            } label: {
                Label("拍照", systemImage: "camera")
            }
            Button {
                showPhotoPicker = true
            } label: {
                Label("从相册选择", systemImage: "photo.on.rectangle")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("从文件选择", systemImage: "doc")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .foregroundStyle(isAttaching ? .tertiary : .secondary)
        }
        .disabled(session.isResponding || isAttaching)
    }

    /// 选中的图片落盘换成引用。
    ///
    /// 内容寻址去重：同一张图重复选只占一份磁盘。
    /// 失败的那张静默跳过 —— 为一张图弹错误框打断输入不值得。
    private func attach(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isAttaching = true
        defer { isAttaching = false; photoItems = [] }

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            await appendMedia(data, mime: "image/jpeg")
        }
    }

    /// 拍照回来的字节。
    private func attach(data: Data, mime: String) async {
        isAttaching = true
        defer { isAttaching = false }
        await appendMedia(data, mime: mime)
    }

    /// 「从文件选择」回来的 URL。
    ///
    /// 文件在 app 沙盒外，**必须先 startAccessingSecurityScopedResource** 才读得到，
    /// 且要配对 stop —— 漏掉 stop 会泄漏安全作用域，多次选取后系统会拒绝新的访问。
    private func attach(fileURLs urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isAttaching = true
        defer { isAttaching = false }

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            await appendMedia(data, mime: Self.mime(for: url))
        }
    }

    /// 落盘换引用 + 去重。三种来源共用这一处，避免各写一遍存储调用。
    private func appendMedia(_ data: Data, mime: String) async {
        let store = MediaStore(db: AIRuntime.shared.database)
        guard let ref = try? await store.save(data, mime: mime) else { return }
        if !pendingMedia.contains(where: { $0.id == ref.id }) {
            pendingMedia.append(ref)
        }
    }

    private static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":          return "image/png"
        case "gif":          return "image/gif"
        case "webp":         return "image/webp"
        case "heic", "heif": return "image/heic"
        default:             return "image/jpeg"
        }
    }

    // MARK: - 确认框

    /// 把「待确认的一批」包成 Identifiable 供 `.sheet(item:)` 用。
    private var confirmationBinding: Binding<ConfirmBatch?> {
        Binding(
            get: { session.pendingConfirmation.map(ConfirmBatch.init) },
            set: { if $0 == nil { session.resolveConfirmation(approved: false) } }
        )
    }

    private struct ConfirmBatch: Identifiable {
        let intents: [AgentMutationIntent]
        var id: String { intents.map(\.id).joined(separator: "|") }

        init(_ intents: [AgentMutationIntent]) {
            self.intents = intents
        }
    }
}
