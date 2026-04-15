import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class ScreenCaptureService: NSObject {
    private let descriptor: DeviceDescriptor
    private weak var state: DeviceState?
    private let matcher: SimulatorWindowMatcher
    private let sampleQueue = DispatchQueue(label: "KittyFarm.ScreenCaptureService")

    private var stream: SCStream?
    private var output: StreamOutput?

    init(descriptor: DeviceDescriptor, state: DeviceState, matcher: SimulatorWindowMatcher) {
        self.descriptor = descriptor
        self.state = state
        self.matcher = matcher
        super.init()
    }

    func start() async throws {
        let match = try await matcher.matchWindow(for: descriptor)

        let filter = SCContentFilter(desktopIndependentWindow: match.window)
        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.width = Int(match.bounds.width)
        configuration.height = Int(match.bounds.height)
        configuration.showsCursor = false

        let output = StreamOutput { [weak self] sampleBuffer in
            self?.handle(sampleBuffer)
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.output = output
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        output = nil
        stream = nil
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard
            CMSampleBufferIsValid(sampleBuffer),
            CMSampleBufferDataIsReady(sampleBuffer),
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        let timestamp = CACurrentMediaTime()
        let frameBox = PixelBufferBox(pixelBuffer: pixelBuffer)
        Task { @MainActor [weak state] in
            state?.noteFrame(.pixelBuffer(frameBox.pixelBuffer), at: timestamp)
        }
    }
}

private final class StreamOutput: NSObject, SCStreamOutput {
    private let onSampleBuffer: (CMSampleBuffer) -> Void

    init(onSampleBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.onSampleBuffer = onSampleBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else {
            return
        }

        onSampleBuffer(sampleBuffer)
    }
}

private struct PixelBufferBox: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}
