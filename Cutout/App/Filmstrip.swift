import SwiftUI

/// Horizontal strip of every dropped image with its per-file status.
///
/// Batch is the normal case, not an edge case, so status lives here rather than
/// in a modal: a failed file shows its badge next to nineteen successful ones and
/// the run keeps going.
struct Filmstrip: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(model.items) { item in
                    thumbnail(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func thumbnail(_ item: ImageItem) -> some View {
        let isSelected = item.id == model.selectedID

        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .underPageBackgroundColor))

                if let image = item.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                        .padding(3)
                } else if case .failed = item.state {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }

                statusBadge(item)
            }
            .frame(width: 78, height: 68)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: isSelected ? 2.5 : 1)
            }

            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 78)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = item.id }
        .help(item.errorMessage ?? item.name)
        .contextMenu {
            Button("Remove") { model.remove(item) }
            Button("Reprocess") { Task { await model.process(item) } }
        }
    }

    @ViewBuilder
    private func statusBadge(_ item: ImageItem) -> some View {
        let symbol: (String, Color)? = {
            switch item.state {
            case .failed: return ("exclamationmark.circle.fill", .orange)
            case .ready: return item.warnings.isEmpty ? nil : ("exclamationmark.triangle.fill", .yellow)
            case .processing, .pending: return nil
            }
        }()

        if let (name, color) = symbol {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: name)
                        .font(.caption)
                        .foregroundStyle(.white, color)
                        .padding(3)
                }
            }
        }
    }
}
