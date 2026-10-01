import SwiftUI

enum Route: Hashable {
    case tool(String, [InputFile])
    case workflows
}

@MainActor
final class AppModel: ObservableObject {
    @Published var path: [Route] = []
    @Published var incoming: [InputFile] = []
    @Published var showIncoming = false
    @Published var recents: [URL] = []

    init() {
        refreshRecents()
    }

    func open(_ tool: Tool, with inputs: [InputFile] = []) {
        path.append(.tool(tool.id, inputs))
    }

    /// "PDF Atölye ile aç" ya da paylaşım menüsünden gelen dosya.
    func handleOpen(_ url: URL) {
        guard let file = try? InputFile.importing(url) else { return }
        incoming = [file]
        showIncoming = true
    }

    func refreshRecents() {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Storage.results, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        recents = items
            .filter { !$0.hasDirectoryPath }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(12)
            .map { $0 }
    }

    /// Sonuçları Dosyalar uygulamasında görünen belgeler klasörüne kopyalar.
    func keep(_ files: [URL]) -> [URL] {
        let fm = FileManager.default
        var kept: [URL] = []
        for file in files {
            let ext = file.pathExtension
            let base = stem(file.lastPathComponent)
            var target = Storage.results.appendingPathComponent(file.lastPathComponent)
            var counter = 2
            while fm.fileExists(atPath: target.path) {
                target = Storage.results.appendingPathComponent("\(base) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)"))
                counter += 1
            }
            if (try? fm.copyItem(at: file, to: target)) != nil {
                kept.append(target)
            } else {
                kept.append(file)
            }
        }
        refreshRecents()
        return kept
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshRecents()
    }
}
