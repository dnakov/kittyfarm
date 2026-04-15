import CoreVideo
import MetalKit
import SwiftUI

struct MetalFrameView: NSViewRepresentable {
    let state: DeviceState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.state = state
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var state: DeviceState

        private let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let pipelineState: MTLRenderPipelineState
        private var textureCache: CVMetalTextureCache?
        private var uploadedTexture: MTLTexture?
        private var uploadedTexturePixelFormat: DeviceFramePixelFormat?
        private var loggedPixelBufferFailure = false

        init(state: DeviceState) {
            self.state = state

            guard let device = MTLCreateSystemDefaultDevice() else {
                fatalError("Metal is required for KittyFarm.")
            }

            guard let commandQueue = device.makeCommandQueue() else {
                fatalError("Unable to create a Metal command queue.")
            }

            guard
                let library = try? device.makeDefaultLibrary(bundle: .main),
                let vertexFunction = library.makeFunction(name: "kittyFarmVertex"),
                let fragmentFunction = library.makeFunction(name: "kittyFarmFragment")
            else {
                fatalError("Unable to load KittyFarm Metal shaders.")
            }

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            guard let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
                fatalError("Unable to create the Metal pipeline state.")
            }

            self.device = device
            self.commandQueue = commandQueue
            self.pipelineState = pipelineState

            super.init()
            CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        }

        func makeView() -> MTKView {
            let view = MTKView(frame: .zero, device: device)
            view.delegate = self
            view.framebufferOnly = false
            view.colorPixelFormat = .bgra8Unorm
            view.preferredFramesPerSecond = 30
            view.enableSetNeedsDisplay = false
            view.isPaused = false
            view.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
            return view
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard
                let descriptor = view.currentRenderPassDescriptor,
                let drawable = view.currentDrawable,
                let commandBuffer = commandQueue.makeCommandBuffer(),
                let texture = currentTexture()
            else {
                return
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func currentTexture() -> MTLTexture? {
            switch state.currentFrame {
            case let .pixelBuffer(pixelBuffer):
                return texture(from: pixelBuffer)
            case let .bitmap(frame):
                return texture(from: frame)
            case .none:
                return nil
            }
        }

        private func texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
            guard let textureCache else {
                return nil
            }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )

            guard status == kCVReturnSuccess, let cvTexture else {
                if !loggedPixelBufferFailure {
                    loggedPixelBufferFailure = true
                    print("[KittyFarm][MetalFrame] CVMetalTextureCacheCreateTextureFromImage failed for \(state.descriptor.displayName) status=\(status) size=\(width)x\(height)")
                }
                return nil
            }

            return CVMetalTextureGetTexture(cvTexture)
        }

        private func texture(from frame: BitmapFrame) -> MTLTexture? {
            if uploadedTexture?.width != frame.width
                || uploadedTexture?.height != frame.height
                || uploadedTexturePixelFormat != frame.pixelFormat
            {
                let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: metalPixelFormat(for: frame.pixelFormat),
                    width: frame.width,
                    height: frame.height,
                    mipmapped: false
                )
                textureDescriptor.usage = [.shaderRead]
                uploadedTexture = device.makeTexture(descriptor: textureDescriptor)
                uploadedTexturePixelFormat = frame.pixelFormat
            }

            guard let uploadedTexture else {
                return nil
            }

            guard let _ = frame.buffer.withUnsafeBytes({ baseAddress in
                uploadedTexture.replace(
                    region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: frame.bytesPerRow
                )
            }) else {
                return nil
            }

            return uploadedTexture
        }

        private func metalPixelFormat(for pixelFormat: DeviceFramePixelFormat) -> MTLPixelFormat {
            switch pixelFormat {
            case .bgra8888:
                return .bgra8Unorm
            case .rgba8888:
                return .rgba8Unorm
            }
        }
    }
}
