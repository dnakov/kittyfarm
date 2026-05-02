import Foundation

struct LocalControlMCPHTTPResponse {
    let status: Int
    let contentType: String
    let headers: [String: String]
    let body: Data
}

@MainActor
enum LocalControlMCPHandler {
    private static let protocolVersion = "2025-06-18"

    static func respond(to body: Data, store: KittyFarmStore) async -> LocalControlMCPHTTPResponse {
        do {
            let value = try JSONSerialization.jsonObject(with: body)
            if let requests = value as? [[String: Any]] {
                var responses: [[String: Any]] = []
                for request in requests {
                    if let response = try await handle(request, store: store) {
                        responses.append(response)
                    }
                }
                return jsonHTTP(responses)
            }

            guard let request = value as? [String: Any] else {
                return jsonHTTP(jsonRPCError(id: nil, code: -32600, message: "Invalid JSON-RPC request."))
            }

            guard let response = try await handle(request, store: store) else {
                return LocalControlMCPHTTPResponse(
                    status: 202,
                    contentType: "application/json",
                    headers: mcpHeaders,
                    body: Data()
                )
            }
            return jsonHTTP(response)
        } catch {
            return jsonHTTP(jsonRPCError(id: nil, code: -32700, message: "Parse error: \(error.localizedDescription)"))
        }
    }

    private static func handle(_ request: [String: Any], store: KittyFarmStore) async throws -> [String: Any]? {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return jsonRPCError(id: id, code: -32600, message: "Missing JSON-RPC method.")
        }

        if method.hasPrefix("notifications/") {
            return nil
        }

