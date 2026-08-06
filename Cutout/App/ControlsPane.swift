import SwiftUI

struct ControlsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                presetSection
                backdropSection

                if model.settings.preset == .idPhoto {
                    IDControls(model: model)
                }

                exportSection

                if let summary = model.exportSummary {
                    summaryBanner(summary)
                }

                if !model.exportFailures.isEmpty {
                    failureList
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Preset

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Preset")

            Picker("", selection: $model.settings.preset) {
                ForEach(Preset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Text(model.settings.preset.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.settings.preset == .custom {
                HStack(spacing: 6) {
                    NumberField(value: $model.settings.customSize.width, label: "W")
                    Text("×").foregroundStyle(.secondary)
                    NumberField(value: $model.settings.customSize.height, label: "H")
                    Text("px").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Backdrop

    private var backdropSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Backdrop")

            Picker("", selection: backdropKind) {
                Text("Transparent").tag(BackdropKind.transparent)
                Text("White").tag(BackdropKind.white)
                Text("Custom").tag(BackdropKind.custom)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if case .custom(let color) = model.settings.backdrop {
                ColorPicker("Colour",
                            selection: Binding(
                                get: { Color(cgColor: color.cgColor) },
                                set: { newValue in
                                    let resolved = NSColor(newValue)
                                        .usingColorSpace(.sRGB) ?? .white
                                    model.settings.backdrop = .custom(RGBColor(cgColor: resolved.cgColor))
                                }),
                            supportsOpacity: false)
            }

            if model.settings.preset.format == .jpeg,
               model.settings.backdrop == .transparent {
                Label("JPEG has no alpha — this preset will export on white.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private enum BackdropKind: Hashable { case transparent, white, custom }

    private var backdropKind: Binding<BackdropKind> {
        Binding(
            get: {
                switch model.settings.backdrop {
                case .transparent: return .transparent
                case .white: return .white
                case .custom: return .custom
                }
            },
            set: { kind in
                switch kind {
                case .transparent: model.settings.backdrop = .transparent
                case .white: model.settings.backdrop = .white
                case .custom:
                    if case .custom = model.settings.backdrop { return }
                    model.settings.backdrop = .custom(RGBColor(red: 0.94, green: 0.94, blue: 0.94))
                }
            })
    }

    // MARK: - Export

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Export")

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(model.outputFolder?.lastPathComponent ?? "No folder chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout)
                Spacer()
                Button("Change…") { model.chooseOutputFolder() }
                    .controlSize(.small)
            }
            .help(model.outputFolder?.path ?? "Pick where exports are written")

            if model.isExporting {
                ProgressView(value: Double(model.exportCompleted),
                             total: Double(max(1, model.exportTotal))) {
                    Text("Exporting \(model.exportCompleted) of \(model.exportTotal)…")
                        .font(.caption)
                }
            }

            HStack {
                Button {
                    Task { await model.exportAll() }
                } label: {
                    Label("Export \(readyCount) image\(readyCount == 1 ? "" : "s")",
                          systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canExport)
            }

            Text("Originals are never modified or overwritten.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var readyCount: Int {
        model.items.filter { $0.state == .ready }.count
    }

    private func summaryBanner(_ summary: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary).font(.callout)
                Button("Show in Finder") { model.revealOutputFolder() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(model.exportFailures, id: \.self) { failure in
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Small pieces

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct NumberField: View {
    @Binding var value: CGFloat
    let label: String

    var body: some View {
        // Bridged through Double because CGFloat has no `.number` format style.
        TextField(label,
                  value: Binding(get: { Double(value) }, set: { value = CGFloat(max(1, $0)) }),
                  format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 68)
            .multilineTextAlignment(.trailing)
    }
}
