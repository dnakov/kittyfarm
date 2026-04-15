import SwiftUI
import UniformTypeIdentifiers

struct DeviceGridView: View {
    @Bindable var store: KittyFarmStore
    @State private var draggedDeviceID: String?

    var body: some View {
        Group {
            if store.activeDevices.isEmpty {
                VStack(spacing: 16) {
                    if let url = Bundle.main.url(forResource: "kittyfarm", withExtension: "png"),
                       let nsImage = NSImage(contentsOf: url) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 200)
                            .opacity(0.6)
                    }

                    Text(store.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    ScrollView {
                        MasonryLayout(
                            columnMinWidth: 220,
                            spacing: 16,
                            availableHeight: geo.size.height - 40
                        ) {
                            ForEach(store.activeDevices, id: \.id) { state in
                                DevicePaneView(
                                    state: state,
                                    isLeader: store.leaderID == state.id,
                                    store: store,
                                    draggedDeviceID: $draggedDeviceID
                                )
                                .onDrop(
                                    of: [UTType.text],
                                    delegate: DeviceDropDelegate(
                                        targetID: state.id,
                                        store: store,
                                        draggedDeviceID: $draggedDeviceID
                                    )
                                )
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                                    removal: .scale(scale: 0.9).combined(with: .opacity)
                                ))
                            }
                        }
                        .padding(20)
                        .animation(.bouncy, value: store.activeDevices.map(\.id))
                    }
                }
            }
        }
        .background(.clear)
    }
}

struct DeviceDropDelegate: DropDelegate {
    let targetID: String
    let store: KittyFarmStore
    @Binding var draggedDeviceID: String?

    func performDrop(info: DropInfo) -> Bool {
        draggedDeviceID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedID = draggedDeviceID, draggedID != targetID else { return }
        withAnimation(.snappy) {
            store.moveDevice(draggedID, before: targetID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedDeviceID != nil
    }
}
