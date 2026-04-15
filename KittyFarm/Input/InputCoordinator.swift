import Foundation

struct InputCoordinator {
    func replicate(_ touch: NormalizedTouch, to targets: [AnyDeviceConnectionBox]) async {
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        try await target.sendTouch(touch)
                    } catch {
                        print("InputCoordinator error [\(target.descriptor.displayName)]: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func replicate(_ keyEvent: DeviceKeyboardEvent, to targets: [AnyDeviceConnectionBox]) async {
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        try await target.sendKey(keyEvent)
                    } catch {
                        print("InputCoordinator key error [\(target.descriptor.displayName)]: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func replicatePasteboard(_ text: String, to targets: [AnyDeviceConnectionBox]) async {
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        try await target.setPasteboardText(text)
                    } catch {
                        print("InputCoordinator pasteboard error [\(target.descriptor.displayName)]: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
