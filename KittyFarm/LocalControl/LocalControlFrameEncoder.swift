import Foundation

enum LocalControlFrameEncoder {
    static func pngData(from frame: DeviceFrame) -> Data? {
        DeviceFrameImageConverter.pngData(from: frame)
    }
}