        do {
            switch method {
            case "initialize":
                return jsonRPCResult(id: id, result: [
                    "protocolVersion": protocolVersion,
                    "capabilities": [
                        "tools": [:],
                        "resources": [:],
                        "prompts": [:],
                    ],
                    "serverInfo": [
                        "name": "kittyfarm",
                        "version": "0.1.0",
                    ],
                    "instructions": "Control and inspect KittyFarm-managed iOS simulators and Android emulators.",
                ])
            case "ping":
                return jsonRPCResult(id: id, result: [:])
            case "tools/list":
                return jsonRPCResult(id: id, result: ["tools": tools])
            case "resources/list":
                return jsonRPCResult(id: id, result: ["resources": []])
            case "prompts/list":
                return jsonRPCResult(id: id, result: ["prompts": []])
            case "tools/call":
                let params = request["params"] as? [String: Any]
                guard let name = params?["name"] as? String else {
                    return jsonRPCError(id: id, code: -32602, message: "tools/call requires params.name.")
                }
                let arguments = params?["arguments"] as? [String: Any] ?? [:]
                return jsonRPCResult(id: id, result: try await callTool(name, arguments: arguments, store: store))
            default:
                return jsonRPCError(id: id, code: -32601, message: "Unknown MCP method: \(method)")
            }
        } catch {
            return jsonRPCError(id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private static func callTool(
        _ name: String,
        arguments: [String: Any],
        store: KittyFarmStore
    ) async throws -> [String: Any] {
        switch name {
        case "kittyfarm_status":
            return try textResult(store.localControlStatusResponse())
        case "kittyfarm_search_documentation":
            return try await textResult(store.localControlSearchDocumentation(decode(LocalControlDocumentationSearchRequest.self, from: arguments)))
        case "kittyfarm_list_devices":
            return try textResult(store.localControlDevicesResponse())
        case "kittyfarm_connect_device":
            let request = try decode(LocalControlConnectRequest.self, from: arguments)
            return try await textResult(store.localControlConnect(deviceId: request.deviceId))
        case "kittyfarm_disconnect_device":
            let request = try decode(LocalControlConnectRequest.self, from: arguments)
            return try await textResult(store.localControlDisconnect(deviceId: request.deviceId))
        case "kittyfarm_screenshot":
            let request = try decode(LocalControlDeviceRequest.self, from: arguments)
            return try imageResult(store.localControlScreenshot(deviceId: request.deviceId))
        case "kittyfarm_accessibility_tree":
            let request = try decode(LocalControlAccessibilityRequest.self, from: arguments)
            return try await textResult(store.localControlAccessibilityTree(deviceId: request.deviceId, bundleId: request.bundleId))
        case "kittyfarm_find_element":
            return try await textResult(store.localControlFindElement(decode(LocalControlFindElementRequest.self, from: arguments)))
        case "kittyfarm_tap":
            return try await textResult(store.localControlTap(decode(LocalControlTapRequest.self, from: arguments)))
        case "kittyfarm_swipe":
            return try await textResult(store.localControlSwipe(decode(LocalControlSwipeRequest.self, from: arguments)))
        case "kittyfarm_type":
            return try await textResult(store.localControlType(decode(LocalControlTypeRequest.self, from: arguments)))
        case "kittyfarm_press_home":
            let request = try decode(LocalControlDeviceRequest.self, from: arguments)
            return try await textResult(store.localControlPressHome(deviceId: request.deviceId))
        case "kittyfarm_rotate":
            let request = try decode(LocalControlDeviceRequest.self, from: arguments)
            return try await textResult(store.localControlRotate(deviceId: request.deviceId))
        case "kittyfarm_open_app":
            return try await textResult(store.localControlOpenApp(decode(LocalControlOpenAppRequest.self, from: arguments)))
        case "kittyfarm_assert_visible":
            return try await textResult(store.localControlAssertVisible(decode(LocalControlAssertRequest.self, from: arguments)))
        case "kittyfarm_assert_not_visible":
            return try await textResult(store.localControlAssertNotVisible(decode(LocalControlAssertRequest.self, from: arguments)))
        case "kittyfarm_wait_for":
            return try await textResult(store.localControlWaitFor(decode(LocalControlWaitRequest.self, from: arguments)))
        case "kittyfarm_discover_project":
            return try await textResult(store.localControlDiscoverProject(decode(LocalControlDiscoverProjectRequest.self, from: arguments)))
        case "kittyfarm_list_ios_schemes":
            return try await textResult(store.localControlListIOSSchemes(decode(LocalControlIOSSchemesRequest.self, from: arguments)))
        case "kittyfarm_select_ios_project":
            return try await textResult(store.localControlSelectIOSProject(decode(LocalControlSelectIOSProjectRequest.self, from: arguments)))
        case "kittyfarm_select_android_project":
            return try await textResult(store.localControlSelectAndroidProject(decode(LocalControlSelectAndroidProjectRequest.self, from: arguments)))
        case "kittyfarm_build_and_run":
            return try await textResult(store.localControlBuildAndRun(decode(LocalControlBuildRunRequest.self, from: arguments)))
        case "kittyfarm_get_logs":
            let limit = arguments["limit"] as? Int ?? 200
            return try textResult(store.localControlLogs(limit: limit))
        case "kittyfarm_read_logs":
            return try textResult(store.localControlReadLogs(decode(LocalControlReadLogsRequest.self, from: arguments)))
        case "kittyfarm_read_crash_reports":
            return try textResult(store.localControlCrashReports(decode(LocalControlCrashReportsRequest.self, from: arguments)))
        case "kittyfarm_start_screen_recording":
            return try textResult(store.localControlStartScreenRecording(decode(LocalControlScreenRecordingRequest.self, from: arguments)))
        case "kittyfarm_stop_screen_recording":
            let response = try await store.localControlStopScreenRecording(decode(LocalControlScreenRecordingRequest.self, from: arguments))
            return try textResult(response)
        case "kittyfarm_screen_recording_status":
            return try textResult(store.localControlScreenRecordingStatus())
        default:
            throw LocalControlStoreError.invalidRequest("Unknown KittyFarm MCP tool: \(name)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from arguments: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func textResult(_ value: any Encodable) throws -> [String: Any] {
        [
            "content": [
                [
                    "type": "text",
                    "text": try prettyText(value),
                ],
            ],
        ]
    }

    private static func imageResult(_ screenshot: LocalControlScreenshotResponse) throws -> [String: Any] {
        let metadata: [String: Any] = [
            "deviceId": screenshot.deviceId,
            "width": screenshot.width,
            "height": screenshot.height,
            "mimeType": screenshot.mimeType,
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        let metadataText = String(data: metadataData, encoding: .utf8) ?? "{}"
        return [
            "content": [
                [
                    "type": "image",
                    "data": screenshot.base64,
                    "mimeType": screenshot.mimeType,
                ],
                [
                    "type": "text",
                    "text": metadataText,
                ],
            ],
        ]
    }

    private static func prettyText(_ value: any Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(MCPAnyEncodable(value))
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let prettyData = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
        return String(data: prettyData, encoding: .utf8) ?? "{}"
    }

    private static func jsonRPCResult(id: Any?, result: Any) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ]
    }

    private static func jsonRPCError(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message,
            ],
        ]
    }

    private static func jsonHTTP(_ object: Any) -> LocalControlMCPHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return LocalControlMCPHTTPResponse(
            status: 200,
            contentType: "application/json",
            headers: mcpHeaders,
            body: data
        )
    }

