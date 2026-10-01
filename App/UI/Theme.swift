import SwiftUI

enum Brand {
    static let colors = [Color(red: 0.0, green: 0.62, blue: 0.86), Color(red: 0.25, green: 0.36, blue: 0.98), Color(red: 0.55, green: 0.24, blue: 0.95)]
    static let gradient = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tint = Color(red: 0.16, green: 0.42, blue: 0.98)
}

/// Yuvarlatılmış kare içinde geçişli renkli SF Symbol.
struct GradientIcon: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            .shadow(color: (colors.first ?? .blue).opacity(0.35), radius: size * 0.18, y: size * 0.08)
    }
}

/// Basınca hafifçe küçülen kart davranışı.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
    }
}

struct ToolCard: View {
    let tool: Tool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                GradientIcon(symbol: tool.symbol, colors: tool.categoryInfo.colors, size: 42)
                Spacer()
                if !Engine.available.contains(tool.id) {
                    Text("Yakında")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .foregroundStyle(.secondary)
                }
            }
            Text(tool.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(tool.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Uyarı/bilgi kutusu.
struct Banner: View {
    enum Kind { case warning, info, error }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.body.weight(.semibold))
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(color.opacity(0.12)))
    }

    private var symbol: String {
        switch kind {
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .warning: return .orange
        case .info: return .blue
        case .error: return .red
        }
    }
}

extension Int64 {
    var fileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension URL {
    var fileSize: Int64 {
        Int64((try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
