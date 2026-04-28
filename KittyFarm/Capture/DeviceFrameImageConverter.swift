import AppKit
import CoreImage
import CoreVideo
import Foundation

enum DeviceFrameImageConverter {
    private static let ciContext = CIContext(options: nil)

    static func cgImage(from frame: DeviceFrame) -> CGImage? {
        switch frame {
        case let .pixelBuffer(pixelBuffer):
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            return ciContext.createCGImage(image, from: image.extent)

        case let .bitmap(bitmap):
            return bitmap.buffer.withUnsafeBytes { baseAddress in
                cgImage(
                    baseAddress: baseAddress,
                    width: bitmap.width,
                    height: bitmap.height,
                    bytesPerRow: bitmap.bytesPerRow,
                    pixelFormat: bitmap.pixelFormat
                )
            } ?? nil
        }
    }

    static func pngData(from frame: DeviceFrame) -> Data? {
        guard let image = cgImage(from: frame) else { return nil }
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
    }

    static func draw(_ frame: DeviceFrame, into pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> Bool {
        guard let image = cgImage(from: frame) else { return false }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return false
        }

        context.interpolationQuality = .none
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }

    private static func cgImage(
        baseAddress: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: DeviceFramePixelFormat
    ) -> CGImage? {
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

        return CGImage(
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
        )
    }
}
