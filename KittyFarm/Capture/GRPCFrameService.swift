import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import ImageIO
import QuartzCore

enum AndroidGRPCError: LocalizedError {
    case invalidDescriptor
    case missingFrameDimensions
    case invalidFramePayload
    case unsupportedImageFormat
    case streamEndedBeforeFirstFrame
    case sharedMemorySetupFailed

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor:
            return "Android emulator gRPC requires a valid emulator descriptor and port."
        case .missingFrameDimensions:
            return "Android emulator gRPC stream returned a frame without dimensions."
        case .invalidFramePayload:
            return "Android emulator gRPC stream returned malformed image data."
        case .unsupportedImageFormat:
            return "Android emulator gRPC stream returned an unsupported image format."
        case .streamEndedBeforeFirstFrame:
            return "Android emulator gRPC stream ended before the first frame arrived."
        case .sharedMemorySetupFailed:
            return "Android emulator shared-memory transport could not be prepared."
        }
    }
}

private final class StreamStartupSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    var isResolved: Bool {
        lock.lock()
        let resolved = continuation == nil
        lock.unlock()
        return resolved
    }
}

private final class AndroidSharedImageTransport: @unchecked Sendable {
    private let fileURL: URL
    private let capacity: Int
    private var fileDescriptor: Int32 = -1
    private var mappedBytes: UnsafeMutableRawPointer?

    init(capacity: Int) throws {
        self.capacity = capacity
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kittyfarm-android-\(UUID().uuidString).rgba")

        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }

            return open(path, O_RDWR | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        }

        guard descriptor >= 0 else {
            throw AndroidGRPCError.sharedMemorySetupFailed
        }

        fileDescriptor = descriptor

        guard ftruncate(fileDescriptor, off_t(capacity)) == 0 else {
            cleanup()
            throw AndroidGRPCError.sharedMemorySetupFailed
        }

        let mapped = mmap(nil, capacity, PROT_READ | PROT_WRITE, MAP_SHARED, fileDescriptor, 0)
        guard mapped != MAP_FAILED else {
            cleanup()
            throw AndroidGRPCError.sharedMemorySetupFailed
        }

        mappedBytes = mapped
    }

    deinit {
        cleanup()
    }

    func requestTransport() -> Android_Emulation_Control_ImageTransport {
        var transport = Android_Emulation_Control_ImageTransport()
        transport.channel = .mmap
        transport.handle = fileURL.absoluteString
        return transport
    }

    func makeBuffer(length: Int) throws -> DeviceFrameBuffer {
        guard length > 0, length <= capacity, let mappedBytes else {
            throw AndroidGRPCError.invalidFramePayload
        }

        return DeviceFrameBuffer(mappedBytes: UnsafeRawPointer(mappedBytes), owner: self)
    }

    private func cleanup() {
        if let mappedBytes {
            munmap(mappedBytes, capacity)
            self.mappedBytes = nil
        }

        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        try? FileManager.default.removeItem(at: fileURL)
    }
}

final class GRPCFrameService {
    let descriptor: DeviceDescriptor
    private static let emulatorGRPCAddress = "127.0.0.1"
    private static let startupRetryWindow: TimeInterval = 20
    private static let startupRetryDelayNanoseconds: UInt64 = 500_000_000
    private static let screenshotMaxResponseBytes = 64 * 1024 * 1024
    private static let enablesSharedTransportByDefault =
        ProcessInfo.processInfo.environment["KITTYFARM_ANDROID_MMAP"] == "1"

    private var streamTask: Task<Void, Never>?
    private var sharedTransport: AndroidSharedImageTransport?

    init(descriptor: DeviceDescriptor) {
        self.descriptor = descriptor
    }

    deinit {
        streamTask?.cancel()
    }

