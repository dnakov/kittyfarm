import SwiftUI

struct DevicePickerSheet: View {
    @Bindable var store: KittyFarmStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String> = []
    @State private var initialized = false

    private var groupedDevices: [(DevicePlatform, [DeviceDescriptor])] {
        Dictionary(grouping: store.availableDevices, by: \.platform)
            .map { ($0.key, $0.value.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) }
            .sorted { $0.0.rawValue < $1.0.rawValue }
    }

    private var hasChanges: Bool {
        selectedIDs != Set(store.activeDevices.map(\.id))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedDevices, id: \.0) { platform, devices in
                    Section {
                        ForEach(devices, id: \.id) { device in
                            deviceRow(device)
                        }
                    } header: {
                        platformHeader(platform, devices: devices)
                    }
                }
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                        if hasChanges {
                            Task {
                                await store.applySelection(selectedIDs)
                            }
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.accentColor)
                }
            }
        }
        .task {
            await store.refreshAvailableDevices()
            if !initialized {
                selectedIDs = Set(store.activeDevices.map(\.id))
                initialized = true
            }
        }
    }

    // MARK: - Section Header

    @ViewBuilder
    private func platformHeader(_ platform: DevicePlatform, devices: [DeviceDescriptor]) -> some View {
        HStack {
            Text(platform.rawValue)

            Spacer()

            let platformIDs = Set(devices.map(\.id))
            let allSelected = platformIDs.isSubset(of: selectedIDs)
            Button(allSelected ? "Deselect All" : "Select All") {
                withAnimation(.smooth) {
                    if allSelected {
                        selectedIDs.subtract(platformIDs)
                    } else {
                        selectedIDs.formUnion(platformIDs)
                    }
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Device Row

    @ViewBuilder
    private func deviceRow(_ device: DeviceDescriptor) -> some View {
        let isSelected = selectedIDs.contains(device.id)
        let isActive = store.activeDevices.contains { $0.id == device.id }
        let bootState = store.deviceBootStates[device.id]

        Button {
            withAnimation(.snappy) {
                if isSelected {
                    selectedIDs.remove(device.id)
                } else {
                    selectedIDs.insert(device.id)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Image(systemName: deviceIcon(device))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)

                        if isActive {
                            Text("Active")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .glassEffect(.regular.tint(.green), in: .capsule)
                        }
                    }

                    HStack(spacing: 6) {
                        if let version = device.osVersion {
                            detailPill(version)
                        }

                        if let state = bootState {
                            detailPill(
                                state,
                                color: state == "Booted" ? .green : .secondary
                            )
                        }

                        if let pairing = store.pairingStatus(for: device) {
                            detailPill(
                                pairing,
                                color: pairing.hasPrefix("Paired") ? .blue : .secondary
                            )
                        }

                        detailPill(device.transportDescription)
                    }
                    .font(.caption)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detailPill(_ text: String, color: Color? = nil) -> some View {
        let pillColor = color ?? .secondary
        Text(text)
            .foregroundStyle(pillColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .glassEffect(.regular.tint(pillColor.opacity(0.15)), in: .capsule)
    }

    private func deviceIcon(_ device: DeviceDescriptor) -> String {
        switch device {
        case let .iOSSimulator(_, name, _):
            if name.localizedCaseInsensitiveContains("iPad") {
                return "ipad"
            }
            if name.localizedCaseInsensitiveContains("Watch") {
                return "applewatch"
            }
            if name.localizedCaseInsensitiveContains("TV") {
                return "appletv"
            }
            return "iphone"
        case .androidEmulator:
            return "phone"
        }
    }
}
