import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                previewArea
                Divider()
                Filmstrip(model: model)
                    .frame(height: 128)
            }
            .frame(minWidth: 560)

            ControlsPane(model: model)
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 420)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        if model.items.isEmpty {
            DropZone(isTargeted: isDropTargeted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let item = model.selectedItem {
            BeforeAfterView(item: item, backdrop: model.settings.effectiveBackdrop)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No image selected",
                                   systemImage: "photo",
                                   description: Text("Pick one from the filmstrip below."))
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Collect asynchronously, then hand the whole set to the model at once so
        // a twenty-file drop is one batch rather than twenty separate additions.
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            model.add(urls: urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
        return true
    }
}

struct DropZone: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.dashed.inset.filled")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop images here")
                .font(.title2)
            Text("One or twenty. Backgrounds are removed on this Mac — nothing is uploaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
