import SwiftUI
import ChunlandCore

// 行政区划级联选择器 —— 消费 /regions 懒加载子级。两种用途：
//   · RegionCascadePicker：省→市→区→街道→村/社区 单选（地址录入）。区县及以下任一级都可"确认"，
//       匹配键(area_code)始终取区县级；更细层级只为收货地址更准。
//   · ServiceAreaPicker：省→市→区县多选（agent 服务区，到区县即止）。

// 选择结果：必含到区县，街道/村可空。area_code 取区县；pathName 拼完整地址前缀。
struct RegionPick {
    let province: Region
    let city: Region
    let area: Region
    let street: Region?
    let village: Region?
    var areaCode: String { area.code }
    var pathName: String {
        [province, city, area, street, village].compactMap { $0?.name }.joined()
    }
}

// 通用：加载某 parent 的子级 region 列表（带 loading / error）。
// internal：城市选择器（HomeView 的 CityPickerSheet）复用省→市两级。
struct RegionLevelLoader<Content: View>: View {
    let parent: String?
    let title: String
    @ViewBuilder let content: ([Region]) -> Content

    @State private var items: [Region] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else {
                content(items)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loading = true
            do { items = try await RegionService.shared.children(parent: parent) }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

// MARK: - 单选级联（地址，到村/社区）

struct RegionCascadePicker: View {
    let onSelect: (RegionPick) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RegionLevelLoader(parent: nil, title: "选择省份") { provinces in
                List(provinces) { p in NavigationLink(p.name) { cityList(p) } }
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } } }
        }
    }

    private func cityList(_ p: Region) -> some View {
        RegionLevelLoader(parent: p.code, title: p.name) { cities in
            List(cities) { c in NavigationLink(c.name) { areaList(p, c) } }
        }
    }

    private func areaList(_ p: Region, _ c: Region) -> some View {
        RegionLevelLoader(parent: c.code, title: c.name) { areas in
            List(areas) { a in NavigationLink(a.name) { streetList(p, c, a) } }
        }
    }

    private func streetList(_ p: Region, _ c: Region, _ a: Region) -> some View {
        RegionLevelLoader(parent: a.code, title: a.name) { streets in
            List {
                Button {
                    onSelect(RegionPick(province: p, city: c, area: a, street: nil, village: nil)); dismiss()
                } label: { confirmRow("就选「\(a.name)」（不细分）") }
                Section("或选街道") {
                    ForEach(streets) { s in NavigationLink(s.name) { villageList(p, c, a, s) } }
                }
            }
        }
    }

    private func villageList(_ p: Region, _ c: Region, _ a: Region, _ s: Region) -> some View {
        RegionLevelLoader(parent: s.code, title: s.name) { villages in
            List {
                Button {
                    onSelect(RegionPick(province: p, city: c, area: a, street: s, village: nil)); dismiss()
                } label: { confirmRow("就选到「\(s.name)」") }
                Section("或选社区 / 村") {
                    ForEach(villages) { v in
                        Button(v.name) {
                            onSelect(RegionPick(province: p, city: c, area: a, street: s, village: v)); dismiss()
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private func confirmRow(_ text: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            Text(text).foregroundStyle(.primary)
        }
    }
}

// MARK: - 多选区县（agent 服务区，到区县止）

struct ServiceAreaPicker: View {
    @Binding var selected: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RegionLevelLoader(parent: nil, title: "选择服务区县") { provinces in
                // 省级：前 2 位前缀 = 该省，统计其下已选区县数
                List(provinces) { p in
                    NavigationLink { cityList(p) } label: {
                        regionRow(p.name, count: selectedCount(prefix: String(p.code.prefix(2))))
                    }
                }
            }
            .toolbar { doneToolbar }
        }
    }

    private func cityList(_ province: Region) -> some View {
        RegionLevelLoader(parent: province.code, title: province.name) { cities in
            // 市级：前 4 位前缀 = 该市，统计其下已选区县数
            List(cities) { c in
                NavigationLink { areaList(c) } label: {
                    regionRow(c.name, count: selectedCount(prefix: String(c.code.prefix(4))))
                }
            }
        }
        .toolbar { doneToolbar }
    }

    private func areaList(_ city: Region) -> some View {
        RegionLevelLoader(parent: city.code, title: city.name) { areas in
            List(areas) { a in
                Button {
                    if selected.contains(a.code) { selected.remove(a.code) } else { selected.insert(a.code) }
                } label: {
                    HStack {
                        Text(a.name).foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(a.code) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .toolbar { doneToolbar }
    }

    // 每一级都带「完成 (N)」—— 钻进区县子页选完可直接完成，不必逐级返回
    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("完成 (\(selected.count))") { dismiss() }.bold()
        }
    }

    // 国标 code 前缀包含：区县 320106 ⊂ 市 3201xx ⊂ 省 32xxxx。
    // 据此数出某省/市前缀下已选区县个数，做中间层「下含已选 N 个」徽章 —— 顺着徽章钻取即可找到之前的选择。
    private func selectedCount(prefix: String) -> Int {
        selected.filter { $0.hasPrefix(prefix) }.count
    }

    // 中间层行：名字 + 数量徽章（count>0 才显示）；NavigationLink 自带 chevron。
    private func regionRow(_ name: String, count: Int) -> some View {
        HStack {
            Text(name).foregroundStyle(.primary)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
    }
}
