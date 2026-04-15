import CoreGraphics
import Foundation
import ScreenCaptureKit

struct SimulatorWindowMatch {
    let window: SCWindow
    let windowID: CGWindowID
    let pid: pid_t
    let bounds: CGRect
}

struct SimulatorWindowMatcher {
    func matchWindow(for descriptor: DeviceDescriptor) async throws -> SimulatorWindowMatch {
        guard case let .iOSSimulator(_, name, _) = descriptor else {
            throw SimulatorWindowMatcherError.unsupportedDescriptor
        }

        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let matchingWindows = shareableContent.windows.filter { window in
            window.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator"
            && (window.title?.localizedCaseInsensitiveContains(name) ?? false)
        }

        if let match = matchingWindows.first, let geometry = geometry(forWindowID: CGWindowID(match.windowID)) {
            return SimulatorWindowMatch(
                window: match,
                windowID: CGWindowID(match.windowID),
                pid: geometry.pid,
                bounds: geometry.bounds
            )
        }

        throw SimulatorWindowMatcherError.windowNotFound(name)
    }

    private func geometry(forWindowID windowID: CGWindowID) -> (pid: pid_t, bounds: CGRect)? {
        guard
            let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
            let first = windowInfo.first,
            let pid = first[kCGWindowOwnerPID as String] as? pid_t,
            let boundsDict = first[kCGWindowBounds as String] as! CFDictionary?,
            let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else {
            return nil
        }

        return (pid, bounds)
    }
}

enum SimulatorWindowMatcherError: LocalizedError {
    case unsupportedDescriptor
    case windowNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDescriptor:
            return "SimulatorWindowMatcher only supports iOS simulator descriptors."
        case let .windowNotFound(name):
            return "Unable to find a visible Simulator window for \(name). Boot the simulator and keep its window open."
        }
    }
}
