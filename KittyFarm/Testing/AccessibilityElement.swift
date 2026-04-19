import Foundation

struct AccessibilityElement: Codable, Sendable {
    let type: String
    let identifier: String
    let label: String
    let value: String?
    let frame: Frame
    let isEnabled: Bool
    let children: [AccessibilityElement]

    struct Frame: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        var midX: Double { x + width / 2 }
        var midY: Double { y + height / 2 }
    }

    var isInteractive: Bool {
        let interactiveTypes: Set<String> = [
            "button", "textField", "secureTextField", "switch", "toggle",
            "slider", "stepper", "link", "searchField", "segmentedControl",
            "picker", "menuButton", "popUpButton", "comboBox", "checkBox",
            "radioButton", "tab", "cell"
        ]
        return interactiveTypes.contains(type)
    }
}