    private static let mcpHeaders = [
        "MCP-Protocol-Version": protocolVersion,
    ]

    private static let tools: [[String: Any]] = [
        tool("kittyfarm_status", "KittyFarm Status", "Check high-level KittyFarm app state.", schema()),
        tool("kittyfarm_search_documentation", "Search Documentation", "Search local Apple SDK symbols and semantic Apple documentation.", documentationSearchSchema()),
        tool("kittyfarm_list_devices", "List KittyFarm Devices", "List available and active devices.", schema()),
        tool("kittyfarm_connect_device", "Connect Device", "Activate and connect a KittyFarm device.", deviceSchema()),
        tool("kittyfarm_disconnect_device", "Disconnect Device", "Remove an active KittyFarm device.", deviceSchema()),
        tool("kittyfarm_screenshot", "Device Screenshot", "Return the latest device frame as an MCP image.", deviceSchema()),
        tool("kittyfarm_accessibility_tree", "Accessibility Tree", "Return the current accessibility tree for a device.", queryDeviceSchema(required: ["deviceId"])),
        tool("kittyfarm_find_element", "Find Element", "Resolve an accessibility query to normalized tap coordinates.", queryDeviceSchema()),
        tool("kittyfarm_tap", "Tap Device", "Tap by accessibility query or normalized x/y coordinates.", tapSchema()),
        tool("kittyfarm_swipe", "Swipe Device", "Swipe by direction, element query, or explicit coordinates.", swipeSchema()),
        tool("kittyfarm_type", "Type Text", "Type text by pasteboard and paste shortcut; optionally tap a field first.", typeSchema()),
        tool("kittyfarm_press_home", "Press Home", "Press Home on a device.", deviceSchema()),
        tool("kittyfarm_rotate", "Rotate", "Rotate a device right.", deviceSchema()),
        tool("kittyfarm_open_app", "Open App", "Open an app by display name, bundle id, or application id.", openAppSchema()),
        tool("kittyfarm_assert_visible", "Assert Visible", "Fail unless an accessibility element is visible.", queryDeviceSchema()),
        tool("kittyfarm_assert_not_visible", "Assert Not Visible", "Fail if an accessibility element is visible.", queryDeviceSchema()),
        tool("kittyfarm_wait_for", "Wait For Element", "Wait until an accessibility element appears.", waitSchema()),
        tool("kittyfarm_discover_project", "Discover Project", "Discover iOS and/or Android project settings from a path.", discoverSchema()),
        tool("kittyfarm_list_ios_schemes", "List iOS Schemes", "List schemes from an Xcode project/workspace path or the currently selected iOS project.", iosSchemesSchema()),
        tool("kittyfarm_select_ios_project", "Select iOS Project", "Select and persist the iOS project and optional scheme used by Build & Play.", selectIOSProjectSchema()),
        tool("kittyfarm_select_android_project", "Select Android Project", "Select and persist the Android project, application id, and Gradle task used by Build & Play.", selectAndroidProjectSchema()),
        tool("kittyfarm_build_and_run", "Build And Run", "Build and launch selected projects on active devices, optionally selecting iOS scheme first.", buildRunSchema()),
        tool("kittyfarm_get_logs", "Get Logs", "Return recent KittyFarm build/runtime logs.", logsSchema()),
        tool("kittyfarm_read_logs", "Read Logs", "Read bounded, filtered KittyFarm logs with truncation metadata for MCP diagnostics.", readLogsSchema()),
        tool("kittyfarm_read_crash_reports", "Read Crash Reports", "Read recent bounded macOS DiagnosticReports crash logs for KittyFarm-launched apps.", crashReportsSchema()),
        tool("kittyfarm_start_screen_recording", "Start Screen Recording", "Start per-device screen recording from KittyFarm's live device frame feed.", screenRecordingSchema()),
        tool("kittyfarm_stop_screen_recording", "Stop Screen Recording", "Stop per-device screen recording and return saved .mov paths.", screenRecordingStopSchema()),
        tool("kittyfarm_screen_recording_status", "Screen Recording Status", "List active KittyFarm screen recordings.", schema()),
    ]

