import SwiftUI
import ChunlandCore

enum AppTab: Hashable {
    case home, feed, ai, cart, profile  // consumer 用
    case workbench, hall                // agent 用（A1：工作台置换旧「我的接单」）
    case merchantHome, merchantOrders   // merchant 用（M1 店铺/商品管理；M2 订单）
}

@MainActor
final class TabRouter: ObservableObject {
    @Published var selected: AppTab = .feed   // 默认落地「发现」（内容优先）

    /// 重复点击当前已选中 tab 的信号：每次自增，子视图通过 onChange 监听。
    /// 配合 reselectedTab 让对应页面执行「回到顶部 / 已在顶部则刷新」。
    @Published private(set) var reselect: Int = 0
    private(set) var reselectedTab: AppTab?

    /// TabView 的自定义 binding setter 调用此方法：点已选中的 tab 发信号，否则正常切换。
    func select(_ tab: AppTab) {
        if tab == selected {
            reselectedTab = tab
            reselect &+= 1
        } else {
            selected = tab
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var auth: AuthManager
    @StateObject private var orchestrator = AIOrchestrator(authManager: AuthManager.shared)
    @StateObject private var tabRouter = TabRouter()
    // 各页面 ✨ 入口唤起 AI 的唯一接缝；根部统一呈现上下文对话面板。
    @StateObject private var aiCoordinator = AICoordinator()
    // 游客模式：账号类动作/受限 tab 经此唤起登录；根部统一呈现登录 sheet。
    @StateObject private var loginCoordinator = LoginCoordinator()

    // 按「当前活跃身份」选布局；账号可同时持有多身份（consumer/agent/merchant），在「我的」页切换
    private var showsAgentLayout: Bool {
        auth.activeIdentity == "agent"
    }
    private var showsMerchantLayout: Bool {
        auth.activeIdentity == "merchant"
    }

    // 点击「已选中」的 tab 时 TabView 仍会调用 binding 的 setter（值不变 → onChange 不触发），
    // 借此把重复点击转给 TabRouter.select 发信号，实现「再点一次回顶/刷新」。
    private var tabSelection: Binding<AppTab> {
        Binding(get: { tabRouter.selected }, set: { tabRouter.select($0) })
    }

    var body: some View {
        TabView(selection: tabSelection) {
            if showsMerchantLayout {
                merchantTabs
            } else if showsAgentLayout {
                agentTabs
            } else {
                consumerTabs
            }
        }
        .minimizeTabBarOnScroll(tabRouter.selected == .feed)   // iOS 26+：仅「发现」tab 滚动时收起底部 tab
        .environmentObject(tabRouter)
        .environmentObject(aiCoordinator)
        .environmentObject(loginCoordinator)
        // 各页面 ✨ 入口经 coordinator 在根部统一弹出上下文对话面板（覆盖所有 tab）。
        // 显式再注入 environment —— 确保 sheet 内 AIChatView / AskAIButton 拿到完整依赖。
        .sheet(item: $aiCoordinator.activeContext) { ctx in
            AIChatSheet(context: ctx)
                .environmentObject(orchestrator)
                .environmentObject(auth)
                .environmentObject(aiCoordinator)
                .environmentObject(loginCoordinator)
        }
        // 游客模式：账号类动作/受限 tab 触发登录，根部统一弹 AuthView（覆盖所有 tab）。
        .sheet(item: $loginCoordinator.pending) { req in
            AuthView(prompt: req.reason)
                .environmentObject(auth)
        }
        .onAppear { alignTabToIdentity() }
        .onChange(of: auth.activeIdentity) { _, _ in
            // 切换身份 / 登录后落地到当前布局合法的 tab
            alignTabToIdentity()
        }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            // 登录成功 → 续做被拦动作并收起登录 sheet（无待办时 no-op）。
            if loggedIn { loginCoordinator.didLogin() }
        }
    }

    /// 当前选中 tab 若不属于当前布局，落到该布局首页；共有 tab（AI / 我的）保持不动。
    private func alignTabToIdentity() {
        let valid: Set<AppTab>
        let landing: AppTab
        if showsMerchantLayout {
            valid = [.merchantHome, .merchantOrders, .ai, .profile]; landing = .merchantHome
        } else if showsAgentLayout {
            valid = [.workbench, .hall, .ai, .profile]; landing = .workbench
        } else {
            valid = [.feed, .home, .ai, .cart, .profile]; landing = .feed
        }
        if !valid.contains(tabRouter.selected) {
            tabRouter.selected = landing
        }
    }

    // MARK: - Consumer tabs

    @ViewBuilder
    private var consumerTabs: some View {
        NavigationStack {
            FeedView()
        }
        .tabItem { Label("发现", systemImage: "newspaper") }
        .tag(AppTab.feed)

        NavigationStack {
            HomeView()
        }
        .tabItem { Label("店铺", systemImage: "storefront") }
        .tag(AppTab.home)

        NavigationStack {
            AIView()
                .environmentObject(orchestrator)
                .environmentObject(auth)
        }
        .tabItem { Label("AI助手", systemImage: "sparkles") }
        .tag(AppTab.ai)

        NavigationStack {
            CartView()
                .environmentObject(auth)
        }
        .tabItem { Label("购物车", systemImage: "cart") }
        .tag(AppTab.cart)

        NavigationStack {
            ProfileView()
                .environmentObject(orchestrator)
                .environmentObject(auth)
        }
        .tabItem { Label("我的", systemImage: "person") }
        .tag(AppTab.profile)
    }

    // MARK: - Merchant tabs（店铺 + 订单 / AI / 我的）

    @ViewBuilder
    private var merchantTabs: some View {
        NavigationStack {
            MerchantHomeView()
                .environmentObject(auth)
        }
        .tabItem { Label("店铺", systemImage: "storefront") }
        .tag(AppTab.merchantHome)

        NavigationStack {
            MerchantOrdersView()
        }
        .tabItem { Label("订单", systemImage: "list.bullet.rectangle") }
        .tag(AppTab.merchantOrders)

        NavigationStack {
            AIView()
                .environmentObject(orchestrator)
                .environmentObject(auth)
        }
        .tabItem { Label("AI助手", systemImage: "sparkles") }
        .tag(AppTab.ai)

        NavigationStack {
            ProfileView()
                .environmentObject(orchestrator)
                .environmentObject(auth)
        }
        .tabItem { Label("我的", systemImage: "person") }
        .tag(AppTab.profile)
    }

    // MARK: - Agent tabs

    @ViewBuilder
    private var agentTabs: some View {
        NavigationStack {
            AgentWorkbenchView()
                .environmentObject(auth)
        }
        .tabItem { Label("工作台", systemImage: "square.grid.2x2") }
        .tag(AppTab.workbench)

        NavigationStack {
            OrderListView(
                title: "接单大厅",
                scope: "hall",
                emptyTitle: "暂无可接订单",
                emptyDescription: "等待消费者下单中…",
                emptyIcon: "tray"
            )
            .environmentObject(auth)
        }
        .tabItem { Label("接单大厅", systemImage: "tray.full") }
        .tag(AppTab.hall)

        NavigationStack {
            AIView()
                .environmentObject(orchestrator)
                .environmentObject(auth)
        }
        .tabItem { Label("AI助手", systemImage: "sparkles") }
        .tag(AppTab.ai)

        NavigationStack {
            ProfileView()
                .environmentObject(orchestrator)
                .environmentObject(auth)
        }
        .tabItem { Label("我的", systemImage: "person") }
        .tag(AppTab.profile)
    }
}

extension View {
    /// iOS 26+：enabled 时向下滚动收起底部 tab 让位内容，否则 .never（常驻）。
    /// 传 `tabRouter.selected == .feed` 即可做到「仅发现页 minimize」；低于 iOS 26 始终常驻。
    @ViewBuilder
    func minimizeTabBarOnScroll(_ enabled: Bool) -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(enabled ? .onScrollDown : .never)
        } else {
            self
        }
    }
}
