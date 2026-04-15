import Foundation

struct SimulatorInfo {
    let descriptor: DeviceDescriptor
    let bootState: String
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
