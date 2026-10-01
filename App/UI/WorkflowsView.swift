import SwiftUI
import UniformTypeIdentifiers

/// Masaüstüyle aynı kurallar: en fazla 8 adım, 20 kayıt; her adım bir öncekinin çıktısını kullanır.
struct WorkflowStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var tool: String
    var options: OptionValues
}

struct WorkflowRecipe: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var steps: [WorkflowStep]
}

enum WorkflowStore {
    static let allowed = ["page_numbers", "compress", "rotate", "grayscale", "flatten"]
    private static let key = "pdf-atolye-workflows-v1"

    static func load() -> [WorkflowRecipe] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let recipes = try? JSONDecoder().decode([WorkflowRecipe].self, from: data) else {
            return [example]
        }
        return recipes.filter { $0.steps.count <= 8 && $0.steps.allSatisfy { allowed.contains($0.tool) } }
    }

    static func save(_ recipes: [WorkflowRecipe]) {
        if let data = try? JSONEncoder().encode(Array(recipes.prefix(20))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func step(_ id: String) -> WorkflowStep {
        WorkflowStep(tool: id, options: OptionValues(defaultsOf: Catalog.tool(id)?.options ?? []))
    }

    static var example: WorkflowRecipe {
        WorkflowRecipe(name: "Numarala ve sıkıştır", steps: [step("page_numbers"), step("compress")])
    }
}

struct WorkflowsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var recipes = WorkflowStore.load()
    @State private var editing: WorkflowRecipe?
    @State private var running: WorkflowRecipe?
    @State private var importing = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var result: ResultBox?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    GradientIcon(symbol: "flowchart", colors: Brand.colors, size: 48)
                    Text("Bir PDF'e sırayla birkaç işlem uygula. Her adım bir öncekinin çıktısını kullanır; akışlar bu cihazda saklanır.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section("Kayıtlı akışlar") {
                ForEach(recipes) { recipe in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recipe.name).font(.headline)
                            Text(recipe.steps.compactMap { Catalog.tool($0.tool)?.name }.joined(separator: " → "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button {
                            running = recipe
                            importing = true
                        } label: {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Brand.gradient))
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .accessibilityLabel("\(recipe.name) akışını çalıştır")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = recipe }
                    .swipeActions {
                        Button(role: .destructive) {
                            recipes.removeAll { $0.id == recipe.id }
                            WorkflowStore.save(recipes)
                        } label: {
                            Label("Sil", systemImage: "trash")
                        }
                    }
                }
                Button {
                    editing = WorkflowRecipe(name: "Yeni akış", steps: [WorkflowStore.step("compress")])
                } label: {
                    Label("Yeni iş akışı", systemImage: "plus.circle.fill")
                }
            }
            if busy {
                Section {
                    ProgressView(value: progress) { Text(status).font(.caption) }
                }
            }
            if let errorText {
                Section { Banner(kind: .error, text: errorText) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle("İş akışları")
        .sheet(item: $editing) { recipe in
            WorkflowEditor(recipe: recipe) { saved in
                if let index = recipes.firstIndex(where: { $0.id == saved.id }) {
                    recipes[index] = saved
                } else {
                    recipes.insert(saved, at: 0)
                }
                WorkflowStore.save(recipes)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { outcome in
            guard case .success(let url) = outcome, let recipe = running else { return }
            Task { @MainActor in await run(recipe, url: url) }
        }
        .navigationDestination(item: $result) { box in
            ResultView(box: box)
        }
    }

    private func run(_ recipe: WorkflowRecipe, url: URL) async {
        errorText = nil
        busy = true
        defer { busy = false }
        do {
            var current = try InputFile.importing(url)
            var last: ToolResult?
            var lastTool: Tool?
            for (index, step) in recipe.steps.enumerated() {
                guard let tool = Catalog.tool(step.tool) else { continue }
                status = "\(index + 1)/\(recipe.steps.count) · \(tool.name)"
                progress = Double(index) / Double(recipe.steps.count)
                let output = try await Engine.run(tool: tool, inputs: [current], options: step.options)
                guard let file = output.files.first else { throw ToolError("\(tool.name) sonuç üretmedi.") }
                current = InputFile(url: file, kind: .pdf, name: file.lastPathComponent)
                last = output
                lastTool = tool
            }
            guard var final = last, let tool = lastTool else { return }
            final.files = model.keep(final.files)
            result = ResultBox(tool: tool, result: final)
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct WorkflowEditor: View {
    @State var recipe: WorkflowRecipe
    let onSave: (WorkflowRecipe) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Akış adı") {
                    TextField("Ad", text: $recipe.name)
                }
                ForEach($recipe.steps) { $step in
                    if let tool = Catalog.tool(step.tool) {
                        Section {
                            ForEach(tool.options.filter { $0.visible(step.options) }) { option in
                                OptionRow(option: option, values: $step.options)
                            }
                        } header: {
                            HStack {
                                Text("\((recipe.steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1). \(tool.name)")
                                Spacer()
                                Button {
                                    moveUp(step)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .disabled(recipe.steps.first?.id == step.id)
                                Button(role: .destructive) {
                                    recipe.steps.removeAll { $0.id == step.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                }
                Section {
                    Menu {
                        ForEach(WorkflowStore.allowed, id: \.self) { id in
                            Button(Catalog.tool(id)?.name ?? id) { recipe.steps.append(WorkflowStore.step(id)) }
                        }
                    } label: {
                        Label("Adım ekle", systemImage: "plus.circle.fill")
                    }
                    .disabled(recipe.steps.count >= 8)
                } footer: {
                    Text("En fazla 8 adım eklenebilir.")
                }
            }
            .navigationTitle("İş akışı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        recipe.name = recipe.name.trimmingCharacters(in: .whitespaces)
                        onSave(recipe)
                        dismiss()
                    }
                    .bold()
                    .disabled(recipe.steps.isEmpty || recipe.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func moveUp(_ step: WorkflowStep) {
        guard let index = recipe.steps.firstIndex(where: { $0.id == step.id }), index > 0 else { return }
        recipe.steps.swapAt(index, index - 1)
    }
}
