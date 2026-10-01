import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Bir seçeneği türüne uygun iOS denetimiyle gösterir.
struct OptionRow: View {
    let option: ToolOption
    @Binding var values: OptionValues
    @State private var photo: PhotosPickerItem?
    @State private var importingCertificate = false

    var body: some View {
        switch option.kind {
        case .text(let placeholder):
            labeled {
                TextField(placeholder ?? option.label, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        case .textarea(let placeholder):
            labeled {
                TextField(placeholder ?? option.label, text: text, axis: .vertical)
                    .lineLimit(3...8)
            }
        case .password:
            labeled {
                SecureField(option.label, text: text)
            }
        case .check:
            Toggle(option.label, isOn: bool)
        case .number(let min, let max, let step):
            numberRow(min: min ?? 0, max: max ?? 100_000, step: step)
        case .range(let min, let max, let step, let percent):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(option.label)
                    Spacer()
                    Text(percent ? "%\(Int((number.wrappedValue * 100).rounded()))" : "\(Int(number.wrappedValue.rounded()))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: number, in: min...max, step: step)
            }
        case .segmented(let choices):
            labeled {
                Picker(option.label, selection: text) {
                    ForEach(choices) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.segmented)
            }
        case .select(let choices):
            Picker(option.label, selection: text) {
                ForEach(choices) { Text($0.label).tag($0.value) }
            }
        case .cards(let choices):
            labeled {
                VStack(spacing: 8) {
                    ForEach(choices) { choice in
                        cardButton(choice)
                    }
                }
            }
        case .color:
            ColorPicker(option.label, selection: color, supportsOpacity: false)
        case .position(let tile):
            labeled {
                PositionPicker(selection: text, allowsTile: tile)
            }
        case .checks(let choices):
            labeled {
                ChipFlow(choices: choices, selection: list)
            }
        case .pairs:
            PairsEditor(pairs: pairs)
        case .font:
            Picker(option.label, selection: text) {
                ForEach(Fonts.families, id: \.self) { family in
                    Text(family).font(.custom(family, size: 16)).tag(family)
                }
            }
        case .image:
            imagePicker
        case .certificate:
            certificatePicker
        case .note(let note):
            Label(note, systemImage: "lightbulb")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Parçalar

    private func labeled<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(option.label)
                .font(.subheadline.weight(.medium))
            content()
            if let hint = option.hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func numberRow(min: Double, max: Double, step: Double) -> some View {
        HStack {
            Text(option.label)
            Spacer()
            TextField("", value: number, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .foregroundStyle(.secondary)
            Stepper(option.label, value: number, in: min...max, step: step)
                .labelsHidden()
        }
    }

    private func cardButton(_ choice: Choice) -> some View {
        let selected = text.wrappedValue == choice.value
        return Button {
            withAnimation(.snappy) { text.wrappedValue = choice.value }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if let detail = choice.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private var imagePicker: some View {
        HStack {
            Text(option.label)
            Spacer()
            if let data = values.data(option.key), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            PhotosPicker(selection: $photo, matching: .images) {
                Text(values.data(option.key) == nil ? "Seç" : "Değiştir")
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self) {
                    values[option.key] = .data(data)
                }
            }
        }
    }

    private var certificatePicker: some View {
        HStack {
            Text(option.label)
            Spacer()
            Button(values.url(option.key)?.lastPathComponent ?? "Seç") {
                importingCertificate = true
            }
            .lineLimit(1)
        }
        .fileImporter(isPresented: $importingCertificate, allowedContentTypes: FileKind.certificate.contentTypes) { result in
            if case .success(let url) = result, let file = try? InputFile.importing(url, as: .certificate) {
                values[option.key] = .file(file.url)
            }
        }
    }

    // MARK: Bağlamalar

    private var text: Binding<String> {
        Binding(get: { values.string(option.key) }, set: { values[option.key] = .string($0) })
    }

    private var bool: Binding<Bool> {
        Binding(get: { values.bool(option.key) }, set: { values[option.key] = .bool($0) })
    }

    private var number: Binding<Double> {
        Binding(get: { values.number(option.key, 0) }, set: { values[option.key] = .number($0) })
    }

    private var list: Binding<[String]> {
        Binding(get: { values.list(option.key) }, set: { values[option.key] = .list($0) })
    }

    private var pairs: Binding<[ReplacePair]> {
        Binding(get: { values.pairs(option.key) }, set: { values[option.key] = .pairs($0) })
    }

    private var color: Binding<Color> {
        Binding(get: { Color(uiColor: UIColor(hex: values.string(option.key, "#000000"))) },
                set: { values[option.key] = .string(UIColor($0).hex) })
    }
}

/// 3×3 konum seçici; isteğe bağlı "döşe" seçeneği.
struct PositionPicker: View {
    @Binding var selection: String
    let allowsTile: Bool
    private let rows = ["top", "middle", "bottom"]
    private let columns = ["left", "center", "right"]

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(spacing: 6) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(columns, id: \.self) { column in
                            let value = "\(row)-\(column)"
                            Button {
                                withAnimation(.snappy) { selection = value }
                            } label: {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selection == value ? Color.accentColor : Color(.tertiarySystemGroupedBackground))
                                    .frame(width: 34, height: 26)
                                    .overlay(Circle().fill(selection == value ? Color.white : Color.secondary).frame(width: 6, height: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            if allowsTile {
                Button {
                    withAnimation(.snappy) { selection = selection == "tile" ? "middle-center" : "tile" }
                } label: {
                    Label("Döşe", systemImage: "square.grid.3x3.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(selection == "tile" ? Color.accentColor : Color(.tertiarySystemGroupedBackground)))
                        .foregroundStyle(selection == "tile" ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Çoklu seçim çipleri.
struct ChipFlow: View {
    let choices: [Choice]
    @Binding var selection: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(choices) { choice in
                let on = selection.contains(choice.value)
                Button {
                    withAnimation(.snappy) {
                        if on { selection.removeAll { $0 == choice.value } } else { selection.append(choice.value) }
                    }
                } label: {
                    Label(choice.label, systemImage: on ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Capsule().fill(on ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemGroupedBackground)))
                        .foregroundStyle(on ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Bul ve değiştir çiftleri.
struct PairsEditor: View {
    @Binding var pairs: [ReplacePair]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Değişiklikler").font(.subheadline.weight(.medium))
            ForEach($pairs) { $pair in
                HStack(spacing: 8) {
                    TextField("Bul", text: $pair.find)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Değiştir", text: $pair.replace)
                        .textFieldStyle(.roundedBorder)
                    if pairs.count > 1 {
                        Button {
                            pairs.removeAll { $0.id == pair.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                pairs.append(ReplacePair())
            } label: {
                Label("Değişiklik ekle", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }
}
