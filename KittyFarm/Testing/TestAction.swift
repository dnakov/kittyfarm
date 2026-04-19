import Foundation

enum TestAction: Sendable {
    case tap(element: String)
    case doubleTap(element: String)
    case longPress(element: String)
    case type(text: String, element: String?)
    case swipe(direction: SwipeDirection, element: String?)
    case waitFor(element: String, timeout: TimeInterval?)
    case assertVisible(element: String)
    case assertNotVisible(element: String)
    case pressHome
    case pause(duration: TimeInterval)
    case open(app: String)

    enum SwipeDirection: String, Sendable {
        case up, down, left, right
    }

    var description: String {
        switch self {
        case .tap(let el): return "tap \"\(el)\""
        case .doubleTap(let el): return "double tap \"\(el)\""
        case .longPress(let el): return "long press \"\(el)\""
        case .type(let text, let el):
            if let el { return "type \"\(text)\" in \"\(el)\"" }
            return "type \"\(text)\""
        case .swipe(let dir, let el):
            if let el { return "swipe \(dir.rawValue) on \"\(el)\"" }
            return "swipe \(dir.rawValue)"
        case .waitFor(let el, let timeout):
            if let timeout { return "wait for \"\(el)\" timeout \(Int(timeout))" }
            return "wait for \"\(el)\""
        case .assertVisible(let el): return "assert visible \"\(el)\""
        case .assertNotVisible(let el): return "assert not visible \"\(el)\""
        case .pressHome: return "press home"
        case .pause(let duration): return "pause \(Int(duration))"
        case .open(let app): return "open \"\(app)\""
        }
    }
}
