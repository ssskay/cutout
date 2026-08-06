import SwiftUI
import UniformTypeIdentifiers

@main
struct CutoutApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Cutout", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Images…") { openPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Export All…") {
                    Task { await model.exportAll() }
                }
                .keyboardShortcut("e")
                .disabled(!model.canExport)

                Button("Choose Export Folder…") { model.chooseOutputFolder() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])

                Divider()

                Button("Remove All Images") { model.removeAll() }
                    .disabled(model.items.isEmpty)
            }
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            model.add(urls: panel.urls)
        }
    }
}
