import SwiftUI
import ChunlandCore

// 首页 = 店铺选择页（store picker）。点店铺卡进入 StoreView 浏览该店商品。
//
// 定位布局（借鉴同城首页）：顶栏「南京 ▾」城市锚点 + 店铺卡「📍 区县 · 距离」+ 本市优先分组。
// 距离由 server 计算（与下单报价同口径），iOS 只做展示分组，绝不本地算费。
// 外市店排「其他城市」分组、不隐藏 —— 代购模式下远店只是距离费更高，不是不能买。
struct HomeView: View {
    @State private var loading = false
    @State private var error: String?
    @State private var showCityPicker = false
    @State private var showFarther = false   // 「查看更远的店铺」折叠区是否展开

    // 静默预填每进程只试一次：已授权才定位（绝不弹授权窗），失败回退默认收货地址区县。
    @MainActor private static var didAttemptSilentAnchor = false

    private var store: MerchantStore { MerchantStore.shared }

    var body: some View {
        Group {
            if !store.merchants.isEmpty {
                storeList
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    error ?? "暂无店铺",
                    systemImage: "storefront",
                    description: Text("下拉刷新重试")
                )
            }
        }
        .navigationTitle("选择店铺")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                cityButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                AskAIButton(context: .store())
            }
        }
        .sheet(isPresented: $showCityPicker) {
            CityPickerSheet()
        }
        .task {
            await load()
            await silentAnchorIfNeeded()
        }
    }

    // 顶栏城市锚点：「南京 ▾」；未设 =「全国 ▾」。点开城市选择器。
    private var cityButton: some View {
        Button { showCityPicker = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "location.fill").font(.caption2)
                Text(cityDisplayName).fontWeight(.semibold)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
    }

    // 顶栏显示选中地点名（省/市/区县）。「南京市」→「南京」「江苏省」→「江苏」，
    // 区县保留全名（「江宁区」）；未设为「全国」。
    private var cityDisplayName: String {
        guard let name = store.anchorName, !name.isEmpty else { return "全国" }
        if name.count > 2, name.hasSuffix("省") || name.hasSuffix("市") {
            return String(name.dropLast())
        }
        return name
    }

    private var storeList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // 近店直接展示；nearby 为空（选了个附近没有任何店的城市）时，
                // 给一句「附近暂无店铺」并把远店区默认展开，避免打开只见一个折叠条。
                if store.nearbyMerchants.isEmpty && !store.fartherMerchants.isEmpty {
                    nearbyEmptyHint
                }
                ForEach(store.nearbyMerchants) { merchant in
                    storeLink(merchant)
                }
                if !store.fartherMerchants.isEmpty {
                    fartherSection
                }
            }
            .padding()
        }
        .refreshable { await reload() }
    }

    private func storeLink(_ merchant: Merchant) -> some View {
        // 同市店只显示区县；跨市店（含近的邻市，如扬州视角的南京店）显示「市·区县」。
        // 锚点为省级/全国（anchorCityCode 为 nil）时一律带市名 —— 省内跨市，市名有区分价值。
        let showCity = store.anchorCityCode == nil || merchant.cityCode != store.anchorCityCode
        return NavigationLink(destination: StoreView(merchant: merchant)) {
            StoreCard(merchant: merchant, showCity: showCity)
        }
        .buttonStyle(.plain)
    }

    private var nearbyEmptyHint: some View {
        Text("附近暂无店铺，以下是较远的店铺（代购费按距离计）")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    // 「查看更远的店铺 (N)」折叠区：远店可达但代购费更高，默认收起、点开展示。
    // 近店为空时强制展开（nearbyEmptyHint 已解释）。
    @ViewBuilder
    private var fartherSection: some View {
        let forceOpen = store.nearbyMerchants.isEmpty
        if !forceOpen {
            Button {
                withAnimation { showFarther.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showFarther ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("查看更远的店铺 (\(store.fartherMerchants.count))")
                    Spacer()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if forceOpen || showFarther {
            ForEach(store.fartherMerchants) { merchant in
                storeLink(merchant)
            }
        }
    }

    private func load() async {
        guard store.merchants.isEmpty else { return }
        loading = true
        error = nil
        await store.loadIfNeeded()
        loading = false
        if store.merchants.isEmpty {
            error = "暂时无法加载店铺"
        }
    }

    private func reload() async {
        await store.reload()
        if store.merchants.isEmpty {
            error = "暂时无法加载店铺"
        } else {
            error = nil
        }
    }

    // 首次进入的城市预填：① 已授权 → 静默定位反编码（无授权立即跳过，绝不弹窗）；
    // ② 回退已登录用户的默认收货地址区县；③ 都没有保持「全国」，等用户点选择器。
    private func silentAnchorIfNeeded() async {
        guard store.anchorCode == nil, !Self.didAttemptSilentAnchor else { return }
        Self.didAttemptSilentAnchor = true

        if let geo = await LocationService.shared.geocodeIfAuthorized() {
            let m = await RegionService.shared.match(province: geo.province, city: geo.city, district: geo.district)
            // 定位到区县最精确；displayName 与 code 同级（server 回显会再校准）
            if let code = m.areaCode {
                await store.setAnchor(code: code, displayName: m.areaName)
                return
            } else if let code = m.cityCode {
                await store.setAnchor(code: code, displayName: m.cityName)
                return
            }
        }

        if AuthManager.shared.isLoggedIn {
            if AddressStore.shared.addresses.isEmpty { await AddressStore.shared.reload() }
            if let area = AddressStore.shared.defaultAddress?.areaCode {
                // 市名不在地址数据里，显示名等 server 回显（setAnchor → reload → 回显覆盖）
                await store.setAnchor(code: area, displayName: nil)
            }
        }
    }
}

// MARK: - 地点选择器（📍 一键定位 / 全国 / 省→市→区县 级联，每级可选定）

private struct CityPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var locating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            regionLevel(parent: nil, title: "选择地区", selectable: nil, isRoot: true)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // 递归级联：展示 parent 的子级。selectable = 当前层级对应地区（右上「选整个XX」，root 为 nil）；
    // isRoot = 省列表页（额外挂 📍定位 / 全国 入口）。区县（level≥3）为末级，点击即选定
    // —— 与商家发货地 area_code 粒度对齐，区县以下无中心坐标故不再下钻。
    // 返回 AnyView：递归级联（regionList 里 NavigationLink 又调本函数）会让 `some View`
    // 不透明类型自引用，必须在此处做类型擦除以切断循环。
    private func regionLevel(parent: String?, title: String, selectable: Region?, isRoot: Bool = false) -> AnyView {
        AnyView(
            RegionLevelLoader(parent: parent, title: title) { items in
                // 直辖市：唯一子级是「市辖区」→ 下钻一层直接展示区县，「选整个」仍对应上级（北京市）
                if items.count == 1, items[0].name == "市辖区" {
                    RegionLevelLoader(parent: items[0].code, title: title) { areas in
                        regionList(areas, selectable: selectable, isRoot: isRoot)
                    }
                } else {
                    regionList(items, selectable: selectable, isRoot: isRoot)
                }
            }
        )
    }

    @ViewBuilder
    private func regionList(_ items: [Region], selectable: Region?, isRoot: Bool) -> some View {
        let childHeader: String = {
            switch items.first?.level {
            case 2: return "选择城市"
            case 3: return "选择区 / 县"
            default: return "选择地区"
            }
        }()
        List {
            if isRoot {
                Section {
                    locateRow
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Button {
                        Task { await MerchantStore.shared.clearAnchor(); dismiss() }
                    } label: {
                        Label("全国（不限地区）", systemImage: "globe.asia.australia")
                    }
                }
            }
            Section(childHeader) {
                ForEach(items) { r in
                    if r.level >= 3 {
                        // 区县（最小可选级）→ 点击即选定
                        Button(r.name) { Task { await pick(r) } }
                            .foregroundStyle(.primary)
                    } else {
                        NavigationLink(r.name) {
                            regionLevel(parent: r.code, title: r.name, selectable: r)
                        }
                    }
                }
            }
        }
        .toolbar {
            if let selectable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("选整个\(selectable.name)") { Task { await pick(selectable) } }.bold()
                }
            }
        }
    }

    private func pick(_ r: Region) async {
        await MerchantStore.shared.setAnchor(code: r.code, displayName: r.name)
        dismiss()
    }

    private var locateRow: some View {
        Button { Task { await useLocation() } } label: {
            HStack {
                Label(locating ? "定位中…" : "使用当前定位", systemImage: "location.fill")
                if locating { Spacer(); ProgressView() }
            }
        }
        .disabled(locating)
    }

    // 用户主动点定位：允许触发授权弹窗（与地址页 useLocation 同纪律）。定位到区县最精确。
    private func useLocation() async {
        locating = true
        defer { locating = false }
        error = nil
        do {
            let geo = try await LocationService.shared.locateAndGeocode()
            let m = await RegionService.shared.match(province: geo.province, city: geo.city, district: geo.district)
            let picked: (code: String, name: String?)? =
                m.areaCode.map { ($0, m.areaName) } ?? m.cityCode.map { ($0, m.cityName) }
            guard let picked else {
                error = "未能识别所在地点，请手动选择"
                return
            }
            await MerchantStore.shared.setAnchor(code: picked.code, displayName: picked.name)
            dismiss()
        } catch LocationError.denied {
            error = "未授权定位，请在系统设置开启，或手动选择地点"
        } catch {
            self.error = "定位失败，请手动选择地点"
        }
    }
}

// MARK: - 店铺卡

private struct StoreCard: View {
    let merchant: Merchant
    var showCity = false

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: merchant.logoUrl ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "storefront")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGray6))
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(merchant.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let location = locationText {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin.and.ellipse").font(.caption2)
                        Text(location)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(feeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    // 「江宁区 · 8.2km」；外市分组带市名「上海市·浦东新区 · 271km」；无发货地不显示本行
    private var locationText: String? {
        guard let area = merchant.areaName else { return nil }
        let place: String
        if showCity, let city = merchant.cityName {
            place = "\(city)·\(area)"
        } else {
            place = area
        }
        guard let km = merchant.distanceKm else { return place }
        return "\(place) · \(Self.formatKm(km))"
    }

    private static func formatKm(_ km: Double) -> String {
        km < 100 ? String(format: "%.1fkm", km) : "\(Int(km.rounded()))km"
    }

    private var feeText: String {
        guard let rate = merchant.platformFeeRate else { return "服务费按平台标准" }
        let percent = NSDecimalNumber(decimal: rate).doubleValue * 100
        return "服务费 \(String(format: "%g", percent))%"
    }
}
