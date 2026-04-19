import Foundation

actor LazyAndroidAccessibilityProvider: AccessibilityTreeProvider {
    private let avdName: String
    private let screenWidth: Double
    private let screenHeight: Double
    private var resolvedSerial: String?

    init(avdName: String, screenWidth: Double, screenHeight: Double) {
        self.avdName = avdName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    nonisolated func fetchTree(bundleIdentifier: String?) async throws -> [AccessibilityElement] {
        let serial = try await ensureSerial()
        // `uiautomator dump /dev/tty` doesn't work reliably over adb shell —
        // the tty redirect goes nowhere. Write to a file and cat it back.
        let result = try await ProcessRunner.run(.init(
            executableURL: ADBUtils.binaryURL,
            arguments: ["-s", serial, "shell", "uiautomator dump /sdcard/kittyfarm_ui.xml && cat /sdcard/kittyfarm_ui.xml"]
        ))
        try result.requireSuccess("adb uiautomator dump")

        return try UIAutomatorXMLParser.parse(result.stdout)
    }

    nonisolated func screenSize() async throws -> (width: Double, height: Double) {
        let w = await screenWidth
        let h = await screenHeight
        return (w, h)
    }

    private func ensureSerial() async throws -> String {
        if let serial = resolvedSerial {
            return serial
        }
        let serial = try await ADBUtils.resolveSerial(avdName: avdName)
        resolvedSerial = serial
        return serial
    }
}

private final class UIAutomatorXMLParser: NSObject, XMLParserDelegate {
    private var rootElements: [AccessibilityElement] = []
    private var elementStack: [(attributes: [String: String], children: [AccessibilityElement])] = []

    static func parse(_ xmlString: String) throws -> [AccessibilityElement] {
        let cleanedXML = Self.extractXML(from: xmlString)
        guard let data = cleanedXML.data(using: .utf8) else {
            return []
        }

        let parser = XMLParser(data: data)
        let delegate = UIAutomatorXMLParser()
        parser.delegate = delegate
        parser.parse()

        return delegate.rootElements
    }

    private static func extractXML(from output: String) -> String {
        if let xmlStart = output.range(of: "<?xml") {
            return String(output[xmlStart.lowerBound...])
        }
        if let hierarchyStart = output.range(of: "<hierarchy") {
            return String(output[hierarchyStart.lowerBound...])
        }
        return output
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        elementStack.append((attributes: attributes, children: []))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard let current = elementStack.popLast() else { return }

        if elementName == "hierarchy" {
            // <hierarchy> is the root wrapper; its direct <node> children are our roots.
            rootElements.append(contentsOf: current.children)
            return
        }

        guard elementName == "node" else { return }

        let element = Self.makeElement(from: current.attributes, children: current.children)

        if elementStack.isEmpty {
            rootElements.append(element)
        } else {
            elementStack[elementStack.count - 1].children.append(element)
        }
    }

    private static func makeElement(
        from attributes: [String: String],
        children: [AccessibilityElement]
    ) -> AccessibilityElement {
        let bounds = parseBounds(attributes["bounds"] ?? "")
        let className = attributes["class"] ?? ""
        let shortClass = className.split(separator: ".").last.map(String.init) ?? className

        return AccessibilityElement(
            type: mapAndroidClassToType(shortClass),
            identifier: attributes["resource-id"] ?? "",
            label: attributes["text"] ?? attributes["content-desc"] ?? "",
            value: attributes["text"],
            frame: bounds,
            isEnabled: attributes["enabled"] == "true",
            children: children
        )
    }

    private static func parseBounds(_ boundsString: String) -> AccessibilityElement.Frame {
        let numbers = boundsString
            .replacingOccurrences(of: "][", with: ",")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: ",")
            .compactMap { Double($0) }

        guard numbers.count == 4 else {
            return .init(x: 0, y: 0, width: 0, height: 0)
        }

        return .init(
            x: numbers[0],
            y: numbers[1],
            width: numbers[2] - numbers[0],
            height: numbers[3] - numbers[1]
        )
    }

    private static func mapAndroidClassToType(_ className: String) -> String {
        switch className {
        case "Button", "ImageButton", "FloatingActionButton": return "button"
        case "TextView": return "staticText"
        case "EditText": return "textField"
        case "ImageView": return "image"
        case "CheckBox": return "checkBox"
        case "RadioButton": return "radioButton"
        case "Switch", "ToggleButton": return "switch"
        case "SeekBar": return "slider"
        case "Spinner": return "picker"
        case "RecyclerView", "ListView": return "table"
        case "ScrollView", "HorizontalScrollView", "NestedScrollView": return "scrollView"
        case "SearchView": return "searchField"
        case "TabLayout": return "tabBar"
        case "WebView": return "webView"
        case "ProgressBar": return "progressIndicator"
        default: return "other"
        }
    }
}
