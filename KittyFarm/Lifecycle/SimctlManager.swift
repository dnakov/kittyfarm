import Foundation

struct SimulatorInfo {
    let descriptor: DeviceDescriptor
    let bootState: String
}

struct SimulatorPairInfo: Hashable, Identifiable, Sendable {
    let id: String
    let watch: PairedSimulatorDevice
    let phone: PairedSimulatorDevice
    let state: String

    func includes(_ descriptor: DeviceDescriptor) -> Bool {
        guard let udid = descriptor.iosUDID else { return false }
        return watch.udid == udid || phone.udid == udid
    }

    func companionName(for descriptor: DeviceDescriptor) -> String? {
        guard let udid = descriptor.iosUDID else { return nil }
        if watch.udid == udid {
            return phone.name
        }
        if phone.udid == udid {
            return watch.name
        }
        return nil
    }
}

struct PairedSimulatorDevice: Hashable, Sendable {
    let name: String
    let udid: String
    let state: String
}

struct SimctlManager {
    private let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")

    func listDevices() async throws -> [SimulatorInfo] {
        let result = try await ProcessRunner.run(.init(executableURL: xcrunURL, arguments: ["simctl", "list", "devices", "--json"]))
        try result.requireSuccess("simctl list devices")

        let decoded = try JSONDecoder().decode(SimctlListResponse.self, from: Data(result.stdout.utf8))
        return decoded.devices.flatMap { (runtimeKey, devices) -> [SimulatorInfo] in
            let runtime = Self.parseRuntime(runtimeKey)
            return devices
                .filter { $0.isAvailable }
                .map {
                    SimulatorInfo(
                        descriptor: .iOSSimulator(udid: $0.udid, name: $0.name, runtime: runtime),
                        bootState: $0.state
                    )
                }
        }
    }

    func listDevicePairs() async throws -> [SimulatorPairInfo] {
        let result = try await ProcessRunner.run(.init(executableURL: xcrunURL, arguments: ["simctl", "list", "pairs", "--json"]))
        try result.requireSuccess("simctl list pairs")
        return try Self.decodeDevicePairs(from: Data(result.stdout.utf8))
    }

    func ensurePaired(watch: DeviceDescriptor, phone: DeviceDescriptor) async throws -> SimulatorPairInfo {
        guard let watchUDID = watch.iosUDID, watch.isWatchSimulator else {
            throw SimctlManagerError.invalidPairDevice("\(watch.displayName) is not an Apple Watch simulator.")
        }
        guard let phoneUDID = phone.iosUDID, phone.isIPhoneSimulator else {
            throw SimctlManagerError.invalidPairDevice("\(phone.displayName) is not an iPhone simulator.")
        }

        if let existing = try await listDevicePairs().first(where: { $0.watch.udid == watchUDID && $0.phone.udid == phoneUDID }) {
            try await activatePair(existing.id)
            return existing
        }

        let result = try await ProcessRunner.run(.init(executableURL: xcrunURL, arguments: ["simctl", "pair", watchUDID, phoneUDID]))
        try result.requireSuccess("simctl pair \(watchUDID) \(phoneUDID)")

        guard let pair = try await listDevicePairs().first(where: { $0.watch.udid == watchUDID && $0.phone.udid == phoneUDID }) else {
            throw SimctlManagerError.pairNotFound(watch: watch.displayName, phone: phone.displayName)
        }

        try await activatePair(pair.id)
        return pair
    }

    func activatePair(_ pairID: String) async throws {
        let result = try await ProcessRunner.run(.init(executableURL: xcrunURL, arguments: ["simctl", "pair_activate", pairID]))
        try result.requireSuccess("simctl pair_activate \(pairID)")
    }

    func ensureSimulatorReady(_ descriptor: DeviceDescriptor) async throws {
        guard case let .iOSSimulator(udid, _, _) = descriptor else {
            return
        }

        try await Task.detached(priority: .userInitiated) {
            try PrivateSimulatorBooter.bootDevice(udid: udid)
        }.value

        let statusResult = try await ProcessRunner.run(.init(executableURL: xcrunURL, arguments: ["simctl", "bootstatus", udid, "-b"]))
        try statusResult.requireSuccess("simctl bootstatus \(udid)")
    }

    func setPasteboard(_ text: String, for descriptor: DeviceDescriptor) async throws {
        guard case let .iOSSimulator(udid, _, _) = descriptor else {
            return
        }

        let result = try await ProcessRunner.run(
            .init(
                executableURL: xcrunURL,
                arguments: ["simctl", "pbcopy", udid],
                stdinData: Data(text.utf8)
            )
        )
        try result.requireSuccess("simctl pbcopy \(udid)")
    }

    private static func parseRuntime(_ key: String) -> String {
        let stripped = key.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        let parts = stripped.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return stripped }
        let version = parts[1].replacingOccurrences(of: "-", with: ".")
        return "\(parts[0]) \(version)"
    }

    static func decodeDevicePairs(from data: Data) throws -> [SimulatorPairInfo] {
        let decoded = try JSONDecoder().decode(SimctlPairListResponse.self, from: data)
        return decoded.pairs
            .map { pairID, pair in
                SimulatorPairInfo(
                    id: pairID,
                    watch: PairedSimulatorDevice(
                        name: pair.watch.name,
                        udid: pair.watch.udid,
                        state: pair.watch.state
                    ),
                    phone: PairedSimulatorDevice(
                        name: pair.phone.name,
                        udid: pair.phone.udid,
                        state: pair.phone.state
                    ),
                    state: pair.state
                )
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

private struct SimctlListResponse: Decodable {
    let devices: [String: [SimctlDevice]]
}

private struct SimctlDevice: Decodable {
    let name: String
    let udid: String
    let isAvailable: Bool
    let state: String
}

private struct SimctlPairListResponse: Decodable {
    let pairs: [String: SimctlDevicePair]
}

private struct SimctlDevicePair: Decodable {
    let watch: SimctlPairedDevice
    let phone: SimctlPairedDevice
    let state: String
}

private struct SimctlPairedDevice: Decodable {
    let name: String
    let udid: String
    let state: String
}

enum SimctlManagerError: LocalizedError {
    case invalidPairDevice(String)
    case pairNotFound(watch: String, phone: String)

    var errorDescription: String? {
        switch self {
        case let .invalidPairDevice(message):
            return message
        case let .pairNotFound(watch, phone):
            return "Could not find the simulator pair for \(watch) and \(phone) after pairing."
        }
    }
}
