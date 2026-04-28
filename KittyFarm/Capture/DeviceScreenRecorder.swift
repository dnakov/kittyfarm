import AVFoundation
import CoreVideo
import Foundation

struct ScreenRecordingResult: Sendable {
    let recordingId: String
    let deviceId: String
    let deviceName: String
    let outputURL: URL
    let startedAt: Date
    let finishedAt: Date
    let durationSeconds: Double
    let frameCount: Int
    let width: Int
    let height: Int
    let fps: Int
}

enum DeviceScreenRecorderError: LocalizedError {
    case missingFrame(String)
    case writerUnavailable
    case pixelBufferUnavailable
    case appendFailed

    var errorDescription: String? {
        switch self {
        case let .missingFrame(deviceName):
            return "No frame is available to record for \(deviceName)."
        case .writerUnavailable:
            return "Could not create the screen recording writer."
        case .pixelBufferUnavailable:
            return "Could not create a video frame buffer."
        case .appendFailed:
            return "Could not append a frame to the screen recording."
        }
    }
}

@MainActor
final class DeviceScreenRecorder {
    let recordingId: String
    let deviceId: String
    let deviceName: String
    let outputURL: URL
    let startedAt: Date
    let fps: Int
    let width: Int
    let height: Int
    var currentFrameCount: Int { frameCount }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var frameCount = 0
    private var finished = false

    init(deviceId: String, deviceName: String, outputURL: URL, frame: DeviceFrame, fps: Int) throws {
        guard let dimensions = frame.dimensions else {
            throw DeviceScreenRecorderError.missingFrame(deviceName)
        }

        let evenWidth = max(2, dimensions.width - dimensions.width % 2)
        let evenHeight = max(2, dimensions.height - dimensions.height % 2)

        self.recordingId = UUID().uuidString
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.outputURL = outputURL
        self.startedAt = Date()
        self.fps = max(1, min(fps, 30))
        self.width = evenWidth
        self.height = evenHeight

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let bitRate = max(evenWidth * evenHeight * 3, 2_000_000)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: evenWidth,
            AVVideoHeightKey: evenHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: evenWidth,
                kCVPixelBufferHeightKey as String: evenHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )

        guard writer.canAdd(input) else {
            throw DeviceScreenRecorderError.writerUnavailable
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? DeviceScreenRecorderError.writerUnavailable
        }
        writer.startSession(atSourceTime: .zero)

        try append(frame)
    }

    func append(_ frame: DeviceFrame) throws {
        guard !finished else { return }
        guard input.isReadyForMoreMediaData else { return }
        guard let pool = adaptor.pixelBufferPool else {
            throw DeviceScreenRecorderError.pixelBufferUnavailable
        }

        var maybePixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybePixelBuffer)
        guard createStatus == kCVReturnSuccess, let pixelBuffer = maybePixelBuffer else {
            throw DeviceScreenRecorderError.pixelBufferUnavailable
        }

        guard DeviceFrameImageConverter.draw(frame, into: pixelBuffer, width: width, height: height) else {
            throw DeviceScreenRecorderError.appendFailed
        }

        let time = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(fps))
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw writer.error ?? DeviceScreenRecorderError.appendFailed
        }
        frameCount += 1
    }

    func finish() async throws -> ScreenRecordingResult {
        guard !finished else {
            return result(finishedAt: Date())
        }

        finished = true
        input.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw writer.error ?? DeviceScreenRecorderError.writerUnavailable
        }

        return result(finishedAt: Date())
    }

    private func result(finishedAt: Date) -> ScreenRecordingResult {
        ScreenRecordingResult(
            recordingId: recordingId,
            deviceId: deviceId,
            deviceName: deviceName,
            outputURL: outputURL,
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationSeconds: max(finishedAt.timeIntervalSince(startedAt), 0),
            frameCount: frameCount,
            width: width,
            height: height,
            fps: fps
        )
    }
}
