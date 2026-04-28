import Foundation

enum LocalControlCrashReportReader {
    static func read(_ request: LocalControlCrashReportsRequest) throws -> LocalControlCrashReportsResponse {
        let limit = max(1, min(request.limit ?? 5, 25))
        let maxExcerptLength = max(500, min(request.maxExcerptLength ?? 4_000, 20_000))
        let includeExcerpt = request.includeExcerpt ?? true
        let normalizedProcess = request.processName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let normalizedBundle = request.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let normalizedSearch = request.search?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let reports = try reportFiles()
        let matched = reports.compactMap { file -> LocalControlCrashReportDTO? in
            guard request.since == nil || file.modifiedAt >= request.since! else { return nil }
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { return nil }
            let summary = CrashSummary(text: text)

            if let normalizedProcess,
               summary.processName?.range(of: normalizedProcess, options: [.caseInsensitive, .diacriticInsensitive]) == nil,
               file.url.lastPathComponent.range(of: normalizedProcess, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return nil
            }
            if let normalizedBundle,
               summary.bundleIdentifier?.range(of: normalizedBundle, options: [.caseInsensitive, .diacriticInsensitive]) == nil,
               text.range(of: normalizedBundle, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return nil
            }
            if let normalizedSearch,
               text.range(of: normalizedSearch, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return nil
            }

            let excerpt = includeExcerpt ? truncate(text, maxLength: maxExcerptLength).text : nil
            return LocalControlCrashReportDTO(
                path: file.url.path,
                fileName: file.url.lastPathComponent,
                modifiedAt: file.modifiedAt,
                processName: summary.processName,
                bundleIdentifier: summary.bundleIdentifier,
                dateTime: summary.dateTime,
                exceptionType: summary.exceptionType,
                terminationReason: summary.terminationReason,
                triggeredThread: summary.triggeredThread,
                crashedThreadTitle: summary.crashedThreadTitle,
                topFrames: summary.topFrames,
                excerpt: excerpt,
                truncated: includeExcerpt && text.count > maxExcerptLength
            )
        }

        let selected = Array(matched.prefix(limit))
        return LocalControlCrashReportsResponse(
            totalAvailable: reports.count,
            matchedCount: matched.count,
            returnedCount: selected.count,
            omittedCount: max(matched.count - selected.count, 0),
            limit: limit,
            filters: LocalControlCrashReportFilters(
                processName: normalizedProcess,
                bundleId: normalizedBundle,
                search: normalizedSearch,
                since: request.since,
                includeExcerpt: includeExcerpt,
                maxExcerptLength: maxExcerptLength
            ),
            reports: selected
        )
    }

    private static func reportFiles() throws -> [ReportFile] {
        let directory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs")
            .appending(path: "DiagnosticReports")

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        )

        return urls.compactMap { url in
            guard ["ips", "crash", "diag"].contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modifiedAt = values?.contentModificationDate else {
                return nil
            }
            return ReportFile(url: url, modifiedAt: modifiedAt)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func truncate(_ text: String, maxLength: Int) -> (text: String, truncated: Bool) {
        guard text.count > maxLength else { return (text, false) }
        let end = text.index(text.startIndex, offsetBy: maxLength)
        return (String(text[..<end]) + "\n... [truncated \(text.count - maxLength) chars]", true)
    }
}

private struct ReportFile {
    let url: URL
    let modifiedAt: Date
}

private struct CrashSummary {
    let processName: String?
    let bundleIdentifier: String?
    let dateTime: String?
    let exceptionType: String?
    let terminationReason: String?
    let triggeredThread: String?
    let crashedThreadTitle: String?
    let topFrames: [String]

