import SwiftUI
import ChunlandCore

struct ProfileView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var profile: UserProfile?
    @State private var showReport = false
    @State private var isLoading = true
    @State private var showAISetup = false
    @State private var showLogoutConfirm = false
    @State private var showServerConfig = false
    @State private var rolesBusy = false
    @State private var roleToast: String?
    @State private var showOpenStore = false   // M1：开店表单（merchant 身份随店铺创建）
    @State private var showAIDebugLogShare = false
    @State private var aiDebugLogContent = ""  // 存 @State 而非每次 body 直接读文件 —— List 内联读文件不是
                                                 // SwiftUI 追踪的依赖，之前用「读文件 if let」清空后不刷新
    @State private var showStreamAnomalyShare = false
    @State private var streamAnomalyContent = ""  // P4 留证：系统 AI 代理层流异常记录（PhaseAuditor 命中才有）
    // 同上一坑：body 里 UserDefaults.standard 直读也不是追踪依赖，AISetupSheet / ServerConfigSheet
    // 保存后本页不刷新 —— 用 @AppStorage 声明成追踪属性，sheet 内写 UserDefaults 即触发重算
    /// AI 来源摘要。异步取自来源配置（库 + 安全存储），不是 UserDefaults ——
    /// 重写后配置不再落 UserDefaults，读旧 key 会永远显示一个冻结的旧值。
    @State private var aiSummary = ""
    #if DEBUG
    @AppStorage("serverBaseURL") private var serverURLDisplay = AppSettings.shared.defaultServerURL
    // 与系统 AI 代理模块 ProxyAnomalyLog 的文件名约定一致（刻意不 import 模块，路径即契约）
    private static var streamAnomalyLogURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ai-stream-anomaly.log")
    }
    #endif
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        NavigationStack {
            // 游客模式：未登录显示 CTA；登录后 List 子树重新挂载，其 .task 自动加载 profile。
            if auth.isLoggedIn {
            List {
                // User header —— 点头像卡进「账户」页（手机/邮箱/密码/注销都在里面）；身份切换器独立留在右侧
                Section {
                    HStack(spacing: 14) {
                        NavigationLink {
                            AccountView().environmentObject(auth)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 56))
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 6) {
                                    if let p = profile {
                                        Text(p.phone ?? p.email ?? "用户")
                                            .font(.title3.weight(.semibold))
                                        identityBadge
                                    } else if isLoading {
                                        ProgressView().scaleEffect(0.8)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        identitySwitcher   // 双身份切换：卡片内右侧图标（单身份不显示）
                    }
                    .padding(.vertical, 8)
                }

                // 单身份时显示「开通另一身份」入口（双身份切换在右上角 toolbar）
                openRoleSection


                // AI Config
                Section("AI 助手") {
                    Button {
                        showAISetup = true
                    } label: {
                        HStack {
                            Label("配置 AI API", systemImage: "sparkles")
                            Spacer()
                            Text(aiSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                // Shopping —— 仅消费者身份显示，与下方「代购设置」对称（activeIdentity 驱动布局二选一）
                if auth.activeIdentity == "consumer" {
                    Section("购物") {
                        NavigationLink(destination: OrderListView().environmentObject(auth)) {
                            Label("我的订单", systemImage: "list.bullet.clipboard")
                        }
                        if auth.isLoggedIn {
                            NavigationLink(destination: FollowsManageView()) {
                                Label("收藏与关注", systemImage: "heart")
                            }
                        }
                        NavigationLink(destination: AddressListView().environmentObject(auth)) {
                            Label("收货地址", systemImage: "location")
                        }
                    }
                }

                // Agent-only settings
                if auth.activeIdentity == "agent" {
                    Section("代购设置") {
                        NavigationLink(destination: AgentSettingsView().environmentObject(auth)) {
                            Label("接单状态与资料", systemImage: "person.text.rectangle")
                        }
                        NavigationLink(destination: SettlementsView()) {
                            Label("待结算 / 收益", systemImage: "yensign.circle")
                        }
                    }
                }

                // Developer settings —— 仅 Debug 构建可见；Release（App Store）锁定 prod 默认地址、不暴露切换入口
                #if DEBUG
                Section("开发者") {
                    Button { showServerConfig = true } label: {
                        HStack {
                            Label("服务器地址", systemImage: "server.rack")
                            Spacer()
                            Text(serverURLDisplay)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)

                    // AI 对话调试日志（完整请求/响应，见 AIDebugFileLog）—— 有内容才显示，避免分享一个空文件。
                    // 用 ActivityShareView 而非 ShareLink 分享，原因见该文件注释。
                    if !aiDebugLogContent.isEmpty {
                        Button {
                            showAIDebugLogShare = true
                        } label: {
                            Label("AI 调试日志", systemImage: "square.and.arrow.up")
                        }
                        .background(ActivityShareView(isPresented: $showAIDebugLogShare, items: [aiDebugLogContent]))

                        // 日志只追加不自动清空（见 AIDebugFileLog），手动清空入口
                        Button(role: .destructive) {
                            AIDebugFileLog.clear()
                            aiDebugLogContent = ""
                        } label: {
                            Label("清空 AI 调试日志", systemImage: "trash")
                        }
                    }

                    // 留证：系统 AI 代理层流异常记录（上游多段生成交错等，代理模块 PhaseAuditor 命中才写）。
                    // 按约定路径读文件、不 import 该模块（文件不存在时本入口自动隐藏）。
                    // 有记录才显示 —— 这一行出现本身就是「复现了」的信号。
                    if !streamAnomalyContent.isEmpty {
                        Button {
                            showStreamAnomalyShare = true
                        } label: {
                            Label("AI 流异常记录", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        .background(ActivityShareView(isPresented: $showStreamAnomalyShare, items: [streamAnomalyContent]))

                        Button(role: .destructive) {
                            if let url = Self.streamAnomalyLogURL { try? FileManager.default.removeItem(at: url) }
                            streamAnomalyContent = ""
                        } label: {
                            Label("清空 AI 流异常记录", systemImage: "trash")
                        }
                    }
                }
                #endif

                // 举报与反馈 + 黑名单 —— 始终可达的投诉举报通道（App Store 1.2 ③④ + 平台合规）
                Section {
                    Button {
                        showReport = true
                    } label: {
                        Label("举报与反馈", systemImage: "flag")
                    }
                    NavigationLink(destination: BlockedUsersView()) {
                        Label("黑名单", systemImage: "person.crop.circle.badge.xmark")
                    }
                }

                // About / 关于（协议 · 隐私 · 支持 · 开源 · 版本）
                aboutSection

                // Logout
                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .listStyle(.insetGrouped)
            // iPad（regular）限宽居中，避免设置项每行拉满宽屏过于稀疏
            .frame(maxWidth: hSizeClass == .regular ? 720 : .infinity)
            .frame(maxWidth: .infinity)
            .toolbar(.hidden, for: .navigationBar)   // 隐藏整条 navbar，header 卡片直接贴顶；切换图标已移入卡片内
            .task { await load() }
            #if DEBUG
            .onAppear {
                if let logURL = AIDebugFileLog.fileURL,
                   let content = try? String(contentsOf: logURL, encoding: .utf8) {
                    aiDebugLogContent = content
                }
                if let anomalyURL = Self.streamAnomalyLogURL,
                   let content = try? String(contentsOf: anomalyURL, encoding: .utf8) {
                    streamAnomalyContent = content
                }
            }
            #endif
            .sheet(isPresented: $showAISetup) {
                NavigationStack {
                    AIProviderSettingsView(config: AIRuntime.shared.config)
                }
            }
            // 关掉配置页回来要刷新 —— 用户很可能刚改过来源
            .task(id: showAISetup) {
                guard !showAISetup else { return }
                aiSummary = await AIRuntime.shared.preferredSourceLabel()
            }
            .sheet(isPresented: $showServerConfig) {
                ServerConfigSheet()
            }
            .sheet(isPresented: $showReport) {
                ReportSheet(targetType: .general)
            }
            .sheet(isPresented: $showOpenStore) {
                OpenStoreView()
                    .environmentObject(auth)
            }
            // 用 alert 而非 confirmationDialog：后者在 iPad（regular）渲染成 popover，
            // 锚点取「挂载它的视图」——挂在整个 List 上时气泡弹到列表顶部，而按钮在
            // 最底部，隔了一整屏，用户看不到就以为「点了退不出去」（实测）。
            // alert 两端都是居中模态，零锚点依赖；破坏性操作用居中确认也更难被忽略。
            // 同类坑参见 ActivityShareView（ShareLink 挂 List 行在 iPad 弹出即收）。
            .alert("确认退出登录？", isPresented: $showLogoutConfirm) {
                Button("退出登录", role: .destructive) {
                    Task {
                        await PushRegistrar.unregisterBeforeLogout() // 先解绑推送（此刻还持有登录态）
                        auth.logout()
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("提示", isPresented: Binding(
                get: { roleToast != nil },
                set: { if !$0 { roleToast = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(roleToast ?? "")
            }
            } else {
                // 游客态：CTA 居中，底部常驻关于/协议链接条（未登录也能访问，Apple 5.1.1）
                VStack(spacing: 0) {
                    GuestGate(title: "登录后查看「我的」",
                              message: "登录 / 注册后管理订单、地址与代购设置",
                              systemImage: "person.crop.circle")
                        .frame(maxHeight: .infinity)
                    aboutFooter
                }
            }
        }
    }

    // MARK: - 关于 / 合规入口

    // iOS 客户端开源地址（公开镜像 repo，自指）
    private let ossRepoURL = "https://github.com/legsegue-gif/chunland-ios"

    /// 静态页基址（用户协议 / 隐私政策 / 支持）—— 随当前服务器走，不硬编码域名。
    private var docsBase: String { AppSettings.shared.docsBaseURL }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    /// 登录态：List 内「关于」section（协议 / 隐私 / 支持 / 开源 / 版本）。
    @ViewBuilder
    private var aboutSection: some View {
        Section("关于") {
            aboutLink("用户协议", url: "\(docsBase)/terms")
            aboutLink("隐私政策", url: "\(docsBase)/privacy")
            aboutLink("帮助与支持", url: "\(docsBase)/support")
            aboutLink("项目开源地址", url: ossRepoURL)
            HStack {
                Text("版本")
                Spacer()
                Text(appVersion).foregroundStyle(.secondary)
            }
        }
    }

    /// 游客态：底部常驻链接条 —— 确保未登录也能访问协议 / 隐私（Apple 5.1.1 要求随时可达）。
    @ViewBuilder
    private var aboutFooter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                footerLink("用户协议", url: "\(docsBase)/terms")
                footerLink("隐私政策", url: "\(docsBase)/privacy")
                footerLink("帮助", url: "\(docsBase)/support")
            }
            footerLink("项目开源地址", url: ossRepoURL)
            Text("版本 \(appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func aboutLink(_ title: String, url: String) -> some View {
        if let u = URL(string: url) {
            Link(destination: u) {
                HStack {
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func footerLink(_ title: String, url: String) -> some View {
        if let u = URL(string: url) {
            Link(title, destination: u).font(.footnote)
        }
    }

    // MARK: - AI Config


    // MARK: - Identity

    /// 当前身份徽章 —— 全页唯一一处身份展示（切换在右上角 toolbar，开通在 openRoleSection）。
    private var identityBadge: some View {
        let (label, icon): (String, String) = switch auth.activeIdentity {
        case "agent":    ("代购人", "shippingbox.fill")
        case "merchant": ("商家", "storefront.fill")
        default:         ("消费者", "cart.fill")
        }
        return Label(label, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }

    /// 多身份切换器 —— header 卡片内右上角图标，点击弹身份菜单（当前身份打勾）；单身份不显示。
    @ViewBuilder
    private var identitySwitcher: some View {
        let owned = ["consumer", "agent", "merchant"].filter { auth.roles.contains($0) }
        if owned.count >= 2 {
            Menu {
                Picker("切换身份", selection: Binding(
                    get: { auth.activeIdentity },
                    set: { auth.switchIdentity(to: $0) }
                )) {
                    if owned.contains("consumer") { Label("消费者", systemImage: "cart").tag("consumer") }
                    if owned.contains("agent")    { Label("代购人", systemImage: "shippingbox").tag("agent") }
                    if owned.contains("merchant") { Label("商家", systemImage: "storefront").tag("merchant") }
                }
            } label: {
                Image(systemName: "arrow.2.squarepath")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("切换身份")
        }
    }

    /// 缺身份时显示开通入口；已有身份的切换在 header 卡片内右上角，此处不再出现。
    /// merchant 开通 = 开店流程（要建店铺实体），不走 /auth/roles。
    @ViewBuilder
    private var openRoleSection: some View {
        let hasConsumer = auth.roles.contains("consumer")
        let hasAgent = auth.roles.contains("agent")
        let hasMerchant = auth.roles.contains("merchant")
        if !(hasConsumer && hasAgent && hasMerchant) {
            Section("身份") {
                if !hasAgent {
                    Button { Task { await openRole("agent") } } label: {
                        identityRow(icon: "bag.badge.plus", title: "成为代购人")
                    }
                    .disabled(rolesBusy)
                }
                if !hasMerchant {
                    Button { showOpenStore = true } label: {
                        identityRow(icon: "storefront", title: "我要开店")
                    }
                    .disabled(rolesBusy)
                }
                if !hasConsumer {
                    Button { Task { await openRole("consumer") } } label: {
                        identityRow(icon: "cart.badge.plus", title: "开通消费者身份")
                    }
                    .disabled(rolesBusy)
                }
            }
        }
    }

    private func identityRow(icon: String, title: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if rolesBusy {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
    }

    private func openRole(_ role: String) async {
        rolesBusy = true
        defer { rolesBusy = false }
        do {
            try await auth.addRole(role)
            await load()   // 刷新 profile.roles
        } catch {
            roleToast = "开通失败：\(error.localizedDescription)"
        }
    }

    private func load() async {
        isLoading = true
        do {
            profile = try await AuthService.shared.me()
        } catch {}
        isLoading = false
    }
}

// MARK: - 设置 / 修改密码（已登录）

struct ChangePasswordView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    let hasPassword: Bool
    var onChanged: () -> Void = {}

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var loading = false
    @State private var error: String?
    @State private var done = false

    private var passwordsMatch: Bool { newPassword == confirm }
    private var canSubmit: Bool {
        newPassword.count >= 6 && passwordsMatch && (!hasPassword || !oldPassword.isEmpty)
    }

    var body: some View {
        Form {
            if hasPassword {
                Section("原密码") {
                    SecureField("当前密码", text: $oldPassword)
                }
            }

            Section {
                SecureField("新密码（至少 6 位）", text: $newPassword)
                SecureField("确认新密码", text: $confirm)
            } header: {
                Text(hasPassword ? "新密码" : "设置密码")
            } footer: {
                if !confirm.isEmpty && !passwordsMatch {
                    Text("两次输入不一致").foregroundStyle(.red)
                } else if !hasPassword {
                    Text("设置后可用手机号 / 邮箱 + 密码登录")
                }
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle(hasPassword ? "修改密码" : "设置密码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if loading { ProgressView() } else { Text("保存").bold() }
                }
                .disabled(loading || !canSubmit)
            }
        }
        .alert("已更新", isPresented: $done) {
            Button("好") { onChanged(); dismiss() }
        } message: {
            Text(hasPassword ? "密码已修改" : "密码已设置")
        }
    }

    private func submit() async {
        error = nil
        loading = true
        defer { loading = false }
        do {
            try await auth.setPassword(oldPassword: hasPassword ? oldPassword : nil, newPassword: newPassword)
            done = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 账户（手机/邮箱绑定 · 密码 · 注销）

struct AccountView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var profile: UserProfile?
    @State private var isLoading = true
    @State private var bindTarget: BindTarget?
    @State private var showDeleteConfirm = false
    @State private var error: String?

    private struct BindTarget: Identifiable { let channel: String; var id: String { channel } }

    var body: some View {
        List {
            if let p = profile {
                Section("账户") {
                    contactRow(title: "手机号", value: p.phone, channel: "sms")
                    contactRow(title: "邮箱", value: p.email, channel: "email")
                    NavigationLink {
                        ChangePasswordView(hasPassword: p.hasPassword) {
                            Task { await load() }   // 设密码后刷新「设置→修改」文案
                        }
                        .environmentObject(auth)
                    } label: {
                        Label(p.hasPassword ? "修改密码" : "设置密码", systemImage: "lock")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("注销账号", systemImage: "person.crop.circle.badge.xmark")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } footer: {
                    Text("注销后账号将无法登录，手机号 / 邮箱等个人信息会被清除，且不可恢复。订单等交易记录依法保留。")
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("账户")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $bindTarget) { t in
            BindContactView(channel: t.channel) { Task { await load() } }
                .environmentObject(auth)
        }
        .alert("确认注销账号？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("注销账号", role: .destructive) { Task { await deleteAccount() } }
        } message: {
            Text("此操作不可恢复：账号将无法登录，手机号 / 邮箱等个人信息会被清除。")
        }
    }

    @ViewBuilder
    private func contactRow(title: String, value: String?, channel: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let v = value, !v.isEmpty {
                Text(v).foregroundStyle(.secondary)
            } else {
                Button("绑定") { bindTarget = BindTarget(channel: channel) }
                    .font(.callout)
            }
        }
    }

    private func load() async {
        isLoading = true
        profile = try? await AuthService.shared.me()
        isLoading = false
    }

    private func deleteAccount() async {
        do {
            try await auth.deleteAccount()   // 成功后 logout → 根视图切回 AuthView，本页随之消失
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 绑定手机号 / 邮箱（OTP purpose=bind）

struct BindContactView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    let channel: String           // "sms" | "email"
    var onBound: () -> Void = {}

    @State private var target = ""
    @State private var code = ""
    @State private var cooldown = 0
    @State private var sendingCode = false
    @State private var loading = false
    @State private var error: String?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var isPhone: Bool { channel == "sms" }
    private var trimmed: String { target.trimmingCharacters(in: .whitespaces) }
    private var targetValid: Bool { !trimmed.isEmpty }
    private var canSendCode: Bool { cooldown == 0 && !sendingCode && targetValid }
    private var canSubmit: Bool { targetValid && code.count == 6 }

    var body: some View {
        NavigationStack {
            Form {
                Section(isPhone ? "绑定手机号" : "绑定邮箱") {
                    if isPhone {
                        TextField("手机号", text: $target).keyboardType(.phonePad)
                    } else {
                        TextField("邮箱", text: $target)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    HStack {
                        TextField("验证码", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .onChange(of: code) { _, v in
                                let f = String(v.filter(\.isNumber).prefix(6))
                                if f != code { code = f }
                            }
                        Button(cooldown > 0 ? "\(cooldown)s 后重发" : "获取验证码") {
                            Task { await sendCode() }
                        }
                        .font(.callout)
                        .disabled(!canSendCode)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(isPhone ? "绑定手机号" : "绑定邮箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if loading { ProgressView() } else { Text("绑定").bold() }
                    }
                    .disabled(loading || !canSubmit)
                }
            }
            .onReceive(timer) { _ in if cooldown > 0 { cooldown -= 1 } }
        }
    }

    private func sendCode() async {
        error = nil
        sendingCode = true
        defer { sendingCode = false }
        do {
            let r = try await auth.sendOtp(channel: channel, target: trimmed, purpose: "bind")
            cooldown = r.cooldown
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit() async {
        error = nil
        loading = true
        defer { loading = false }
        do {
            try await auth.bindContact(channel: channel, target: trimmed, code: code)
            onBound()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Address Book

enum AddressEditTarget: Identifiable {
    case new
    case edit(Address)
    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let a): return "edit-\(a.id)"
        }
    }
}

struct AddressListView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var store = AddressStore.shared
    @State private var editTarget: AddressEditTarget?
    @State private var pendingDelete: Address?

    // 选择模式（CheckoutView 用）—— 不为 nil 即"用于选择"，点行回调并自动 dismiss
    var onSelect: ((Address) -> Void)?

    var body: some View {
        Group {
            if store.isLoading && store.addresses.isEmpty {
                ProgressView()
            } else if let error = store.error, store.addresses.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if store.addresses.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("收货地址")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editTarget = .new
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await store.reload() }
        .refreshable { await store.reload() }
        .sheet(item: $editTarget) { target in
            NavigationStack {
                AddressEditView(target: target) {
                    // AddressStore.create/update 内部已 reload，无需重复
                }
                .environmentObject(auth)
            }
        }
        .confirmationDialog(
            pendingDelete.map { "删除「\($0.name) · \($0.address)」？" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { a in
            Button("删除", role: .destructive) {
                Task { await store.delete(id: a.id) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有收货地址", systemImage: "house")
        } description: {
            Text("点右上角 + 添加")
        } actions: {
            Button("添加地址") { editTarget = .new }
                .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        List {
            ForEach(store.addresses) { a in
                row(a)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let onSelect {
                            onSelect(a)
                        } else {
                            editTarget = .edit(a)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = a
                        } label: { Label("删除", systemImage: "trash") }
                        Button {
                            editTarget = .edit(a)
                        } label: { Label("编辑", systemImage: "pencil") }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ a: Address) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(a.name).font(.subheadline).bold()
                    Text(a.phone).font(.subheadline).foregroundStyle(.secondary)
                    if a.isDefault {
                        Text("默认").font(.caption2).bold()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(a.address).font(.callout).foregroundStyle(.primary)
                if let note = a.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if onSelect != nil {
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddressEditView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    let target: AddressEditTarget
    let onSaved: () -> Void

    @State private var name = ""
    @State private var phone = ""
    @State private var address = ""
    @State private var note = ""
    @State private var isDefault = false
    @State private var loading = false
    @State private var error: String?
    // 接单匹配：结构化区县（产出 area_code，用于就近派单）
    @State private var provinceCode: String?
    @State private var cityCode: String?
    @State private var areaCode: String?
    @State private var regionLabel = ""
    @State private var showRegionPicker = false
    @State private var locating = false

    private var isEdit: Bool {
        if case .edit = target { return true } else { return false }
    }
    private var editingId: Int? {
        if case .edit(let a) = target { return a.id } else { return nil }
    }

    var body: some View {
        Form {
            Section("收货信息") {
                TextField("收货人姓名", text: $name)
                TextField("联系电话", text: $phone).keyboardType(.phonePad)
                Button {
                    showRegionPicker = true
                } label: {
                    HStack {
                        Text("所在区县")
                        Spacer()
                        Text(regionLabel.isEmpty ? "请选择（用于就近派单）" : regionLabel)
                            .foregroundStyle(regionLabel.isEmpty ? Color.secondary : Color.primary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                Button {
                    Task { await useLocation() }
                } label: {
                    HStack(spacing: 6) {
                        if locating {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "location.fill")
                        }
                        Text(locating ? "定位中…" : "用当前定位填充区县")
                    }
                    .font(.footnote)
                }
                .disabled(locating)
                TextField("详细地址", text: $address, axis: .vertical)
                    .lineLimit(2...4)
                TextField("备注（可选）", text: $note)
            }

            Section {
                Toggle("设为默认地址", isOn: $isDefault)
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle(isEdit ? "编辑地址" : "新建地址")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if loading { ProgressView() } else { Text("保存").bold() }
                }
                .disabled(loading || !canSave)
            }
        }
        .task { loadInitial() }
        .sheet(isPresented: $showRegionPicker) {
            RegionCascadePicker { pick in
                provinceCode = pick.province.code
                cityCode = pick.city.code
                areaCode = pick.area.code          // 匹配键始终是区县级
                regionLabel = [pick.province, pick.city, pick.area].map(\.name).joined()    // 「所在区县」只显示到区县(3级)，即便选到街道/村
                address = pick.pathName   // 每次重新选区县都用最新路径覆盖详细地址
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !phone.trimmingCharacters(in: .whitespaces).isEmpty
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadInitial() {
        if case .edit(let a) = target {
            name = a.name
            phone = a.phone
            address = a.address
            note = a.note ?? ""
            isDefault = a.isDefault
            provinceCode = a.provinceCode
            cityCode = a.cityCode
            areaCode = a.areaCode
            if a.areaCode != nil { regionLabel = "已选区县（点按可修改）" }
        }
    }

    // 定位 → CLGeocoder 反编码 → 匹配 regions 预填省市区（用户仍可在级联里改）
    private func useLocation() async {
        locating = true
        defer { locating = false }
        error = nil
        do {
            let geo = try await LocationService.shared.locateAndGeocode()
            let m = await RegionService.shared.match(province: geo.province, city: geo.city, district: geo.district)
            if let pc = m.provinceCode { provinceCode = pc }
            if let cc = m.cityCode { cityCode = cc }
            if let ac = m.areaCode { areaCode = ac }
            let label = [m.provinceName, m.cityName, m.areaName].compactMap { $0 }.joined()
            if label.isEmpty {
                error = "未能识别定位所在区域，请手动选择"
            } else {
                regionLabel = label
                // 精确定位：标准省市区后追加街道+门牌，再把 POI 地标拼到最末；非精确二者均 nil，回退只填省市区
                var detail = geo.streetDetail.map { label + $0 } ?? label
                if let poi = geo.poi, !poi.isEmpty { detail += poi }
                address = detail
                if m.areaCode == nil { error = "已定位到 \(label)，请手动选到区县" }
            }
        } catch LocationError.denied {
            error = "未授权定位，请在系统设置开启，或手动选择区县"
        } catch {
            self.error = "定位失败，请手动选择区县"
        }
    }

    private func save() async {
        error = nil
        loading = true
        defer { loading = false }
        do {
            if let id = editingId {
                _ = try await AddressStore.shared.update(
                    id: id,
                    name: name, phone: phone, address: address,
                    note: note.isEmpty ? nil : note,
                    isDefault: isDefault,
                    provinceCode: provinceCode, cityCode: cityCode, areaCode: areaCode
                )
            } else {
                _ = try await AddressStore.shared.create(
                    name: name, phone: phone, address: address,
                    note: note.isEmpty ? nil : note,
                    isDefault: isDefault,
                    provinceCode: provinceCode, cityCode: cityCode, areaCode: areaCode
                )
            }
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
