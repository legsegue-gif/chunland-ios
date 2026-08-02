import SwiftUI
import ChunlandCore

struct AuthView: View {
    enum Mode { case otp, password }

    // 游客模式下被拦动作的可选提示（如「登录后即可加入购物车」）。AuthView 现仅作 sheet 呈现。
    var prompt: String? = nil

    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .otp          // 验证码为主
    @State private var usePhone = true
    @State private var phone = ""
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var agreed = false             // 用户协议勾选，gate 提交
    @State private var cooldown = 0               // 「X 秒后重发」倒计时，由发码成功响应驱动
    @State private var sendingCode = false
    @State private var error: String?
    @State private var loading = false
    @State private var showServerConfig = false
    @State private var showReset = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var channel: String { usePhone ? "sms" : "email" }
    private var target: String { (usePhone ? phone : email).trimmingCharacters(in: .whitespaces) }
    private var targetValid: Bool { !target.isEmpty }

    private var canSubmit: Bool {
        guard targetValid else { return false }
        return mode == .otp ? code.count == 6 : !password.isEmpty
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    header
                    if let prompt {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    inputCard
                    primaryButton
                    secondaryToggle
                    agreement
                }
                .padding(.horizontal, 24)
                .padding(.top, 56)
                .padding(.bottom, 40)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)   // iPad 居中
            }
            .scrollDismissesKeyboard(.interactively)

            // 服务器配置入口（角标）—— 仅 Debug 构建；Release（App Store）锁定 prod、不暴露切换入口
            #if DEBUG
            Button { showServerConfig = true } label: {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            .padding(.leading, 8)
            #endif

            // 关闭（游客「先逛逛」）—— AuthView 现仅作 sheet 呈现，可随时收起回去浏览
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 8)
        }
        .sheet(isPresented: $showServerConfig) { ServerConfigSheet() }
        .sheet(isPresented: $showReset) {
            PasswordResetView(usePhone: usePhone, target: target)
                .environmentObject(auth)
        }
        .onReceive(timer) { _ in if cooldown > 0 { cooldown -= 1 } }
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    // MARK: - 品牌头

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "cart.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            Text("金鳞").font(.title.bold())
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        if mode == .password { return "账号密码登录" }
        return usePhone ? "手机号一键登录 / 注册" : "邮箱一键登录 / 注册"
    }

    // MARK: - 输入卡片

    private var inputCard: some View {
        VStack(spacing: 0) {
            Picker("账号类型", selection: $usePhone) {
                Text("手机号").tag(true)
                Text("邮箱").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            Divider()

            // 渠道字段（手机号 / 邮箱）
            fieldRow(icon: usePhone ? "phone.fill" : "envelope.fill") {
                if usePhone {
                    TextField("手机号", text: $phone)
                        .keyboardType(.phonePad)
                } else {
                    TextField("邮箱", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Divider()

            // 验证码 / 密码
            if mode == .otp {
                fieldRow(icon: "lock.fill") {
                    HStack {
                        TextField("验证码", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)   // iOS 短信验证码自动填充
                            .onChange(of: code) { _, v in
                                let filtered = String(v.filter(\.isNumber).prefix(6))  // 只留数字、最多 6 位
                                if filtered != code { code = filtered }
                            }
                        Button(cooldown > 0 ? "\(cooldown)s 后重发" : "获取验证码") {
                            Task { await sendCode() }
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(canSendCode ? Color.accentColor : Color.secondary)
                        .disabled(!canSendCode)
                    }
                }
            } else {
                fieldRow(icon: "lock.fill") {
                    SecureField("密码", text: $password)
                }
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            } else if mode == .otp && !loading {
                Text("未注册的账号将自动创建")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var canSendCode: Bool { cooldown == 0 && !sendingCode && targetValid }

    @ViewBuilder
    private func fieldRow<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            content()
        }
        .padding(.vertical, 14)
    }

    // MARK: - 主按钮

    private var primaryButton: some View {
        Button {
            Task { await submit() }
        } label: {
            Group {
                if loading {
                    ProgressView().tint(.white)
                } else {
                    Text(mode == .otp ? "登录 / 注册" : "登录").fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .foregroundStyle(.white)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(canSubmit && !loading ? 1 : 0.45)
        .disabled(!canSubmit || loading)
    }

    // MARK: - 次要入口（密码 ↔ 验证码）

    private var secondaryToggle: some View {
        HStack {
            Button {
                mode = mode == .otp ? .password : .otp
                error = nil
            } label: {
                HStack(spacing: 2) {
                    Text(mode == .otp ? "密码登录" : "验证码登录")
                    Image(systemName: "chevron.right").font(.caption2)
                }
            }
            if mode == .password {
                Spacer()
                Button("忘记密码？") { showReset = true }
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    // MARK: - 协议

    private var agreement: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { agreed.toggle() } label: {
                Image(systemName: agreed ? "checkmark.square.fill" : "square")
                    .foregroundStyle(agreed ? Color.accentColor : Color.secondary)
            }
            Text(agreementText)
                .font(.footnote)
                .tint(.accentColor)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 协议文案：内联可点链接（《用户协议》《隐私政策》），点击经默认 openURL 在 Safari 打开。
    // URL 取自当前服务器（docsBaseURL）：Debug 连本地、Release 指公网 prod。
    private var agreementText: AttributedString {
        let base = AppSettings.shared.docsBaseURL
        let md = "已阅读并同意 [《用户协议》](\(base)/terms) 和 [《隐私政策》](\(base)/privacy)"
        return (try? AttributedString(markdown: md)) ?? AttributedString("已阅读并同意《用户协议》和《隐私政策》")
    }

    // MARK: - Actions

    private func sendCode() async {
        error = nil
        sendingCode = true
        defer { sendingCode = false }
        do {
            let result = try await auth.sendOtp(channel: channel, target: target)
            cooldown = result.cooldown
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit() async {
        guard agreed else {
            error = "请先阅读并同意《用户协议》"
            return
        }
        error = nil
        loading = true
        defer { loading = false }
        do {
            if mode == .otp {
                try await auth.loginWithOtp(channel: channel, target: target, code: code)
            } else {
                try await auth.login(
                    phone: usePhone ? target : nil,
                    email: usePhone ? nil : target,
                    password: password
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 忘记密码（OTP 验证 + 设新密码）

struct PasswordResetView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    @State private var usePhone: Bool
    @State private var phone: String
    @State private var email: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirm = ""
    @State private var cooldown = 0
    @State private var sendingCode = false
    @State private var loading = false
    @State private var error: String?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(usePhone: Bool, target: String) {
        _usePhone = State(initialValue: usePhone)
        _phone = State(initialValue: usePhone ? target : "")
        _email = State(initialValue: usePhone ? "" : target)
    }

    private var channel: String { usePhone ? "sms" : "email" }
    private var target: String { (usePhone ? phone : email).trimmingCharacters(in: .whitespaces) }
    private var targetValid: Bool { !target.isEmpty }
    private var canSendCode: Bool { cooldown == 0 && !sendingCode && targetValid }
    private var passwordsMatch: Bool { newPassword == confirm }
    private var canSubmit: Bool {
        targetValid && code.count == 6 && newPassword.count >= 6 && passwordsMatch
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("验证身份") {
                    Picker("账号类型", selection: $usePhone) {
                        Text("手机号").tag(true)
                        Text("邮箱").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if usePhone {
                        TextField("手机号", text: $phone).keyboardType(.phonePad)
                    } else {
                        TextField("邮箱", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        TextField("验证码", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)   // iOS 短信验证码自动填充
                            .onChange(of: code) { _, v in
                                let filtered = String(v.filter(\.isNumber).prefix(6))  // 只留数字、最多 6 位
                                if filtered != code { code = filtered }
                            }
                        Button(cooldown > 0 ? "\(cooldown)s 后重发" : "获取验证码") {
                            Task { await sendCode() }
                        }
                        .font(.callout)
                        .disabled(!canSendCode)
                    }
                }

                Section {
                    SecureField("新密码（至少 6 位）", text: $newPassword)
                    SecureField("确认新密码", text: $confirm)
                } header: {
                    Text("设置新密码")
                } footer: {
                    if !confirm.isEmpty && !passwordsMatch {
                        Text("两次输入不一致").foregroundStyle(.red)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("重置密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if loading { ProgressView() } else { Text("完成").bold() }
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
            let r = try await auth.sendOtp(channel: channel, target: target, purpose: "reset")
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
            // 成功后 AuthManager 落 token → isLoggedIn=true → AuthView 整体被替换，sheet 随之消失
            try await auth.resetPassword(channel: channel, target: target, code: code, newPassword: newPassword)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
