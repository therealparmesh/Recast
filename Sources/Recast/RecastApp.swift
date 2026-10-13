import SwiftUI
import Sparkle

@main
struct RecastApp: App {
    @State private var model = ConvertModel()
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    var body: some Scene {
        Window("Recast", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 540, minHeight: 480)
                .containerBackground(.thinMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Files…") { model.pickFiles() }
                    .keyboardShortcut("o")
                    .disabled(model.isWorking)
                Button("Choose Save Folder…") { model.pickDestination() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.isWorking)
                Divider()
                Button("Clear Files") { model.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.files.isEmpty || model.isWorking)
                Button("Cancel Conversion") { model.cancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!model.isWorking)
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater.updater)
            }
        }
    }
}

/// "Check for Updates…" menu item, enabled only when Sparkle can currently check.
private struct CheckForUpdatesView: View {
    private let updater: SPUUpdater
    @State private var canCheck = false

    init(updater: SPUUpdater) { self.updater = updater }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!canCheck)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
