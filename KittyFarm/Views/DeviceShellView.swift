import AppKit
import SwiftUI

struct DeviceShellView<Content: View>: View {
    let descriptor: DeviceDescriptor
    let content: Content

    init(descriptor: DeviceDescriptor, @ViewBuilder content: () -> Content) {
        self.descriptor = descriptor
        self.content = content()
    }

    var body: some View {
        if let chrome = chromeProfile {
            chromeWrapped(chrome)
        } else {
            content
                .aspectRatio(descriptor.defaultAspectRatio, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
        }
    }

    private var chromeProfile: ChromeProfile? {
        switch descriptor {
        case let .iOSSimulator(_, name, _):
            return ChromeProfile.load(for: name)
        case let .androidEmulator(avdName, _):
            return AndroidSkinProfile.load(for: avdName)
        }
    }

    private func chromeWrapped(_ chrome: ChromeProfile) -> some View {
        Color.clear
            .aspectRatio(chrome.totalAspectRatio, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let scale = geo.size.width / chrome.totalSize.width

                    let compX = chrome.buttonMargins.left * scale
                    let compY = chrome.buttonMargins.top * scale
                    let compW = chrome.compositeSize.width * scale
                    let compH = chrome.compositeSize.height * scale

                    let screenX = compX + chrome.screenInsets.left * scale
                    let screenY = compY + chrome.screenInsets.top * scale
                    let screenW = compW - (chrome.screenInsets.left + chrome.screenInsets.right) * scale
                    let screenH = compH - (chrome.screenInsets.top + chrome.screenInsets.bottom) * scale

                    // Buttons behind the device body — with edge highlights
                    ForEach(chrome.buttons) { button in
                        let imgSize = button.image.size
                        let w = imgSize.width * scale
                        let h = imgSize.height * scale

                        let pos = buttonPosition(
                            button, scale: scale,
                            compX: compX, compY: compY,
                            compW: compW, compH: compH
                        )

                        Image(nsImage: button.image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: w, height: h)
                            .position(x: pos.x, y: pos.y)
                            .allowsHitTesting(false)
                    }

                    // Device body behind screen
                    Image(nsImage: chrome.compositeImage)
                        .resizable()
                        .frame(width: compW, height: compH)
                        .position(x: compX + compW / 2, y: compY + compH / 2)
                        .allowsHitTesting(false)

                    // Screen content on top, clipped to screen shape
                    content
                        .frame(width: screenW, height: screenH)
                        .clipShape(RoundedRectangle(cornerRadius: (chrome.cornerRadius + 1) * scale, style: .continuous))
                        .position(x: screenX + screenW / 2, y: screenY + screenH / 2)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }

    private func buttonPosition(_ button: ChromeButton, scale: CGFloat, compX: CGFloat, compY: CGFloat, compW: CGFloat, compH: CGFloat) -> CGPoint {
        switch button.anchor {
        case .left:
            return CGPoint(
                x: compX + button.offset.x * scale,
                y: compY + button.offset.y * scale
            )
        case .right:
            return CGPoint(
                x: compX + compW + button.offset.x * scale,
                y: compY + button.offset.y * scale
            )
        case .top:
            let baseX = button.align == .trailing ? compX + compW : compX
            return CGPoint(
                x: baseX + button.offset.x * scale,
                y: compY + button.offset.y * scale
            )
        case .bottom:
            let baseX = button.align == .trailing ? compX + compW : compX
            return CGPoint(
                x: baseX + button.offset.x * scale,
                y: compY + compH + button.offset.y * scale
            )
        }
    }
}

// MARK: - Data Model

struct ChromeButton: Identifiable {
    let id: String
    let image: NSImage
    let anchor: Anchor
    let align: Align
    let offset: CGPoint

    enum Anchor: String {
        case left, right, top, bottom
    }

    enum Align: String {
        case leading, trailing
    }
}

struct ChromeProfile {
    let compositeImage: NSImage
    let compositeSize: CGSize
    let screenInsets: NSEdgeInsets
    let cornerRadius: CGFloat
    let buttons: [ChromeButton]
    let buttonMargins: NSEdgeInsets

    var totalSize: CGSize {
        CGSize(
            width: compositeSize.width + buttonMargins.left + buttonMargins.right,
            height: compositeSize.height + buttonMargins.top + buttonMargins.bottom
        )
    }

    var totalAspectRatio: CGFloat {
        totalSize.width / totalSize.height
    }

    @MainActor private static var cache: [String: ChromeProfile] = [:]

    @MainActor static func load(for deviceName: String) -> ChromeProfile? {
        if let cached = cache[deviceName] {
            return cached
        }

        let profilePath = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/\(deviceName).simdevicetype/Contents/Resources/profile.plist"
        guard let profileData = try? Data(contentsOf: URL(fileURLWithPath: profilePath)),
              let plist = try? PropertyListSerialization.propertyList(from: profileData, format: nil) as? [String: Any],
              let chromeId = plist["chromeIdentifier"] as? String
        else {
            return nil
        }

        let chromeName = chromeId.replacingOccurrences(of: "com.apple.dt.devicekit.chrome.", with: "")
        let chromePath = "/Library/Developer/DeviceKit/Chrome/\(chromeName).devicechrome/Contents/Resources"

        let jsonPath = "\(chromePath)/chrome.json"
        guard let jsonData = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let images = json["images"] as? [String: Any]
        else {
            return nil
        }

        // Screen insets
        let sizing = images["sizing"] as? [String: Any]

        let screenInsets = NSEdgeInsets(
            top: num(sizing, "topHeight"),
            left: num(sizing, "leftWidth"),
            bottom: num(sizing, "bottomHeight"),
            right: num(sizing, "rightWidth")
        )

        // Composite image: use pre-built composite if available, otherwise assemble from 9-slice
        let compositeImage: NSImage
        let compositeSize: CGSize

        if let compositeName = images["composite"] as? String,
           let img = NSImage(contentsOfFile: "\(chromePath)/\(compositeName).pdf") {
            compositeImage = img
            compositeSize = img.size
        } else {
            // Build composite from 9-slice pieces
            let screenScale = (plist["mainScreenScale"] as? CGFloat) ?? 2
            let pointW = ((plist["mainScreenWidth"] as? CGFloat) ?? 1668) / screenScale
            let pointH = ((plist["mainScreenHeight"] as? CGFloat) ?? 2420) / screenScale
            let totalW = pointW + screenInsets.left + screenInsets.right
            let totalH = pointH + screenInsets.top + screenInsets.bottom

            guard let assembled = assemble9Slice(images: images, chromePath: chromePath, width: totalW, height: totalH) else {
                return nil
            }
            compositeImage = assembled
            compositeSize = assembled.size
        }

        // Corner radius
        let paths = json["paths"] as? [String: Any]
        let border = paths?["simpleOutsideBorder"] as? [String: Any]
        let rawCornerRadius = (border?["cornerRadiusX"] as? CGFloat) ?? 80

        let screenScale = (plist["mainScreenScale"] as? CGFloat) ?? 3
        let pointScreenWidth = ((plist["mainScreenWidth"] as? CGFloat) ?? 1320) / screenScale
        let bezelWidth = max(screenInsets.left, screenInsets.top)
        let innerRadius = max(rawCornerRadius - bezelWidth, 0)
        let screenW = compositeSize.width - screenInsets.left - screenInsets.right
        let radiusScale = screenW / pointScreenWidth
        let cornerRadius = innerRadius * radiusScale

        // Buttons
        var buttons: [ChromeButton] = []
        var marginLeft: CGFloat = 0
        var marginRight: CGFloat = 0
        var marginTop: CGFloat = 0
        var marginBottom: CGFloat = 0

        if let inputs = json["inputs"] as? [[String: Any]] {
            for input in inputs {
                let name = input["name"] as? String ?? UUID().uuidString
                let imageName = input["image"] as? String ?? ""
                let anchorStr = input["anchor"] as? String ?? "left"
                let offsets = input["offsets"] as? [String: Any]
                let rolloverOffset = offsets?["rollover"] as? [String: Any]
                    ?? offsets?["normal"] as? [String: Any]

                guard let image = NSImage(contentsOfFile: "\(chromePath)/\(imageName).pdf") else {
                    continue
                }

                let anchor = ChromeButton.Anchor(rawValue: anchorStr) ?? .left
                let alignStr = input["align"] as? String ?? "leading"
                let align = ChromeButton.Align(rawValue: alignStr) ?? .leading
                let offsetX = (rolloverOffset?["x"] as? CGFloat) ?? 0
                let offsetY = (rolloverOffset?["y"] as? CGFloat) ?? 0

                buttons.append(ChromeButton(
                    id: name,
                    image: image,
                    anchor: anchor,
                    align: align,
                    offset: CGPoint(x: offsetX, y: offsetY)
                ))

                // Calculate how much space buttons need outside the composite
                let imgW = image.size.width
                let imgH = image.size.height

                switch anchor {
                case .left:
                    let overshoot = max(imgW - offsetX, 0)
                    marginLeft = max(marginLeft, overshoot)
                case .right:
                    let overshoot = max(imgW + offsetX, 0)
                    marginRight = max(marginRight, overshoot)
                case .top:
                    let overshoot = max(-(offsetY - imgH / 2), 0)
                    marginTop = max(marginTop, overshoot)
                case .bottom:
                    let overshoot = max(offsetY + imgH / 2, 0)
                    marginBottom = max(marginBottom, overshoot)
                }
            }
        }

        let profile = ChromeProfile(
            compositeImage: compositeImage,
            compositeSize: compositeSize,
            screenInsets: screenInsets,
            cornerRadius: cornerRadius,
            buttons: buttons,
            buttonMargins: NSEdgeInsets(
                top: marginTop,
                left: marginLeft,
                bottom: marginBottom,
                right: marginRight
            )
        )

        cache[deviceName] = profile
        return profile
    }

    private static func num(_ dict: [String: Any]?, _ key: String) -> CGFloat {
        (dict?[key] as? CGFloat) ?? 0
    }

    private static func assemble9Slice(images: [String: Any], chromePath: String, width: CGFloat, height: CGFloat) -> NSImage? {
        func load(_ key: String) -> NSImage? {
            guard let name = images[key] as? String else { return nil }
            return NSImage(contentsOfFile: "\(chromePath)/\(name).pdf")
        }

        guard let tl = load("topLeft"),
              let top = load("top"),
              let tr = load("topRight"),
              let left = load("left"),
              let right = load("right"),
              let bl = load("bottomLeft"),
              let bottom = load("bottom"),
              let br = load("bottomRight")
        else {
            return nil
        }

        let cornerW = tl.size.width
        let cornerH = tl.size.height
        let midW = max(width - cornerW * 2, 0)
        let midH = max(height - cornerH * 2, 0)

        let composite = NSImage(size: NSSize(width: width, height: height))
        composite.lockFocus()

        // Corners
        tl.draw(in: NSRect(x: 0, y: height - cornerH, width: cornerW, height: cornerH))
        tr.draw(in: NSRect(x: width - cornerW, y: height - cornerH, width: cornerW, height: cornerH))
        bl.draw(in: NSRect(x: 0, y: 0, width: cornerW, height: cornerH))
        br.draw(in: NSRect(x: width - cornerW, y: 0, width: cornerW, height: cornerH))

        // Edges (stretched)
        top.draw(in: NSRect(x: cornerW, y: height - cornerH, width: midW, height: cornerH))
        bottom.draw(in: NSRect(x: cornerW, y: 0, width: midW, height: cornerH))
        left.draw(in: NSRect(x: 0, y: cornerH, width: cornerW, height: midH))
        right.draw(in: NSRect(x: width - cornerW, y: cornerH, width: cornerW, height: midH))

        composite.unlockFocus()
        return composite
    }
}

// MARK: - Android Skin Profile

enum AndroidSkinProfile {
    @MainActor private static var cache: [String: ChromeProfile] = [:]

    @MainActor static func load(for avdName: String) -> ChromeProfile? {
        if let cached = cache[avdName] {
            return cached
        }

        // Find skin path from AVD config
        guard let skinPath = findSkinPath(for: avdName) else {
            return nil
        }

        // Parse layout file
        let layoutPath = "\(skinPath)/layout"
        guard let layoutString = try? String(contentsOfFile: layoutPath, encoding: .utf8),
              let layout = parseLayout(layoutString)
        else {
            return nil
        }

        // Load back.webp as the device frame
        guard let backImage = NSImage(contentsOfFile: "\(skinPath)/back.webp") else {
            return nil
        }

        // The layout gives us:
        // - total size (layouts.portrait.width/height) — this is the back.webp size
        // - screen offset (part2 x/y where part2.name == "device")
        // - screen size (device.display.width/height)
        // - corner radius (device.display.corner_radius)

        let totalW = layout.layoutWidth
        let totalH = layout.layoutHeight
        let screenX = layout.screenX
        let screenY = layout.screenY
        let screenW = layout.screenWidth
        let screenH = layout.screenHeight

        let screenInsets = NSEdgeInsets(
            top: screenY,
            left: screenX,
            bottom: totalH - screenY - screenH,
            right: totalW - screenX - screenW
        )

        // Scale corner radius from screen pixel space to the back.webp coordinate space
        // The layout corner_radius is in screen pixels; we need it relative to the back image
        let cornerRadius = layout.cornerRadius

        let profile = ChromeProfile(
            compositeImage: backImage,
            compositeSize: CGSize(width: totalW, height: totalH),
            screenInsets: screenInsets,
            cornerRadius: cornerRadius,
            buttons: [],
            buttonMargins: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        )

        cache[avdName] = profile
        return profile
    }

    private static func findSkinPath(for avdName: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let avdDir = "\(home)/.android/avd/\(avdName).avd"
        let configPath = "\(avdDir)/config.ini"

        guard let configString = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }

        // Look for skin.path in config
        for line in configString.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("skin.path=") {
                let path = String(trimmed.dropFirst("skin.path=".count))
                // Verify the path has a layout file
                if FileManager.default.fileExists(atPath: "\(path)/layout") {
                    return path
                }
            }
            // Also check skin.name as fallback — look in SDK skins dir
            if trimmed.hasPrefix("skin.name=") {
                let name = String(trimmed.dropFirst("skin.name=".count))
                let sdkPath = "\(home)/Library/Android/sdk/skins/\(name)"
                if FileManager.default.fileExists(atPath: "\(sdkPath)/layout") {
                    return sdkPath
                }
            }
        }

        // Last resort: try matching avdName to skin folder (avd names often use _ for spaces)
        let skinName = avdName.lowercased()
        let sdkPath = "\(home)/Library/Android/sdk/skins/\(skinName)"
        if FileManager.default.fileExists(atPath: "\(sdkPath)/layout") {
            return sdkPath
        }

        return nil
    }