    func startStreaming(into state: DeviceState) async throws {
        let grpcPort = try requireGRPCPort()

        await stop()
        let deadline = Date().addingTimeInterval(Self.startupRetryWindow)

        while true {
            let sharedTransport = Self.enablesSharedTransportByDefault
                ? (try? AndroidSharedImageTransport(capacity: Self.screenshotMaxResponseBytes))
                : nil
            self.sharedTransport = sharedTransport

            do {
                try await withCheckedThrowingContinuation { continuation in
                    streamTask = Self.makeStreamTask(
                        grpcPort: grpcPort,
                        state: state,
                        startupSignal: StreamStartupSignal(continuation),
                        sharedTransport: sharedTransport,
                        suppressInitialErrors: true
                    )
                }
                return
            } catch is CancellationError {
                throw AndroidGRPCError.streamEndedBeforeFirstFrame
            } catch {
                self.sharedTransport = nil

                guard Self.shouldRetryStartup(after: error), Date() < deadline else {
                    throw error
                }

                try await Task.sleep(nanoseconds: Self.startupRetryDelayNanoseconds)
            }
        }
    }

    func stop() async {
        let task = streamTask
        streamTask = nil
        task?.cancel()
        await task?.value
        sharedTransport = nil
    }

    private func requireGRPCPort() throws -> Int {
        guard let grpcPort = descriptor.androidGRPCPort else {
            throw AndroidGRPCError.invalidDescriptor
        }

        return grpcPort
    }

    private static func makeStreamTask(
        grpcPort: Int,
        state: DeviceState,
        startupSignal: StreamStartupSignal,
        sharedTransport: AndroidSharedImageTransport?,
        suppressInitialErrors: Bool
    ) -> Task<Void, Never> {
        Task { [grpcPort, state, sharedTransport] in
            do {
                if let sharedTransport {
                    do {
                        try await Self.streamFrames(
                            grpcPort: grpcPort,
                            state: state,
                            startupSignal: startupSignal,
                            sharedTransport: sharedTransport
                        )
                        startupSignal.resume(throwing: AndroidGRPCError.streamEndedBeforeFirstFrame)
                        return
                    } catch is CancellationError {
                        startupSignal.resume(throwing: AndroidGRPCError.streamEndedBeforeFirstFrame)
                        return
                    } catch {
                        print("Android emulator MMAP stream failed, falling back to inline frames: \(error.localizedDescription)")
                    }
                }

                try await Self.streamFrames(
                    grpcPort: grpcPort,
                    state: state,
                    startupSignal: startupSignal,
                    sharedTransport: nil
                )
                startupSignal.resume(throwing: AndroidGRPCError.streamEndedBeforeFirstFrame)
            } catch is CancellationError {
                startupSignal.resume(throwing: AndroidGRPCError.streamEndedBeforeFirstFrame)
                return
            } catch {
                let shouldReport = startupSignal.isResolved || !suppressInitialErrors
                startupSignal.resume(throwing: error)
                if shouldReport {
                    await Self.noteError(error, on: state)
                }
            }
        }
    }

    @MainActor
    private static func noteFrame(_ frame: DeviceFrame, at receivedAt: CFTimeInterval, on state: DeviceState) {
        state.noteFrame(frame, at: receivedAt)
    }

    @MainActor
    private static func noteError(_ error: Error, on state: DeviceState) {
        state.noteError(error)
    }

    private static func streamFrames(
        grpcPort: Int,
        state: DeviceState,
        startupSignal: StreamStartupSignal,
        sharedTransport: AndroidSharedImageTransport?
    ) async throws {
        try await withGRPCClient(
            transport: .http2NIOPosix(
                target: .ipv4(address: Self.emulatorGRPCAddress, port: grpcPort),
                transportSecurity: .plaintext
            )
        ) { client in
            let emulator = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
            let format = makeRequestFormat(sharedTransport: sharedTransport)
            var options = CallOptions.defaults
            options.maxRequestMessageBytes = Self.screenshotMaxResponseBytes
            options.maxResponseMessageBytes = Self.screenshotMaxResponseBytes

            try await emulator.streamScreenshot(
                format,
                metadata: AndroidEmulatorAuth.metadata(forGRPCPort: grpcPort),
                options: options
            ) { response in
                for try await image in response.messages {
                    let frame = try Self.makeFrame(from: image, sharedTransport: sharedTransport)
                    startupSignal.resume()
                    let receivedAt = CACurrentMediaTime()
                    await Self.noteFrame(frame, at: receivedAt, on: state)
                }
            }
        }
    }

