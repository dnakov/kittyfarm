import XCTest

final class KittyProbeTest: XCTestCase {

    override func setUp() {
        continueAfterFailure = true
    }

    func testServeAccessibilityTree() throws {
        let portEnv = ProcessInfo.processInfo.environment["KITTYPROBE_PORT"]
        let requestedPort = portEnv.flatMap(UInt16.init) ?? 19876

        let server = ProbeHTTPServer(port: requestedPort) { method, path in
            if path == "/ping" || path == "/ping/" {
                return (200, Data("ok".utf8), "text/plain")
            }

            if path.hasPrefix("/tree") {
                let bundleId = Self.extractQueryParam(from: path, key: "bundleId")
                let tree = DispatchQueue.main.sync {
                    ElementTreeSnapshot.capture(bundleIdentifier: bundleId)
                }
                do {
                    let json = try JSONEncoder().encode(tree)
                    return (200, json, "application/json")
                } catch {
                    let msg = Data("Failed to encode tree: \(error.localizedDescription)".utf8)
                    return (500, msg, "text/plain")
                }
            }

            return (404, Data("not found".utf8), "text/plain")
        }

        let boundPort = try server.start()
        print("[KittyProbe] port=\(boundPort)")

        // Keep the main run loop alive so DispatchQueue.main.sync (used by the
        // /tree handler for @MainActor snapshot calls) can execute. RunLoop.run()
        // spins forever without blocking the main thread, unlike DispatchSemaphore
        // which would deadlock with main.sync.
        RunLoop.current.run()
    }

    private static func extractQueryParam(from path: String, key: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = String(path[path.index(after: queryStart)...])
        let pairs = query.split(separator: "&")
        for pair in pairs {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == key {
                return String(kv[1]).removingPercentEncoding
            }
        }
        return nil
    }
}