    // MARK: - Layout Parser

    private struct LayoutData {
        let layoutWidth: CGFloat
        let layoutHeight: CGFloat
        let screenX: CGFloat
        let screenY: CGFloat
        let screenWidth: CGFloat
        let screenHeight: CGFloat
        let cornerRadius: CGFloat
    }

    private static func parseLayout(_ text: String) -> LayoutData? {
        // Simple recursive-descent parser for the Android skin layout format
        // Format:
        //   parts { device { display { width N, height N, x N, y N, corner_radius N } } }
        //   layouts { portrait { width N, height N, part2 { name device, x N, y N } } }

        var screenWidth: CGFloat = 0
        var screenHeight: CGFloat = 0
        var cornerRadius: CGFloat = 0
        var layoutWidth: CGFloat = 0
        var layoutHeight: CGFloat = 0
        var deviceX: CGFloat = 0
        var deviceY: CGFloat = 0

        // Tokenize: split on whitespace and braces
        let cleaned = text
            .replacingOccurrences(of: "{", with: " { ")
            .replacingOccurrences(of: "}", with: " } ")
        let tokens = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        // Parse into a nested dictionary structure
        var index = 0

        func parseBlock() -> [(String, Any)] {
            var entries: [(String, Any)] = []
            while index < tokens.count {
                let token = tokens[index]
                if token == "}" {
                    index += 1
                    return entries
                }
                index += 1
                if index < tokens.count {
                    if tokens[index] == "{" {
                        index += 1
                        let children = parseBlock()
                        entries.append((token, children))
                    } else {
                        // key value pair
                        entries.append((token, tokens[index]))
                        index += 1
                    }
                }
            }
            return entries
        }

        let root = parseBlock()

        // Extract display info from parts.device.display
        func findBlock(_ entries: [(String, Any)], _ name: String) -> [(String, Any)]? {
            entries.first(where: { $0.0 == name })?.1 as? [(String, Any)]
        }

        func findValue(_ entries: [(String, Any)], _ name: String) -> String? {
            entries.first(where: { $0.0 == name })?.1 as? String
        }

        if let parts = findBlock(root, "parts"),
           let device = findBlock(parts, "device"),
           let display = findBlock(device, "display") {
            screenWidth = CGFloat(Double(findValue(display, "width") ?? "0") ?? 0)
            screenHeight = CGFloat(Double(findValue(display, "height") ?? "0") ?? 0)
            cornerRadius = CGFloat(Double(findValue(display, "corner_radius") ?? "0") ?? 0)
        }

        if let layouts = findBlock(root, "layouts"),
           let portrait = findBlock(layouts, "portrait") {
            layoutWidth = CGFloat(Double(findValue(portrait, "width") ?? "0") ?? 0)
            layoutHeight = CGFloat(Double(findValue(portrait, "height") ?? "0") ?? 0)

            // Find the part that references "device" for screen offset
            for (key, value) in portrait {
                if key.hasPrefix("part"), let block = value as? [(String, Any)] {
                    if findValue(block, "name") == "device" {
                        deviceX = CGFloat(Double(findValue(block, "x") ?? "0") ?? 0)
                        deviceY = CGFloat(Double(findValue(block, "y") ?? "0") ?? 0)
                    }
                }
            }
        }

        guard layoutWidth > 0, layoutHeight > 0, screenWidth > 0, screenHeight > 0 else {
            return nil
        }

        return LayoutData(
            layoutWidth: layoutWidth,
            layoutHeight: layoutHeight,
            screenX: deviceX,
            screenY: deviceY,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            cornerRadius: cornerRadius
        )
    }
}
