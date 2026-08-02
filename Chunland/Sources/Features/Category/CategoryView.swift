import SwiftUI
import ChunlandCore

private typealias ProductCategory = ChunlandCore.Category

struct CategoryView: View {
    @State private var categories: [ProductCategory] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selected: ProductCategory?

    var body: some View {
        NavigationSplitView {
            Group {
                if isLoading {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else {
                    List(categories, selection: $selected) { cat in
                        Button {
                            selected = cat
                        } label: {
                            HStack {
                                Text(cat.name).foregroundStyle(.primary)
                                Spacer()
                                if !cat.children.isEmpty {
                                    Text("\(cat.children.count)").font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .listRowBackground(selected?.code == cat.code
                            ? Color.accentColor.opacity(0.1) : Color.clear)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("分类")
            .task { await load() }
        } detail: {
            if let selected {
                SubcategoryGrid(category: selected)
            } else {
                ContentUnavailableView("选择分类", systemImage: "square.grid.2x2")
            }
        }
    }

    private func load() async {
        isLoading = true
        do {
            categories = try await CategoryService.shared.tree()
                .filter { $0.level == 1 }
                .sorted { ($0.sequence ?? 999) < ($1.sequence ?? 999) }
            if selected == nil { selected = categories.first }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

private struct SubcategoryGrid: View {
    let category: ProductCategory

    var body: some View {
        ScrollView {
            if category.children.isEmpty {
                NavigationLink(destination: ProductListView(category: category.code, title: category.name)) {
                    Label("查看全部商品", systemImage: "arrow.right.circle")
                        .padding()
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 16) {
                    NavigationLink(destination: ProductListView(category: category.code, title: category.name)) {
                        SubcategoryCell(name: "全部", code: "ALL")
                    }
                    .buttonStyle(.plain)

                    ForEach(category.children.sorted { ($0.sequence ?? 999) < ($1.sequence ?? 999) }) { sub in
                        NavigationLink(destination: ProductListView(category: sub.code, title: sub.name)) {
                            SubcategoryCell(name: sub.name, code: sub.code)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct SubcategoryCell: View {
    let name: String
    let code: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 56, height: 56)
                Text(String(name.prefix(2)))
                    .font(.title3).bold()
                    .foregroundStyle(Color.accentColor)
            }
            Text(name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}