    init(text: String) {
        if let summary = Self.ipsSummary(text: text) {
            processName = summary.processName
            bundleIdentifier = summary.bundleIdentifier
            dateTime = summary.dateTime
            exceptionType = summary.exceptionType
            terminationReason = summary.terminationReason
            triggeredThread = summary.triggeredThread
            crashedThreadTitle = summary.crashedThreadTitle
            topFrames = summary.topFrames
            return
        }

        let lines = text.components(separatedBy: .newlines)
        processName = Self.value(after: "Process:", in: lines)
        bundleIdentifier = Self.value(after: "Identifier:", in: lines)
        dateTime = Self.value(after: "Date/Time:", in: lines)
        exceptionType = Self.value(after: "Exception Type:", in: lines)
        terminationReason = Self.value(after: "Termination Reason:", in: lines)
        triggeredThread = Self.value(after: "Triggered by Thread:", in: lines)

        if let index = lines.firstIndex(where: { $0.range(of: #"Thread \d+ Crashed"#, options: .regularExpression) != nil }) {
            crashedThreadTitle = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            topFrames = lines[(index + 1)...]
                .prefix { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(12)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            crashedThreadTitle = nil
            topFrames = []
        }
    }

    private static func ipsSummary(text: String) -> CrashSummary? {
        guard let newline = text.firstIndex(of: "\n") else { return nil }

        let headerData = Data(text[..<newline].utf8)
        let bodyStart = text.index(after: newline)
        let bodyData = Data(text[bodyStart...].utf8)

        guard let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }

        let processName = body["procName"] as? String ?? header["app_name"] as? String ?? header["name"] as? String
        let bundleInfo = body["bundleInfo"] as? [String: Any]
        let bundleIdentifier = bundleInfo?["CFBundleIdentifier"] as? String ?? header["bundleID"] as? String
        let dateTime = body["captureTime"] as? String ?? header["timestamp"] as? String

        let exception = body["exception"] as? [String: Any]
        let signal = exception?["signal"] as? String
        let exceptionType = [exception?["type"] as? String, signal.map { "(\($0))" }]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty

        let termination = body["termination"] as? [String: Any]
        let terminationReason = terminationReason(from: termination)
        let faultingThread = body["faultingThread"] as? Int
        let triggeredThread = faultingThread.map(String.init)
        let threads = body["threads"] as? [[String: Any]] ?? []
        let triggeredThreadDictionary = threadDictionary(in: threads, faultingThread: faultingThread)
        let crashedThreadTitle = crashedThreadTitle(
            thread: triggeredThreadDictionary.thread,
            ordinal: triggeredThreadDictionary.ordinal
        )
        let topFrames = topFrames(
            from: triggeredThreadDictionary.thread?["frames"] as? [[String: Any]] ?? [],
            imageNames: imageNames(from: body["usedImages"] as? [[String: Any]] ?? [])
        )

        return CrashSummary(
            processName: processName,
            bundleIdentifier: bundleIdentifier,
            dateTime: dateTime,
            exceptionType: exceptionType,
            terminationReason: terminationReason,
            triggeredThread: triggeredThread,
            crashedThreadTitle: crashedThreadTitle,
            topFrames: topFrames
        )
    }

    private init(
        processName: String?,
        bundleIdentifier: String?,
        dateTime: String?,
        exceptionType: String?,
        terminationReason: String?,
        triggeredThread: String?,
        crashedThreadTitle: String?,
        topFrames: [String]
    ) {
        self.processName = processName
        self.bundleIdentifier = bundleIdentifier
        self.dateTime = dateTime
        self.exceptionType = exceptionType
        self.terminationReason = terminationReason
        self.triggeredThread = triggeredThread
        self.crashedThreadTitle = crashedThreadTitle
        self.topFrames = topFrames
    }

    private static func terminationReason(from termination: [String: Any]?) -> String? {
        guard let termination else { return nil }
        let namespace = termination["namespace"] as? String
        let code = termination["code"].map { String(describing: $0) }
        let indicator = termination["indicator"] as? String

        var parts: [String] = []
        if let namespace { parts.append("Namespace \(namespace)") }
        if let code { parts.append("Code \(code)") }
        if let indicator { parts.append(indicator) }
        return parts.joined(separator: ", ").nilIfEmpty
    }

    private static func threadDictionary(
        in threads: [[String: Any]],
        faultingThread: Int?
    ) -> (ordinal: Int?, thread: [String: Any]?) {
        if let index = threads.firstIndex(where: { ($0["triggered"] as? Bool) == true }) {
            return (index, threads[index])
        }
        if let faultingThread, threads.indices.contains(faultingThread) {
            return (faultingThread, threads[faultingThread])
        }
        return (nil, nil)
    }

    private static func crashedThreadTitle(thread: [String: Any]?, ordinal: Int?) -> String? {
        guard let thread else { return nil }
        let number = ordinal.map { String($0) } ?? (thread["id"].map { String(describing: $0) } ?? "?")
        let label = thread["name"] as? String ?? thread["queue"] as? String
        if let label, !label.isEmpty {
            return "Thread \(number) Crashed: \(label)"
        }
        return "Thread \(number) Crashed"
    }

    private static func imageNames(from images: [[String: Any]]) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: images.enumerated().compactMap { index, image in
            guard let name = image["name"] as? String ?? image["path"] as? String else { return nil }
            return (index, name)
        })
    }

    private static func topFrames(from frames: [[String: Any]], imageNames: [Int: String]) -> [String] {
        frames.prefix(12).enumerated().map { index, frame in
            let imageName = (frame["imageIndex"] as? Int).flatMap { imageNames[$0] }
            let symbol = frame["symbol"] as? String
            let sourceFile = frame["sourceFile"] as? String
            let sourceLine = frame["sourceLine"].map { String(describing: $0) }
            let offset = frame["imageOffset"].map { "offset \(String(describing: $0))" }

            var location = symbol ?? offset ?? "unknown"
            if let sourceFile {
                location += " (\(sourceFile)\(sourceLine.map { ":\($0)" } ?? ""))"
            }
            if let imageName {
                return "\(index) \(imageName) \(location)"
            }
            return "\(index) \(location)"
        }
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
