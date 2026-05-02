import AppKit
import Foundation

final class AndroidEmulatorConnection: DeviceConnection {
    let descriptor: DeviceDescriptor

    private let state: DeviceState
    private let frameService: GRPCFrameService
    private let touchInjector: GRPCTouchInjector

    init(descriptor: DeviceDescriptor, state: DeviceState) {
        self.descriptor = descriptor
        self.state = state
        frameService = GRPCFrameService(descriptor: descriptor)
        touchInjector = GRPCTouchInjector(descriptor: descriptor, state: state)
    }

    func connect() async throws {
        try await frameService.startStreaming(into: state)
    }

    func disconnect() async {
        await frameService.stop()
        let state = self.state
        await MainActor.run {
            state.noteDisconnected()
        }
    }

    func sendTouch(_ touch: NormalizedTouch) async throws {
        try await touchInjector.sendTouch(touch)
    }

    func sendKey(_ keyEvent: DeviceKeyboardEvent) async throws {
        try await touchInjector.sendKey(keyEvent)
    }

    func sendHardwareKeyboardEvent(_ event: NSEvent) async throws {
        guard event.type == .keyDown else {
            return
        }

        try await touchInjector.sendKey(DeviceKeyboardEvent(event: event))
    }

    func setPasteboardText(_ text: String) async throws {
        try await touchInjector.setPasteboardText(text)
    }

    func triggerSimulatorControl(_ identifier: String) async throws {}

    func pressHomeButton() async throws {
        let serial = try await resolveSerial()
        _ = try await runAdb(["-s", serial, "shell", "input", "keyevent", "3"])
    }

    func rotateRight() async throws {
        let serial = try await resolveSerial()
        // `adb emu rotate` rotates the emulator display 90° clockwise via the
        // emulator console. Works regardless of per-app orientation locks and
        // doesn't require disabling auto-rotate or poking system settings.
        _ = try await runAdb(["-s", serial, "emu", "rotate"])
    }

    func openApp(_ nameOrBundleID: String) async throws {
        let serial = try await resolveSerial()

        let packageName = nameOrBundleID.contains(".")
            ? nameOrBundleID
            : try await resolveAndroidPackage(name: nameOrBundleID, serial: serial)

        let activity = try await resolveLauncherActivity(packageName: packageName, serial: serial)
        _ = try await runAdb(["-s", serial, "shell", "am", "start", "-n", activity])
    }

    private func resolveAndroidPackage(name: String, serial: String) async throws -> String {
        let stdout = try await runAdb(["-s", serial, "shell", "pm", "list", "packages"])
        let packages = stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { line -> String? in
                guard line.hasPrefix("package:") else { return nil }
                return String(line.dropFirst("package:".count))
            }

        let needle = name.lowercased()

        // Match on the final component first (most specific), then anywhere in the package name.
        if let exactTail = packages.first(where: { ($0.split(separator: ".").last?.lowercased() ?? "") == needle }) {
            return exactTail
        }
        if let contained = packages.first(where: { $0.lowercased().contains(needle) }) {
            return contained
        }

        throw AndroidLaunchError.appNotFound(name)
    }

    private func resolveLauncherActivity(packageName: String, serial: String) async throws -> String {
        let stdout = try await runAdb([
            "-s", serial,
            "shell", "cmd", "package", "resolve-activity", "--brief", packageName
        ])

        if let activity = stdout
            .split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .last(where: { $0.contains("/") && !$0.contains("No activity") }) {
            return activity
        }

        throw AndroidLaunchError.launcherActivityNotFound(packageName)
    }

    // MARK: - ADB helpers

    private func resolveSerial() async throws -> String {
        guard case let .androidEmulator(avdName, _) = descriptor else {
            throw AndroidEmulatorError.notAnAndroidDevice
        }
        return try await ADBUtils.resolveSerial(avdName: avdName)
    }

    @discardableResult
    private func runAdb(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(.init(
            executableURL: ADBUtils.binaryURL,
            arguments: arguments
        ))
        try result.requireSuccess("adb \(arguments.dropFirst(2).first ?? "")")
        return result.stdout
    }
}

private enum AndroidEmulatorError: LocalizedError {
    case notAnAndroidDevice

    var errorDescription: String? {
        switch self {
        case .notAnAndroidDevice:
            return "Descriptor is not an Android emulator."
        }
    }
}

enum AndroidLaunchError: LocalizedError {
    case appNotFound(String)
    case launcherActivityNotFound(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name): return "No installed Android package matching \"\(name)\"."
        case .launcherActivityNotFound(let packageName): return "No launcher activity found for Android package \"\(packageName)\"."
        }
    }
}
