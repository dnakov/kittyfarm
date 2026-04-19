import CoreGraphics
import Foundation

enum DevicePlatform: String, CaseIterable, Sendable, Codable {
    case iOSSimulator = "iOS Simulator"
    case androidEmulator = "Android Emulator"
}

enum DeviceDescriptor: Hashable, Identifiable, Sendable {
    case iOSSimulator(udid: String, name: String, runtime: String)
    case androidEmulator(avdName: String, grpcPort: Int)

    var id: String {
        switch self {
        case let .iOSSimulator(udid, _, _):
            return "ios-\(udid)"
        case let .androidEmulator(avdName, grpcPort):
            return "android-\(avdName)-\(grpcPort)"
        }
    }

    var displayName: String {
        switch self {
        case let .iOSSimulator(_, name, _):
            return name
        case let .androidEmulator(avdName, _):
            return avdName
        }
    }

    var platform: DevicePlatform {
        switch self {
        case .iOSSimulator:
            return .iOSSimulator
        case .androidEmulator:
            return .androidEmulator
        }
    }

    var osVersion: String? {
        switch self {
        case let .iOSSimulator(_, _, runtime):
            return runtime
        case .androidEmulator:
            return nil
        }
    }

    var subtitle: String {
        switch self {
        case let .iOSSimulator(udid, _, runtime):
            return "\(runtime) · \(String(udid.prefix(8)))…"
        case let .androidEmulator(_, grpcPort):
            return "gRPC :\(grpcPort)"
        }
    }

    var transportDescription: String {
        switch self {
        case let .iOSSimulator(udid, _, _):
            return udid
        case let .androidEmulator(_, grpcPort):
            return "gRPC :\(grpcPort)"
        }
    }

    var androidGRPCPort: Int? {
        guard case let .androidEmulator(_, grpcPort) = self else {
            return nil
        }
        return grpcPort
    }

    var iosUDID: String? {
        guard case let .iOSSimulator(udid, _, _) = self else { return nil }
        return udid
    }

    var defaultAspectRatio: CGFloat {
        switch self {
        case let .iOSSimulator(_, name, _):
            if name.localizedCaseInsensitiveContains("iPad") {
                return 3.0 / 4.0
            }
            return 9.0 / 19.5
        case .androidEmulator:
            return 9.0 / 19.5
        }
    }
}

extension DeviceDescriptor: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, udid, name, runtime, avdName, grpcPort
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .iOSSimulator(udid, name, runtime):
            try container.encode("ios", forKey: .type)
            try container.encode(udid, forKey: .udid)
            try container.encode(name, forKey: .name)
            try container.encode(runtime, forKey: .runtime)
        case let .androidEmulator(avdName, grpcPort):
            try container.encode("android", forKey: .type)
            try container.encode(avdName, forKey: .avdName)
            try container.encode(grpcPort, forKey: .grpcPort)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ios":
            self = .iOSSimulator(
                udid: try container.decode(String.self, forKey: .udid),
                name: try container.decode(String.self, forKey: .name),
                runtime: try container.decode(String.self, forKey: .runtime)
            )
        case "android":
            self = .androidEmulator(
                avdName: try container.decode(String.self, forKey: .avdName),
                grpcPort: try container.decode(Int.self, forKey: .grpcPort)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown device type: \(type)"
            )
        }
    }
}
