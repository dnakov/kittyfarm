import Foundation

enum XctraceParserError: LocalizedError {
    case exportFailed(stderr: String)
    case xmlMalformed(reason: String)

    var errorDescription: String? {
        switch self {
        case .exportFailed(let stderr):
            return "xctrace export failed: \(stderr.prefix(500))"
        case .xmlMalformed(let reason):
            return "Could not parse xctrace XML: \(reason)"
        }
    }
}

enum XctraceTimeProfileParser {
    /// Run `xctrace export` to extract the `time-profile` table, then SAX-parse
    /// the XML into per-thread time-stamped sample arrays. Symbols and module
    /// names come pre-resolved by xctrace; we just dereference its ID interning.
    static func parse(traceURL: URL) async throws -> TimeProfileTrace {
        let xml = try await runExport(traceURL: traceURL)
        return try parseXML(data: xml)
    }

    private static func runExport(traceURL: URL) async throws -> Data {
        let command = ProcessRunner.Command(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "xctrace", "export",
                "--input", traceURL.path,
                "--xpath", #"/trace-toc/run/data/table[@schema="time-profile"]"#
            ]
        )
        let result = try await ProcessRunner.run(command)
        guard result.terminationStatus == 0 else {
            throw XctraceParserError.exportFailed(stderr: result.stderr)
        }
        return result.stdoutData
    }

    private static func parseXML(data: Data) throws -> TimeProfileTrace {
        let parser = XMLParser(data: data)
        let delegate = TimeProfileSAXDelegate()
        parser.delegate = delegate

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown"
            throw XctraceParserError.xmlMalformed(reason: reason)
        }

        // Group samples by thread, sort each by timestamp.
        let threads: [TimeProfileThread] = delegate.samplesByThread.map { (threadID, raw) in
            let label = delegate.threadLabels[threadID] ?? "Thread \(threadID)"
            let sorted = raw.sorted { $0.timestampNs < $1.timestampNs }
            return TimeProfileThread(id: UInt64(threadID) ?? 0, label: label, samples: sorted)
        }
        .sorted { $0.samples.count > $1.samples.count }   // hottest thread first

        let allSamples = threads.flatMap(\.samples)
        let startNs = allSamples.map(\.timestampNs).min() ?? 0
        let endNs = allSamples.map { $0.timestampNs + $0.weightNs }.max() ?? startNs
        return TimeProfileTrace(startNs: startNs, endNs: endNs, threads: threads)
    }
}

/// SAX delegate. The `time-profile` schema columns appear in a fixed order
/// per row: time, thread, process, core, thread-state, weight, stack. Each
/// can be inline (`id="N"`) or a reference (`ref="N"`); we intern the inline
/// ones so refs cheaply find them.
private final class TimeProfileSAXDelegate: NSObject, XMLParserDelegate {
    var samplesByThread: [String: [TimeProfileSample]] = [:]
    var threadLabels: [String: String] = [:]

    private var sampleTimes: [String: UInt64] = [:]
    private var weights: [String: UInt64] = [:]
    private var binaries: [String: String] = [:]    // id → display name
    private var frames: [String: TimeProfileFrame] = [:]
    private var backtraces: [String: [TimeProfileFrame]] = [:]

    private var inRow = false
    private var rowTimestamp: UInt64 = 0
    private var rowWeight: UInt64 = 0
    private var rowThreadID: String?
    private var rowBacktraceID: String?

    private var inBacktrace = false
    private var currentBacktraceInnerID: String?
    private var currentBacktraceOuterID: String?     // <tagged-backtrace id="…">
    private var currentBacktraceFrames: [TimeProfileFrame] = []

    private var inFrame = false
    private var pendingFrameID: String?
    private var pendingFrameSymbol: String = "?"
    private var pendingFrameAddress: UInt64 = 0
    private var pendingFrameModule: String?

    private var captureText = false
    private var textBuffer = ""
    private var pendingTimeID: String?
    private var pendingWeightID: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row":
            inRow = true
            rowTimestamp = 0
            rowWeight = 0
            rowThreadID = nil
            rowBacktraceID = nil

