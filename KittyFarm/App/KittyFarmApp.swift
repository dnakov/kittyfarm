import SwiftUI

@main
struct KittyFarmApp: App {
    @State private var store = KittyFarmStore()

    var body: some Scene {
        WindowGroup("KittyFarm") {
            ContentView(store: store)
                .frame(minWidth: 1100, minHeight: 700)
                .containerBackground(.ultraThinMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