    private static func makeRequestFormat(
        sharedTransport: AndroidSharedImageTransport?
    ) -> Android_Emulation_Control_ImageFormat {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        if let sharedTransport {
            format.transport = sharedTransport.requestTransport()
        }
        return format
    }

    private static func makeFrame(
        from image: Android_Emulation_Control_Image,
        sharedTransport: AndroidSharedImageTransport?
    ) throws -> DeviceFrame {
        let width = Int(image.hasFormat ? image.format.width : image.width)
        let height = Int(image.hasFormat ? image.format.height : image.height)

        guard width > 0, height > 0 else {
            throw AndroidGRPCError.missingFrameDimensions
        }

        let format = image.hasFormat ? image.format.format : .png
        switch format {
        case .rgba8888:
            return .bitmap(
                BitmapFrame(
                    buffer: try makeRGBA8888Buffer(
                        from: image.image,
                        width: width,
                        height: height,
                        sharedTransport: sharedTransport
                    ),
                    width: width,
                    height: height,
                    bytesPerRow: width * 4,
                    pixelFormat: .rgba8888
                )
            )
        case .rgb888:
            return .bitmap(
                BitmapFrame(
                    buffer: DeviceFrameBuffer(
                        data: try expandRGB888ToRGBA(image.image, width: width, height: height)
                    ),
                    width: width,
                    height: height,
                    bytesPerRow: width * 4,
                    pixelFormat: .rgba8888
                )
            )
        case .png:
            return try decodePNG(image.image)
        case .UNRECOGNIZED:
            throw AndroidGRPCError.unsupportedImageFormat
        }
    }

    private static func makeRGBA8888Buffer(
        from data: Data,
        width: Int,
        height: Int,
        sharedTransport: AndroidSharedImageTransport?
    ) throws -> DeviceFrameBuffer {
        let sourceBytesPerRow = width * 4
        let byteCount = sourceBytesPerRow * height

        if data.isEmpty, let sharedTransport {
            return try sharedTransport.makeBuffer(length: byteCount)
        }

        guard data.count >= byteCount else {
            throw AndroidGRPCError.invalidFramePayload
        }

        return DeviceFrameBuffer(data: data)
    }

    private static func expandRGB888ToRGBA(_ data: Data, width: Int, height: Int) throws -> Data {
        let sourceBytesPerRow = width * 3
        guard data.count >= sourceBytesPerRow * height else {
            throw AndroidGRPCError.invalidFramePayload
        }

        var converted = Data(count: width * height * 4)
        converted.withUnsafeMutableBytes { destinationBytes in
            data.withUnsafeBytes { sourceBytes in
                guard
                    let destinationBase = destinationBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let sourceBase = sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = row * sourceBytesPerRow
                    let destinationOffset = row * width * 4
                    for x in 0..<width {
                        let sourceIndex = sourceOffset + (x * 3)
                        let destinationIndex = destinationOffset + (x * 4)
                        destinationBase[destinationIndex + 0] = sourceBase[sourceIndex + 0]
                        destinationBase[destinationIndex + 1] = sourceBase[sourceIndex + 1]
                        destinationBase[destinationIndex + 2] = sourceBase[sourceIndex + 2]
                        destinationBase[destinationIndex + 3] = 255
                    }
                }
            }
        }

        return converted
    }

    private static func decodePNG(_ data: Data) throws -> DeviceFrame {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw AndroidGRPCError.invalidFramePayload
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else {
                return false
            }

            guard let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else {
            throw AndroidGRPCError.invalidFramePayload
        }

        return .bitmap(
            BitmapFrame(
                buffer: DeviceFrameBuffer(data: pixels),
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                pixelFormat: .bgra8888
            )
        )
    }

    private static func shouldRetryStartup(after error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let rpcError = error as? RPCError {
            switch rpcError.code {
            case .unavailable, .cancelled, .internalError, .unknown:
                return true
            default:
                return false
            }
        }

        return false
    }
}
