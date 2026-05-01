import AppKit
import SwiftUI

enum KittyFarmWindow {
    static let documentationSearch = "documentation-search"
}

@main
struct KittyFarmApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate
    @State private var store = KittyFarmStore()

    var body: some Scene {
        WindowGroup("KittyFarm") {
            ContentView(store: store)
                .onAppear {
                    appDelegate.store = store
                }
                .frame(minWidth: 1100, minHeight: 700)
                .containerBackground(.ultraThinMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)

        Window("Documentation Search", id: KittyFarmWindow.documentationSearch) {
            DocumentationSearchView(store: store)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 760)
    }
}

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var store: KittyFarmStore?
    private var isPreparingToTerminate = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate else {
            return .terminateNow
        }

        isPreparingToTerminate = true
        Task { @MainActor [weak self] in
            await self?.store?.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
