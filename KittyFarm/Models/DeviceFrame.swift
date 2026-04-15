import CoreVideo
import Foundation

enum DeviceFramePixelFormat {
    case bgra8888
    case rgba8888
}

final class DeviceFrameBuffer: @unchecked Sendable {
    private enum Storage {
        case data(Data)
        case mapped(UnsafeRawPointer, owner: AnyObject)
    }

    private let storage: Storage

    init(data: Data) {
        storage = .data(data)
    }

    init(mappedBytes: UnsafeRawPointer, owner: AnyObject) {
        storage = .mapped(mappedBytes, owner: owner)
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawPointer) -> R) -> R? {
        switch storage {
        case let .data(data):
            return data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return nil
                }

                return body(baseAddress)
            }
        case let .mapped(baseAddress, owner):
            return withExtendedLifetime(owner) {
                body(baseAddress)
            }
        }
    }
}

struct BitmapFrame {
    let buffer: DeviceFrameBuffer
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelFormat: DeviceFramePixelFormat
}

enum DeviceFrame {
    case pixelBuffer(CVPixelBuffer)
    case bitmap(BitmapFrame)

    var dimensions: (width: Int, height: Int)? {
        switch self {
        case let .pixelBuffer(pb):
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            return w > 0 && h > 0 ? (w, h) : nil
        case let .bitmap(frame):
            let width = frame.width
            let height = frame.height
            return width > 0 && height > 0 ? (width, height) : nil
        }
    }
}
