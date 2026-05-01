import Darwin
import Foundation
import Network

enum EmulatorLaunchError: LocalizedError {
    case grpcNotReady(avdName: String, port: Int)
    case emulatorExited(avdName: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case let .grpcNotReady(avdName, port):
            return "Android emulator \(avdName) did not expose gRPC on a loopback address for port \(port) in time."
        case let .emulatorExited(avdName, status):
            return "Android emulator \(avdName) exited before gRPC became ready (exit \(status))."
        }
    }
}

private final class EmulatorPortProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Bool, Never>
    private var finished = false

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        connection.cancel()
        continuation.resume(returning: value)
    }
}

actor EmulatorManager {
    private let loopbackHosts = ["localhost", "::1", "127.0.0.1"]
    private var launchedProcesses: [String: Process] = [:]

    func listAVDs() async throws -> [DeviceDescriptor] {
        let result = try await ProcessRunner.run(.init(executableURL: emulatorBinaryURL, arguments: ["-list-avds"]))
        try result.requireSuccess("emulator -list-avds")

        let names = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return names.enumerated().map { index, name in
            .androidEmulator(avdName: name, grpcPort: 8554 + index)
        }
    }

    func launchIfNeeded(avdName: String, grpcPort: Int) async throws {
        if let existingProcess = launchedProcesses[avdName] {
            if existingProcess.isRunning {
                try await waitForGRPCReady(avdName: avdName, grpcPort: grpcPort, process: existingProcess)
                return
            }

            launchedProcesses.removeValue(forKey: avdName)
        }

        let process = Process()
        process.executableURL = emulatorBinaryURL
        process.arguments = [
            "-avd", avdName,
            "-no-window",
            "-grpc", String(grpcPort)
        ]

        let nullHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        process.standardOutput = nullHandle
        process.standardError = nullHandle

        try process.run()
        launchedProcesses[avdName] = process
        try await waitForGRPCReady(avdName: avdName, grpcPort: grpcPort, process: process)
    }

    func stopLaunchedEmulators(gracePeriod: TimeInterval = 5) async {
        let processes = launchedProcesses
        launchedProcesses.removeAll()

        for process in processes.values where process.isRunning {
            process.terminate()
        }

        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline, processes.values.contains(where: \.isRunning) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        for process in processes.values where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func waitForGRPCReady(avdName: String, grpcPort: Int, process: Process) async throws {
        let deadline = Date().addingTimeInterval(15)

        while Date() < deadline {
            if !process.isRunning {
                launchedProcesses.removeValue(forKey: avdName)
                throw EmulatorLaunchError.emulatorExited(avdName: avdName, status: process.terminationStatus)
            }

            if await isPortOpen(port: grpcPort) {
                return
            }

            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw EmulatorLaunchError.grpcNotReady(avdName: avdName, port: grpcPort)
    }

    private func isPortOpen(port: Int) async -> Bool {
        for host in loopbackHosts {
            if await isPortOpen(host: host, port: port) {
                return true
            }
        }

        return false
    }

    private func isPortOpen(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port)),
                using: .tcp
            )
            let queue = DispatchQueue(label: "KittyFarm.EmulatorPortProbe.\(host).\(port)")
            let probeState = EmulatorPortProbeState(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    probeState.finish(true)
                case .failed, .cancelled:
                    probeState.finish(false)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + .milliseconds(200)) {
                probeState.finish(false)
            }
        }
    }

    private var emulatorBinaryURL: URL {
        ADBUtils.emulatorBinaryURL
    }
}