        case "sample-time":
            if let ref = attributes["ref"] {
                rowTimestamp = sampleTimes[ref] ?? 0
            } else if let id = attributes["id"] {
                pendingTimeID = id
                captureText = true
                textBuffer = ""
            }

        case "thread":
            if let ref = attributes["ref"] {
                rowThreadID = ref
            } else if let id = attributes["id"] {
                rowThreadID = id
                if let fmt = attributes["fmt"] {
                    threadLabels[id] = fmt
                }
            }

        case "weight":
            if let ref = attributes["ref"] {
                rowWeight = weights[ref] ?? 0
            } else if let id = attributes["id"] {
                pendingWeightID = id
                captureText = true
                textBuffer = ""
            }

        case "tagged-backtrace":
            if let ref = attributes["ref"] {
                rowBacktraceID = ref
            } else if let id = attributes["id"] {
                rowBacktraceID = id
                currentBacktraceOuterID = id
            }

        case "backtrace":
            inBacktrace = true
            currentBacktraceInnerID = attributes["id"]
            currentBacktraceFrames = []
            if let ref = attributes["ref"], let cached = backtraces[ref] {
                currentBacktraceFrames = cached
            }

        case "frame":
            inFrame = true
            if let ref = attributes["ref"], let cached = frames[ref] {
                currentBacktraceFrames.append(cached)
                inFrame = false
            } else {
                pendingFrameID = attributes["id"]
                pendingFrameSymbol = attributes["name"] ?? "?"
                pendingFrameAddress = parseHex(attributes["addr"]) ?? 0
                pendingFrameModule = nil
            }

        case "binary":
            if let ref = attributes["ref"], let cached = binaries[ref] {
                pendingFrameModule = cached
            } else {
                let bname = attributes["name"]
                if let id = attributes["id"], let bname {
                    binaries[id] = bname
                }
                pendingFrameModule = bname
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters chars: String) {
        if captureText { textBuffer += chars }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch name {
        case "sample-time":
            if let id = pendingTimeID {
                let value = UInt64(textBuffer.trimmingCharacters(in: .whitespaces)) ?? 0
                sampleTimes[id] = value
                rowTimestamp = value
            }
            pendingTimeID = nil
            captureText = false
            textBuffer = ""

        case "weight":
            if let id = pendingWeightID {
                let value = UInt64(textBuffer.trimmingCharacters(in: .whitespaces)) ?? 0
                weights[id] = value
                rowWeight = value
            }
            pendingWeightID = nil
            captureText = false
            textBuffer = ""

        case "frame":
            if inFrame {
                let frame = TimeProfileFrame(
                    symbol: pendingFrameSymbol,
                    address: pendingFrameAddress,
                    module: pendingFrameModule
                )
                currentBacktraceFrames.append(frame)
                if let id = pendingFrameID {
                    frames[id] = frame
                }
            }
            inFrame = false
            pendingFrameID = nil

        case "backtrace":
            if let id = currentBacktraceInnerID {
                backtraces[id] = currentBacktraceFrames
            }
            if let outer = currentBacktraceOuterID {
                backtraces[outer] = currentBacktraceFrames
            }
            inBacktrace = false

        case "tagged-backtrace":
            currentBacktraceOuterID = nil

        case "row":
            let bt = rowBacktraceID.flatMap { backtraces[$0] } ?? []
            let threadID = rowThreadID ?? "unknown"
            let sample = TimeProfileSample(
                timestampNs: rowTimestamp,
                weightNs: rowWeight,
                backtrace: bt
            )
            samplesByThread[threadID, default: []].append(sample)
            inRow = false

        default:
            break
        }
    }

    private func parseHex(_ str: String?) -> UInt64? {
        guard let str else { return nil }
        let cleaned = str.hasPrefix("0x") ? String(str.dropFirst(2)) : str
        return UInt64(cleaned, radix: 16)
    }
}
