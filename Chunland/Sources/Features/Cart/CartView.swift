import SwiftUI
import ChunlandCore

struct CartView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var tabRouter: TabRouter
    @State private var store = CartStore.shared
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var showCheckout = false
    @State private var pendingDelete: CartItem?
    @State private var pendingClearInvalid = false
    @State private var navigateToCode: String?
    @State private var navigateToOrderId: Int?
    @State private var toast: String?

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                GuestGate(title: "登录后查看购物车",
                          message: "登录 / 注册后即可加购与下单",
                          systemImage: "cart")
            } else if store.isLoading && store.cart == nil {
                ProgressView()
            } else if let cart = store.cart, !cart.items.isEmpty {
                cartContent(cart)
            } else if let error = store.error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else {
                emptyState
            }
        }
        .navigationTitle("购物车")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AskAIButton(context: .cart())
            }
        }
        .navigationDestination(item: $navigateToCode) { code in
            ProductDetailView(code: code)
        }
        .navigationDestination(item: $navigateToOrderId) { id in
            OrderDetailView(orderId: id)
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        // task(id:) 随登录态变化重跑：游客不拉取（避免 /cart 401），登录成功后自动加载。
        .task(id: auth.isLoggedIn) {
            guard auth.isLoggedIn else { return }
            await store.reload()
            await store.loadMerchantConfigs()
        }
        .refreshable {
            guard auth.isLoggedIn else { return }
            await store.reload()
            await store.loadMerchantConfigs()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("购物车是空的", systemImage: "cart")
        } description: {
            Text("去首页逛逛商品吧")
        } actions: {
            Button {
                tabRouter.selected = .home
            } label: {
                Text("去逛逛")
                    .padding(.horizontal, 24)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func cartContent(_ cart: Cart) -> some View {
        VStack(spacing: 0) {
            List {
                ForEach(store.availableGroups) { group in
                    Section {
                        ForEach(group.items) { item in
                            CartItemRow(
                                item: item,
                                isSelected: store.selected.contains(item.id),
                                onToggleSelect: { store.toggleSelect(item.id) },
                                onTap: { navigateToCode = item.productCode },
                                onQuantityChange: { newQty in
                                    if let err = await store.updateItem(item, quantity: newQty) {
                                        showToast(err)
                                    }
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = item
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        merchantHeader(group)
                    } footer: {
                        merchantFooter(group)
                    }
                }

                if !store.invalidItems.isEmpty {
                    Section {
                        ForEach(store.invalidItems) { item in
                            CartItemRow(
                                item: item,
                                isSelected: false,
                                onToggleSelect: {},
                                onTap: { navigateToCode = item.productCode },
                                onQuantityChange: { _ in }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = item
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("失效商品").font(.subheadline).bold()
                                .foregroundStyle(.primary)
                            Text("\(store.invalidItems.count) 件")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("清空") {
                                pendingClearInvalid = true
                            }
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
            .listStyle(.plain)

            Divider()
            if !store.blockingGroups.isEmpty {
                checkoutBlockWarning
            }
            bottomBar
        }
        // iPad（regular）整车限宽居中，避免每行被 Spacer 撑到两端、中间大片空白；
        // compact（iPhone）走 .infinity = 全宽，等于原状。
        .frame(maxWidth: hSizeClass == .regular ? 720 : .infinity)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showCheckout, onDismiss: { Task { await store.reload() } }) {
            CheckoutView(
                onViewOrder: { orderId in
                    navigateToOrderId = orderId
                },
                onBackHome: {
                    tabRouter.selected = .home
                }
            )
            .environmentObject(auth)
        }
        .confirmationDialog(
            pendingDelete.map { "删除「\($0.name)」？" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("删除", role: .destructive) {
                Task {
                    if let err = await store.deleteItem(item) {
                        showToast(err)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "清空所有失效商品？",
            isPresented: $pendingClearInvalid,
            titleVisibility: .visible
        ) {
            Button("清空 \(store.invalidItems.count) 件", role: .destructive) {
                Task { await store.clearInvalid() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                store.toggleSelectAll()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.allSelectableSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(store.allSelectableSelected ? Color.accentColor : .secondary)
                    Text("全选").font(.subheadline)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text("合计").font(.caption).foregroundStyle(.secondary)
                    Text("¥\(NSDecimalNumber(decimal: store.selectedTotal).stringValue)")
                        .font(.headline).bold().foregroundStyle(.red)
                }
                Text("已选 \(store.selected.count) 件")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Button {
                showCheckout = true
            } label: {
                Text("结算(\(store.selected.count))")
                    .font(.subheadline).bold()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(store.canCheckout ? Color.accentColor : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .disabled(!store.canCheckout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { if toast == msg { toast = nil } }
        }
    }

    // MARK: - 按店分组的 section header / footer

    private func merchantHeader(_ group: CartStore.MerchantGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "storefront")
                .font(.caption).foregroundStyle(.secondary)
            Text(group.merchantName)
                .font(.subheadline).bold().foregroundStyle(.primary)
            Spacer()
        }
    }

    @ViewBuilder
    private func merchantFooter(_ group: CartStore.MerchantGroup) -> some View {
        let selectedInGroup = group.items.filter { store.selected.contains($0.id) }
        if !selectedInGroup.isEmpty {
            let sub = store.subtotal(of: selectedInGroup)
            let minAmt = store.minOrderAmount(of: group)
            HStack {
                if sub < minAmt {
                    Text("还差 ¥\(money(minAmt - sub)) 起送")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Text("小计 ¥\(money(sub))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var checkoutBlockWarning: some View {
        let names = store.blockingGroups.map(\.merchantName).joined(separator: "、")
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text("「\(names)」未满起送，无法结算")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    private func money(_ d: Decimal) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: d).doubleValue)
    }
}

// MARK: - CartItemRow

private struct CartItemRow: View {
    let item: CartItem
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onTap: () -> Void
    let onQuantityChange: (Int) async -> Void
    @State private var quantity: Int

    init(item: CartItem,
         isSelected: Bool,
         onToggleSelect: @escaping () -> Void,
         onTap: @escaping () -> Void,
         onQuantityChange: @escaping (Int) async -> Void) {
        self.item = item
        self.isSelected = isSelected
        self.onToggleSelect = onToggleSelect
        self.onTap = onTap
        self.onQuantityChange = onQuantityChange
        _quantity = State(initialValue: item.quantity)
    }

    private var isAvailable: Bool { item.stockStatus != "outOfStock" }
    private var minQ: Int { item.minOrderQuantity ?? 1 }
    private var maxQ: Int { item.maxOrderQuantity ?? 99 }
    private var isFixedQuantity: Bool { minQ >= maxQ }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .opacity(isAvailable ? 1 : 0.3)

            Button(action: onTap) {
                HStack(spacing: 12) {
                    ZStack {
                        CachedAsyncImage(url: URL(string: item.thumbnail ?? "")) { img in
                            img.resizable().aspectRatio(1, contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(Color(.systemGray5))
                        }
                        .frame(width: 64, height: 64)
                        .clipped()
                        .cornerRadius(8)

                        if !isAvailable {
                            Color.black.opacity(0.45)
                                .frame(width: 64, height: 64)
                                .cornerRadius(8)
                            Text("失效")
                                .font(.caption2).bold()
                                .foregroundStyle(.white)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.subheadline).lineLimit(2)
                            .foregroundStyle(isAvailable ? .primary : .secondary)
                        if let size = item.selectedSize, !size.isEmpty {
                            Text("尺码 \(size)")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(.systemGray6))
                                .clipShape(Capsule())
                                .foregroundStyle(.secondary)
                        }
                        if let unit = item.unitType, !unit.isEmpty, unit.count > 1 {
                            Text(unit).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let price = item.currentPrice {
                            HStack(spacing: 4) {
                                Text("¥\(price.description)").font(.caption).bold()
                                    .foregroundStyle(isAvailable ? .red : .secondary)
                                Text("×\(quantity)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if item.randomWeight {
                            Text("生鲜·按实重").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            quantityControl
        }
    }

    @ViewBuilder
    private var quantityControl: some View {
        if isAvailable {
            if isFixedQuantity {
                Text("限购 \(maxQ)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
            } else {
                Stepper(value: $quantity, in: minQ...maxQ, step: 1) {
                    Text("\(quantity)").frame(minWidth: 28)
                }
                .labelsHidden()
                .onChange(of: quantity) { _, new in
                    // 只有"用户改的"才同步 server；服务端推回来的不再发请求
                    if new != item.quantity { scheduleSync(new) }
                }
                .onChange(of: item.quantity) { _, new in
                    // 服务端数据变了（如别处加购、reload 刷新），更新本地 Stepper
                    if new != quantity { quantity = new }
                }
            }
        }
    }

    @State private var debounceTask: Task<Void, Never>?

    private func scheduleSync(_ qty: Int) {
        debounceTask?.cancel()
        debounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch { return }
            await onQuantityChange(qty)
        }
    }
}

// MARK: - CheckoutView

struct CheckoutView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    let onViewOrder: (Int) -> Void
    let onBackHome: () -> Void

    @State private var cart = CartStore.shared

    // CheckoutView 改用共享 AddressStore，
    // 让 Profile/AddressListView 增删地址后这里自动看到最新数据
    @State private var addressStore = AddressStore.shared
    @State private var selectedAddress: Address?
    @State private var note = ""
    @State private var loading = false
    @State private var error: String?
    @State private var batch: CheckoutBatch?
    @State private var quote: OrderQuote?           // 距离代购费报价（选地址后服务端 dry-run 算）
    @State private var pendingQuote: OrderQuote?    // 轮询探到的新价，待用户确认（不静默跳变）
    @State private var quoting = false

    @State private var showAddressPicker = false
    @State private var showAddressEdit: AddressEditTarget?

    // 费率从 ConfigStore 读取（per-merchant，服务端 system_configs / merchants 唯一 truth source）
    private func money(_ d: Decimal) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: d).doubleValue)
    }

    // 平台费率优先取 quote 的实时值（与金额同源）；无 quote 时回退 ConfigStore 兜底。
    private func ratePercent(_ q: QuoteGroup?, _ merchantId: Int) -> String {
        let rate = q?.platformFeeRate ?? ConfigStore.shared.platformFeeRate(merchant: merchantId)
        let r = NSDecimalNumber(decimal: rate).doubleValue * 100
        return String(format: "%g", r)
    }

    var body: some View {
        NavigationStack {
            if let batch {
                orderSuccess(batch)
            } else {
                checkoutForm
            }
        }
    }

    private var checkoutForm: some View {
        Form {
            Section("收货地址") {
                addressSection
            }

            Section("订单备注") {
                TextField("给代购人留言（可选）", text: $note, axis: .vertical)
                    .lineLimit(1...3)
            }

            if let pending = pendingQuote, let cur = quote {
                Section {
                    Button {
                        quote = pending
                        pendingQuote = nil
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("费用已更新").font(.subheadline).bold()
                                Text("合计 ¥\(money(cur.grandTotal)) → ¥\(money(pending.grandTotal))，点击刷新")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color.orange.opacity(0.15))
            }

            Section {
                ForEach(cart.selectedGroups) { g in
                    let q = quoteGroup(for: g.merchantId)
                    VStack(spacing: 6) {
                        HStack {
                            Text(g.merchantName).font(.subheadline).bold()
                            Spacer()
                        }
                        HStack {
                            Text("商品合计").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("¥\(money(q?.itemsTotal ?? cart.subtotal(of: g.items)))").font(.caption)
                        }
                        HStack {
                            Text("平台服务费 (\(ratePercent(q, g.merchantId))%)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("¥\(money(q?.platformFee ?? cart.platformFee(of: g)))").font(.caption)
                        }
                        HStack {
                            Text("代购费（按距离）").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let q {
                                Text("¥\(money(q.agentFee))").font(.caption)
                            } else if selectedAddress?.areaCode == nil {
                                Text("选收货地址后计算").font(.caption2).foregroundStyle(.tertiary)
                            } else {
                                Text("计算中…").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Text("合计").bold()
                    Spacer()
                    Text("¥\(money(quote?.grandTotal ?? cart.selectedGrandTotal))").bold().foregroundStyle(.red)
                }
            } header: {
                Text("费用明细")
            } footer: {
                if quote == nil {
                    Text("代购费按商家发货地到收货地址的距离计算")
                } else if cart.selectedGroups.count > 1 {
                    Text("将按商家拆分为 \(cart.selectedGroups.count) 笔订单，分别由代购人接单")
                }
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }

            Section {
                Button {
                    Task { await placeOrder() }
                } label: {
                    if loading {
                        ProgressView()
                    } else {
                        Text("提交订单").frame(maxWidth: .infinity)
                    }
                }
                .disabled(loading || selectedAddress == nil)
            }
        }
        .navigationTitle("确认订单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") { dismiss() }
            }
        }
        .task {
            await cart.loadMerchantConfigs()
            await addressStore.reload()
            if selectedAddress == nil {
                selectedAddress = addressStore.defaultAddress
            }
            await reloadQuote()
            await pollQuote()
        }
        .onChange(of: selectedAddress?.id) { _, _ in
            Task {
                pendingQuote = nil      // 用户主动换地址 → 直接重报价，不走"提示后变"
                await reloadQuote()
            }
        }
        .sheet(isPresented: $showAddressPicker) {
            NavigationStack {
                AddressListView(onSelect: { picked in
                    selectedAddress = picked
                    showAddressPicker = false
                })
                .environmentObject(auth)
            }
        }
        .sheet(item: $showAddressEdit) { target in
            NavigationStack {
                AddressEditView(target: target) {
                    // AddressStore.create/update 内部已 reload，不必再调
                    if selectedAddress == nil {
                        selectedAddress = addressStore.defaultAddress
                    }
                }
                .environmentObject(auth)
            }
        }
    }

    @ViewBuilder
    private var addressSection: some View {
        if let addr = selectedAddress {
            Button {
                showAddressPicker = true
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(addr.name).font(.subheadline).bold()
                                .foregroundStyle(.primary)
                            Text(addr.phone).font(.subheadline).foregroundStyle(.secondary)
                            if addr.isDefault {
                                Text("默认").font(.caption2).bold()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                        }
                        Text(addr.address).font(.callout).foregroundStyle(.primary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        } else if addressStore.isLoading {
            HStack { ProgressView(); Spacer() }
                .padding(.vertical, 4)
        } else {
            Button {
                showAddressEdit = .new
            } label: {
                Label("添加收货地址", systemImage: "plus.circle")
            }
        }
    }

    private func orderSuccess(_ batch: CheckoutBatch) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("下单成功").font(.title).bold()
            if batch.orderCount == 1, let only = batch.orders.first {
                Text("订单号：\(only.orderNumber)").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("已按商家拆为 \(batch.orderCount) 笔订单").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("总金额：¥\(batch.grandTotal)").font(.headline)
            Text("等待代购人接单…").foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    let id = batch.orders.first?.id
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let id { onViewOrder(id) }
                    }
                } label: {
                    Text("查看订单").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onBackHome()
                    }
                } label: {
                    Text("继续逛逛").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)
        }
        .padding()
        .navigationTitle("订单确认")
    }

    private func quoteGroup(for merchantId: Int) -> QuoteGroup? {
        quote?.groups.first { $0.merchantId == merchantId }
    }

    // 选中商品 + 收货区县 → 服务端报价（含距离代购费）。地址/进入时刷新；失败静默回退本地估算。
    private func reloadQuote() async {
        let codes = cart.selectedItems.map(\.productCode)
        guard !codes.isEmpty else { quote = nil; return }
        quoting = true
        defer { quoting = false }
        quote = try? await OrderService.shared.quote(
            areaCode: selectedAddress?.areaCode,
            productCodes: codes
        )
    }

    // 用户停留结算页期间，后台每 4s 探测费率变化：变了不静默改显示价，
    // 挂到 pendingQuote 由顶部黄条提示用户确认（避免付款时金额无声突变）。
    // .task 随 view 生命周期，view 消失即 Task 取消、循环退出。
    private func pollQuote() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            if Task.isCancelled { break }
            let codes = cart.selectedItems.map(\.productCode)
            guard !codes.isEmpty else { continue }
            guard let latest = try? await OrderService.shared.quote(
                areaCode: selectedAddress?.areaCode,
                productCodes: codes
            ) else { continue }
            if quote == nil {
                quote = latest                              // 首次还没价 → 直接补上
            } else if latest.grandTotal != quote?.grandTotal {
                pendingQuote = latest                       // 变了 → 挂起，等用户点黄条确认
            } else {
                pendingQuote = nil                          // 又变回与显示价一致 → 撤掉提示
            }
        }
    }

    private func placeOrder() async {
        guard let addr = selectedAddress else { return }
        // 有未确认的新价（轮询探到费率变更）→ 先应用 + 提示，保证「看到的价 = 下单的价」
        if let pending = pendingQuote {
            quote = pending
            pendingQuote = nil
            error = "费用已更新为 ¥\(money(pending.grandTotal))，请确认后再次提交"
            return
        }
        error = nil
        loading = true
        defer { loading = false }
        let snapshot = DeliveryAddress(
            name: addr.name,
            phone: addr.phone,
            address: addr.address,
            note: note.isEmpty ? nil : note,
            areaCode: addr.areaCode
        )
        let codes = cart.selectedItems.map(\.productCode)
        do {
            batch = try await OrderService.shared.placeOrder(
                deliveryAddress: snapshot,
                productCodes: codes.isEmpty ? nil : codes
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

}
