import Foundation

struct LocalControlConfig: Codable, Sendable {
    let baseURL: String
    let mcpURL: String
    let token: String
}

struct LocalControlStatusResponse: Codable, Sendable {
    let ok: Bool
    let version: String
    let availableDeviceCount: Int
    let activeDeviceCount: Int
    let selectedIOSProject: IOSProjectConfiguration?
    let selectedAndroidProject: AndroidProjectConfiguration?
    let statusMessage: String
}

struct LocalControlDeviceDTO: Codable, Sendable {
    let id: String
    let platform: String
    let displayName: String
    let subtitle: String
    let isActive: Bool
    let isConnected: Bool
    let isConnecting: Bool
    let frameWidth: Int?
    let frameHeight: Int?
    let fps: Double
    let latencyMs: Double
    let lastError: String?
}

struct LocalControlDevicesResponse: Codable, Sendable {
    let available: [LocalControlDeviceDTO]
    let active: [LocalControlDeviceDTO]
}

struct LocalControlOKResponse: Codable, Sendable {
    let ok: Bool
    let message: String
}

struct LocalControlErrorResponse: Codable, Sendable {
    let error: String
}

struct LocalControlLogsResponse: Codable, Sendable {
    let logs: [LocalControlLogDTO]
}

struct LocalControlLogDTO: Codable, Sendable {
    let id: String
    let timestamp: Date
    let source: String
    let severity: String
    let scope: String
    let message: String
}

struct LocalControlConnectRequest: Codable, Sendable {
    let deviceId: String
}

struct LocalControlDeviceRequest: Codable, Sendable {
    let deviceId: String
}

struct LocalControlAccessibilityRequest: Codable, Sendable {
    let deviceId: String
    let bundleId: String?
}

struct LocalControlTapRequest: Codable, Sendable {
    let deviceId: String
    let x: Double?
    let y: Double?
    let query: String?
    let bundleId: String?
}

struct LocalControlSwipeRequest: Codable, Sendable {
    let deviceId: String
    let direction: String?
    let startX: Double?
    let startY: Double?
    let endX: Double?
    let endY: Double?
    let query: String?
    let bundleId: String?
}

struct LocalControlTypeRequest: Codable, Sendable {
    let deviceId: String
    let text: String
    let query: String?
    let bundleId: String?
}

struct LocalControlOpenAppRequest: Codable, Sendable {
    let deviceId: String
    let app: String
}

struct LocalControlFindElementRequest: Codable, Sendable {
    let deviceId: String
    let query: String
    let bundleId: String?
}

struct LocalControlElementResponse: Codable, Sendable {
    let element: AccessibilityElement
    let normalizedX: Double
    let normalizedY: Double
}

struct LocalControlAssertRequest: Codable, Sendable {
    let deviceId: String
    let query: String
    let bundleId: String?
}

struct LocalControlWaitRequest: Codable, Sendable {
    let deviceId: String
    let query: String
    let timeout: TimeInterval?
    let bundleId: String?
}

struct LocalControlDiscoverProjectRequest: Codable, Sendable {
    let path: String
    let platform: String?
}

struct LocalControlDiscoverProjectResponse: Codable, Sendable {
    let ios: IOSProjectConfiguration?
    let android: AndroidProjectConfiguration?
}

struct LocalControlBuildRunRequest: Codable, Sendable {
    let iosProjectPath: String?
    let androidProjectPath: String?
    let deviceIds: [String]?
}

struct LocalControlScreenshotResponse: Codable, Sendable {
    let deviceId: String
    let width: Int
    let height: Int
    let mimeType: String
    let base64: String
}
