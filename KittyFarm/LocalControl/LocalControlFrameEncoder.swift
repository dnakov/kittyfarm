import AppKit
import CoreImage
import CoreVideo
import Foundation

enum LocalControlFrameEncoder {
    static func pngData(from frame: DeviceFrame) -> Data? {
        switch frame {
        case .pixelBuffer(let pixelBuffer):
            return pngData(from: CIImage(cvPixelBuffer: pixelBuffer))

        case .bitmap(let bitmap):
            return bitmap.buffer.withUnsafeBytes { baseAddress in
                pngData(
                    baseAddress: baseAddress,
                    width: bitmap.width,
                    height: bitmap.height,
                    bytesPerRow: bitmap.bytesPerRow,
                    pixelFormat: bitmap.pixelFormat
                )
            } ?? nil
        }
    }

    private static func pngData(from image: CIImage) -> Data? {
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return nil
        }
        return pngData(from: cgImage)
    }

    private static func pngData(
        baseAddress: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: DeviceFramePixelFormat
    ) -> Data? {
        let bitmapInfo: CGBitmapInfo
        switch pixelFormat {
        case .bgra8888:
            bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            )
        case .rgba8888:
            bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            )
        }

        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: baseAddress,
            size: bytesPerRow * height,
            releaseData: { _, _, _ in }
        ) else {
            return nil
        }

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        return pngData(from: image)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
    }
}
