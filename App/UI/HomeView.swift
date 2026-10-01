import QuickLook
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var category: String?
    @State private var preview: URL?

    private let columns = [GridItem(.adaptive(minimum: 158, maximum: 260), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if search.isEmpty {
                    hero
                    quickActions
                    if !model.recents.isEmpty { recents }
                }
                categoryBar
                if search.isEmpty && category == nil {
                    ForEach(Catalog.categories) { section($0) }
                    workflows
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    grid(filtered)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("PDF Atölye")
        .searchable(text: $search, prompt: "Araç ara: birleştir, imza, form…")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AboutView()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Hakkında ve gizlilik")
            }
        }
        .quickLookPreview($preview, in: model.recents)
        .onAppear { model.refreshRecents() }
    }

    private var filtered: [Tool] {
        let query = fold(search)
        return Catalog.tools.filter { tool in
            (category == nil || tool.category == category) &&
                (query.isEmpty || fold(tool.name + " " + tool.summary + " " + tool.categoryInfo.name).contains(query))
        }
    }

    private func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .trimmingCharacters(in: .whitespaces)
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Brand.gradient)
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 120, weight: .bold))
                .foregroundStyle(.white.opacity(0.12))
                .rotationEffect(.degrees(-12))
                .offset(x: 210, y: -18)
            VStack(alignment: .leading, spacing: 10) {
                Label("Dosyaların cihazından çıkmaz", systemImage: "lock.shield.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.2)))
                Text("Tüm PDF araçları\ncebinde.")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text("\(Catalog.tools.count) araç · çevrimdışı çalışır · hesap gerekmez")
                    .font(.subheadline)
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(22)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Brand.colors[1].opacity(0.35), radius: 18, y: 10)
        .padding(.top, 4)
    }

    private var quickActions: some View {
        let ids = ["scan", "merge", "compress", "sign"]
        return VStack(alignment: .leading, spacing: 12) {
            Text("Hızlı başla").font(.title3.weight(.bold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(ids.compactMap(Catalog.tool), id: \.id) { tool in
                    NavigationLink(value: Route.tool(tool.id, [])) {
                        HStack(spacing: 12) {
                            Image(systemName: tool.symbol)
                                .font(.title3.weight(.semibold))
                                .frame(width: 30)
                            Text(tool.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tool.categoryInfo.gradient))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Son sonuçlar").font(.title3.weight(.bold))
                Spacer()
                Text("Dosyalar › PDF Atölye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.recents, id: \.self) { url in
                        Button {
                            preview = url
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                FileThumbnail(url: url, size: CGSize(width: 96, height: 120))
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .frame(width: 96, alignment: .leading)
                            }
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu {
                            ShareLink(item: url)
                            Button(role: .destructive) {
                                model.delete(url)
                            } label: {
                                Label("Sil", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var workflows: some View {
        NavigationLink(value: Route.workflows) {
            HStack(spacing: 14) {
                GradientIcon(symbol: "flowchart", colors: Brand.colors, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("İş akışları").font(.headline).foregroundStyle(.primary)
                    Text("Numarala, sıkıştır, döndür… birkaç adımı tek dokunuşla uygula.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(PressableStyle())
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "Tümü", symbol: "square.grid.2x2.fill", colors: Brand.colors, selected: category == nil) {
                    category = nil
                }
                ForEach(Catalog.categories) { item in
                    chip(title: item.name, symbol: item.symbol, colors: item.colors, selected: category == item.id) {
                        category = category == item.id ? nil : item.id
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .sensoryFeedback(.selection, trigger: category)
    }

    private func chip(title: String, symbol: String, colors: [Color], selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background {
                    if selected {
                        Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    } else {
                        Capsule().fill(Color(.secondarySystemGroupedBackground))
                    }
                }
        }
        .buttonStyle(PressableStyle())
    }

    private func section(_ category: ToolCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GradientIcon(symbol: category.symbol, colors: category.colors, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.name).font(.title3.weight(.bold))
                    Text(category.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            grid(Catalog.tools.filter { $0.category == category.id })
        }
    }

    private func grid(_ tools: [Tool]) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(tools) { tool in
                NavigationLink(value: Route.tool(tool.id, [])) {
                    ToolCard(tool: tool)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}