    private static func tool(_ name: String, _ title: String, _ description: String, _ inputSchema: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": inputSchema,
        ]
    }

    private static func schema(properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        ]
    }

    private static func deviceSchema() -> [String: Any] {
        schema(properties: ["deviceId": string("KittyFarm deviceId from kittyfarm_list_devices.")], required: ["deviceId"])
    }

    private static func queryDeviceSchema(required: [String] = ["deviceId", "query"]) -> [String: Any] {
        schema(
            properties: [
                "deviceId": string("KittyFarm deviceId from kittyfarm_list_devices."),
                "query": string("Accessibility label, identifier, or value to resolve."),
                "bundleId": string("Optional iOS app bundle identifier. Ignored for Android."),
            ],
            required: required
        )
    }

    private static func tapSchema() -> [String: Any] {
        schema(
            properties: [
                "deviceId": string("KittyFarm deviceId from kittyfarm_list_devices."),
                "query": string("Optional accessibility query to tap."),
                "x": number("Normalized x coordinate from 0 to 1.", minimum: 0, maximum: 1),
                "y": number("Normalized y coordinate from 0 to 1.", minimum: 0, maximum: 1),
                "bundleId": string("Optional iOS app bundle identifier. Ignored for Android."),
            ],
            required: ["deviceId"]
        )
    }

    private static func swipeSchema() -> [String: Any] {
        schema(
            properties: [
                "deviceId": string("KittyFarm deviceId from kittyfarm_list_devices."),
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "query": string("Optional accessibility query to center the swipe on."),
                "startX": number("Normalized start x coordinate.", minimum: 0, maximum: 1),
                "startY": number("Normalized start y coordinate.", minimum: 0, maximum: 1),
                "endX": number("Normalized end x coordinate.", minimum: 0, maximum: 1),
                "endY": number("Normalized end y coordinate.", minimum: 0, maximum: 1),
                "bundleId": string("Optional iOS app bundle identifier. Ignored for Android."),
            ],
            required: ["deviceId"]
        )
    }

    private static func typeSchema() -> [String: Any] {
        schema(
            properties: [
                "deviceId": string("KittyFarm deviceId from kittyfarm_list_devices."),
                "text": string("Text to type."),
                "query": string("Optional field accessibility query to tap before typing."),
                "bundleId": string("Optional iOS app bundle identifier. Ignored for Android."),
            ],
            required: ["deviceId", "text"]
        )
    }

    private static func openAppSchema() -> [String: Any] {
        schema(
            properties: [
                "deviceId": string("KittyFarm deviceId from kittyfarm_list_devices."),
                "app": string("App display name, bundle id, or Android application id."),
            ],
            required: ["deviceId", "app"]
        )
    }

    private static func waitSchema() -> [String: Any] {
        schema(
            properties: [
                "deviceId": string("KittyFarm deviceId from kittyfarm_list_devices."),
                "query": string("Accessibility label, identifier, or value to wait for."),
                "timeout": number("Timeout in seconds.", minimum: 0),
                "bundleId": string("Optional iOS app bundle identifier. Ignored for Android."),
            ],
            required: ["deviceId", "query"]
        )
    }

    private static func discoverSchema() -> [String: Any] {
        schema(
            properties: [
                "path": string("Project directory path."),
                "platform": ["type": "string", "enum": ["ios", "android"]],
            ],
            required: ["path"]
        )
    }

    private static func buildRunSchema() -> [String: Any] {
        schema(
            properties: [
                "iosProjectPath": string("Optional iOS project directory path."),
                "iosScheme": string("Optional iOS Xcode scheme. When provided, it is selected and persisted before building."),
                "androidProjectPath": string("Optional Android project directory path."),
                "androidApplicationID": string("Optional Android application id to launch after install, including build-type suffixes such as .debug."),
                "gradleTask": string("Optional Gradle install task, such as :hashi:installDebug."),
                "deviceIds": [
                    "type": "array",
                    "items": string("KittyFarm deviceId from kittyfarm_list_devices."),
                ],
            ]
        )
    }

    private static func iosSchemesSchema() -> [String: Any] {
        schema(
            properties: [
                "path": string("Optional .xcodeproj, .xcworkspace, or containing folder. Omit to use the selected iOS project."),
            ]
        )
    }

    private static func selectIOSProjectSchema() -> [String: Any] {
        schema(
            properties: [
                "path": string("Optional .xcodeproj, .xcworkspace, or containing folder. Omit to change the selected project's scheme."),
                "scheme": string("Optional Xcode scheme to persist for future Build & Play runs."),
            ]
        )
    }

    private static func selectAndroidProjectSchema() -> [String: Any] {
        schema(
            properties: [
                "path": string("Optional Android project directory, gradlew, or file inside the project. Omit to update the selected Android project."),
                "applicationID": string("Optional Android application id to launch after install, including build-type suffixes such as .debug."),
                "gradleTask": string("Optional Gradle install task, such as :app:installDebug."),
            ]
        )
    }

    private static func logsSchema() -> [String: Any] {
        schema(properties: ["limit": ["type": "integer", "minimum": 1, "maximum": 1000]])
    }

    private static func documentationSearchSchema() -> [String: Any] {
        schema(
            properties: [
                "query": string("Symbol name, framework API, or Apple documentation concept to search for."),
                "mode": [
                    "type": "string",
                    "enum": ["symbols", "docs", "all"],
                    "description": "Search symbols, semantic docs, or both. Defaults to all.",
                ],
                "platform": [
                    "type": "string",
                    "enum": ["macos", "ios", "watchos", "all"],
                    "description": "Optional symbol platform filter. Defaults to all.",
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 25,
                    "description": "Maximum results to return. Defaults to 10 and is capped at 25.",
                ],
            ],
            required: ["query"]
        )
    }

    private static func readLogsSchema() -> [String: Any] {
        schema(
            properties: [
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 200,
                    "description": "Maximum entries to return. Defaults to 50 and is capped at 200.",
                ],
                "minimumSeverity": [
                    "type": "string",
                    "enum": ["info", "warning", "error"],
                    "description": "Return entries at this severity or higher. Defaults to info.",
                ],
                "source": [
                    "type": "string",
                    "enum": ["command", "stdout", "stderr", "system"],
                    "description": "Optional exact log source filter.",
                ],
                "scope": string("Optional exact scope id, such as build or device:<name>."),
                "search": string("Optional case-insensitive substring filter."),
                "since": string("Optional ISO-8601 timestamp. Entries before this are skipped."),
                "maxMessageLength": [
                    "type": "integer",
                    "minimum": 120,
                    "maximum": 2000,
                    "description": "Maximum characters per returned message. Defaults to 600.",
                ],
                "newestFirst": [
                    "type": "boolean",
                    "description": "Return newest entries first. Defaults to false so tail results stay chronological.",
                ],
            ]
        )
    }

    private static func crashReportsSchema() -> [String: Any] {
        schema(
            properties: [
                "processName": string("Optional process name filter, such as Workouts-iOS or KittyFarm."),
                "bundleId": string("Optional bundle identifier filter, such as com.mweinbach.Workouts."),
                "search": string("Optional case-insensitive full-report substring filter."),
                "since": string("Optional ISO-8601 timestamp. Reports older than this are skipped."),
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 25,
                    "description": "Maximum crash reports to return. Defaults to 5 and is capped at 25.",
                ],
                "maxExcerptLength": [
                    "type": "integer",
                    "minimum": 500,
                    "maximum": 20000,
                    "description": "Maximum characters of each report excerpt. Defaults to 4000.",
                ],
                "includeExcerpt": [
                    "type": "boolean",
                    "description": "Include a bounded report excerpt. Defaults to true.",
                ],
            ]
        )
    }

    private static func screenRecordingSchema() -> [String: Any] {
        schema(
            properties: [
                "deviceId": string("Optional single KittyFarm deviceId from kittyfarm_list_devices."),
                "deviceIds": [
                    "type": "array",
                    "items": string("KittyFarm deviceId from kittyfarm_list_devices."),
                    "description": "Optional list of devices to record individually.",
                ],
                "allActive": [
                    "type": "boolean",
                    "description": "Record every active device into separate .mov files.",
                ],
                "fps": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 30,
                    "description": "Recording frame rate. Defaults to 10 fps.",
                ],
                "maxDurationSeconds": [
                    "type": "number",
                    "minimum": 1,
                    "maximum": 600,
                    "description": "Optional auto-stop duration. Defaults to open-ended until stopped.",
                ],
            ]
        )
    }

    private static func screenRecordingStopSchema() -> [String: Any] {
        schema(
            properties: [
                "deviceId": string("Optional single KittyFarm deviceId from kittyfarm_list_devices."),
                "deviceIds": [
                    "type": "array",
                    "items": string("KittyFarm deviceId from kittyfarm_list_devices."),
                    "description": "Optional list of devices to stop recording.",
                ],
                "allActive": [
                    "type": "boolean",
                    "description": "Stop all active screen recordings.",
                ],
            ]
        )
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "number", "description": description]
        if let minimum {
            schema["minimum"] = minimum
        }
        if let maximum {
            schema["maximum"] = maximum
        }
        return schema
    }
}

private struct MCPAnyEncodable: Encodable {
    let value: any Encodable

    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}
