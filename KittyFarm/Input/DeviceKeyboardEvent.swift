import AppKit
import Foundation

struct DeviceKeyboardEvent: Sendable {
    struct Modifiers: OptionSet, Sendable {
        let rawValue: UInt8

        static let shift = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
        static let capsLock = Modifiers(rawValue: 1 << 4)
        static let function = Modifiers(rawValue: 1 << 5)

        static func from(_ flags: NSEvent.ModifierFlags) -> Modifiers {
            var modifiers: Modifiers = []
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
            if flags.contains(.function) { modifiers.insert(.function) }
            return modifiers
        }

        var orderedKeyCodes: [UInt16] {
            var keyCodes: [UInt16] = []
            if contains(.capsLock) { keyCodes.append(57) }
            if contains(.control) { keyCodes.append(59) }
            if contains(.option) { keyCodes.append(58) }
            if contains(.shift) { keyCodes.append(56) }
            if contains(.command) { keyCodes.append(55) }
            if contains(.function) { keyCodes.append(63) }
            return keyCodes
        }
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            modifiers: .from(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        )
    }
}
