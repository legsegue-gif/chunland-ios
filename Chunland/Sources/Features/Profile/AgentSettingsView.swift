import SwiftUI
import ChunlandCore

struct AgentSettingsView: View {
    @EnvironmentObject var auth: AuthManager

    @State private var profile: AgentProfile?
    @State private var bio: String = ""
    @State private var isAvailable: Bool = true
    @State private var serviceAreas: Set<String> = []        // P1 服务区县 code 集合
    @State private var showServiceAreaPicker = false

    @State private var isLoading = true
    @State private var saving = false
    @State private var error: String?
    @State private var savedToast: String?

    var body: some View {
        Form {
            if isLoading && profile == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else {
                availableSection
                serviceAreaSection
                bioSection
                statsSection
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
        }
        .navigationTitle("代购设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView() } else { Text("保存").bold() }
                }
                .disabled(saving || !canSave)
            }
        }
        .overlay(alignment: .top) {
            if let savedToast {
                Text(savedToast)
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { await load() }
        .sheet(isPresented: $showServiceAreaPicker) {
            ServiceAreaPicker(selected: $serviceAreas)
        }
    }

    private var availableSection: some View {
        Section {
            Toggle("接受新订单", isOn: $isAvailable)
        } footer: {
            Text(isAvailable ? "当前可接单，新订单会出现在接单大厅" : "已暂停接单，接单大厅将无法抢单")
        }
    }

    private var serviceAreaSection: some View {
        Section {
            Button {
                showServiceAreaPicker = true
            } label: {
                HStack {
                    Text("服务区县")
                    Spacer()
                    Text(serviceAreas.isEmpty ? "全部区域" : "\(serviceAreas.count) 个区县")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        } header: {
            Text("服务区域")
        } footer: {
            Text(serviceAreas.isEmpty
                 ? "未设置 = 接收全部区域的订单"
                 : "只接收所选区县的订单（无区县信息的老订单仍会推送）")
        }
    }

    private var bioSection: some View {
        Section("自我介绍") {
            TextField("写点什么让买家更了解你（可选）", text: $bio, axis: .vertical)
                .lineLimit(3...6)
        }
    }

    private var statsSection: some View {
        Section("数据") {
            LabeledContent("评分", value: profile.map { String(format: "%.2f", NSDecimalNumber(decimal: $0.rating).doubleValue) } ?? "-")
            LabeledContent("累计订单", value: profile.map { String($0.totalOrders) } ?? "-")
        }
    }

    private var canSave: Bool { true }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let p = try await AgentProfileService.shared.fetch()
            profile = p
            bio = p.bio ?? ""
            isAvailable = p.isAvailable
            serviceAreas = Set(p.serviceAreaCodes)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        error = nil
        saving = true
        defer { saving = false }
        do {
            // 代购费已由平台统一定价，不再提交 serviceFee（列保留作历史/未来接单偏好）。
            let updated = try await AgentProfileService.shared.update(
                bio: bio.isEmpty ? nil : bio,
                isAvailable: isAvailable,
                serviceAreaCodes: Array(serviceAreas)
            )
            profile = updated
            serviceAreas = Set(updated.serviceAreaCodes)
            withAnimation { savedToast = "已保存" }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { savedToast = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
