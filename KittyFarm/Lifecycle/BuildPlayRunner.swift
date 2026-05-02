import Foundation

struct BuildPlayRunner {
    typealias Logger = @Sendable (BuildLogSource, String) async -> Void

    struct LaunchResult: Sendable {
        let launchedDeviceCount: Int
        let runtimeTargets: [RuntimeLogTarget]
    }

    private struct AndroidDiscovery {
        let applicationID: String
        let gradleTask: String
        let moduleName: String

        var appTarget: AndroidAppTarget {
            AndroidAppTarget(
                moduleName: moduleName,
                applicationID: applicationID,
                gradleTask: gradleTask
            )
        }
    }

    private static var fileManager: FileManager { FileManager.default }
    private static let xcodebuildURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
    private static var xcrunURL: URL { XcrunUtils.xcrunURL }

    static func discoverIOSProject(at url: URL, scheme requestedScheme: String? = nil) async throws -> IOSProjectConfiguration {
        let projectURL = try resolveIOSProjectContainer(from: url)
        let schemes = try await listXcodeSchemes(at: projectURL)
        guard let scheme = selectedScheme(from: schemes, requestedScheme: requestedScheme, projectURL: projectURL) else {
            throw BuildPlayError.noXcodeScheme(projectURL.lastPathComponent)
        }

        let bundleID = try? await extractIOSBundleID(projectURL: projectURL, scheme: scheme)
        return IOSProjectConfiguration(
            projectPath: projectURL.path,
            scheme: scheme,
            bundleIdentifier: bundleID,
            schemes: schemes
        )
    }

    static func discoverIOSSchemes(at url: URL) async throws -> (projectURL: URL, schemes: [String]) {
        let projectURL = try resolveIOSProjectContainer(from: url)
        return (projectURL, try await listXcodeSchemes(at: projectURL))
    }

    private static func extractIOSBundleID(projectURL: URL, scheme: String) async throws -> String? {
        var arguments = ["-showBuildSettings", "-scheme", scheme, "-configuration", "Debug"]
        if projectURL.pathExtension == "xcworkspace" {
            arguments.insert(contentsOf: ["-workspace", projectURL.path], at: 0)
        } else {
            arguments.insert(contentsOf: ["-project", projectURL.path], at: 0)
        }

        let result = try await ProcessRunner.run(.init(executableURL: xcodebuildURL, arguments: arguments))
        guard result.terminationStatus == 0 else { return nil }

        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER =") {
                let value = trimmed
                    .replacingOccurrences(of: "PRODUCT_BUNDLE_IDENTIFIER =", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    static func discoverAndroidProject(at url: URL) async throws -> AndroidProjectConfiguration {
        let projectDirectoryURL = try resolveAndroidProjectDirectory(from: url)
        let discoveries = try detectAndroidProjects(in: projectDirectoryURL)
        guard let discovery = preferredAndroidDiscovery(from: discoveries) else {
            throw BuildPlayError.missingAndroidApplicationID(projectDirectoryURL.path)
        }
        return AndroidProjectConfiguration(
            projectDirectoryPath: projectDirectoryURL.path,
            applicationID: discovery.applicationID,
            gradleTask: discovery.gradleTask,
            appTargets: discoveries.map(\.appTarget)
        )
    }

    static func buildAndRunIOS(
        project: IOSProjectConfiguration,
        devices: [DeviceDescriptor],
        logger: Logger? = nil
    ) async throws -> LaunchResult {
        let simulators = devices.compactMap { descriptor -> (udid: String, name: String, runtime: String)? in
            guard case let .iOSSimulator(udid, name, runtime) = descriptor else { return nil }
            return (udid: udid, name: name, runtime: runtime)
        }
        guard !simulators.isEmpty else {
            return LaunchResult(launchedDeviceCount: 0, runtimeTargets: [])
        }
        let primarySimulator = simulators[0]
        let platformPrefix = "[platform iOS]"

        let derivedDataURL = tempBuildRoot()
            .appending(path: "ios")
            .appending(path: sanitizedComponent(project.displayName))
        try recreateDirectory(at: derivedDataURL)

        await logger?(
            .system,
            "\(platformPrefix) Building \(project.scheme) for \(primarySimulator.name) (\(primarySimulator.runtime))"
        )

        var arguments = ["-scheme", project.scheme, "-configuration", "Debug", "-destination", "id=\(primarySimulator.udid)"]
        if project.isWorkspace {
            arguments.insert(contentsOf: ["-workspace", project.projectPath], at: 0)
        } else {
            arguments.insert(contentsOf: ["-project", project.projectPath], at: 0)
        }
        arguments.append(contentsOf: ["-derivedDataPath", derivedDataURL.path, "build", "CODE_SIGNING_ALLOWED=NO"])

        var environment = ProcessInfo.processInfo.environment
        environment["NSUnbufferedIO"] = "YES"

        let buildResult = try await runLoggedCommand(
            .init(executableURL: xcodebuildURL, arguments: arguments, environment: environment),
            context: "xcodebuild \(project.scheme)",
            logPrefix: platformPrefix,
            logger: logger
        )
        try buildResult.requireSuccess("xcodebuild \(project.scheme)")

        let appURL = try findBuiltIOSApp(in: derivedDataURL, preferredName: project.scheme)
        guard let bundleID = Bundle(url: appURL)?.bundleIdentifier, !bundleID.isEmpty else {
            throw BuildPlayError.missingBundleID(appURL.lastPathComponent)
        }
        let executableName = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? project.scheme

        try await withThrowingTaskGroup(of: Void.self) { group in
            for simulator in simulators {
                group.addTask {
                    let udid = simulator.udid
                    let devicePrefix = "[device \(simulator.name) (\(String(udid.prefix(8))))]"
                    await logger?(.system, "\(devicePrefix) Ensuring simulator is booted")
                    try await ensureSimulatorReady(udid: udid, logPrefix: devicePrefix, logger: logger)
                    try await runSimctl(
                        ["install", udid, appURL.path],
                        context: "simctl install \(udid)",
                        logPrefix: devicePrefix,
                        logger: logger
                    )
                    try await runSimctl(
                        ["launch", "--terminate-running-process", udid, bundleID],
                        context: "simctl launch \(bundleID)",
                        logPrefix: devicePrefix,
                        logger: logger,
                        environment: XcrunUtils.simulatorAppLaunchEnvironment
                    )
                }
            }
            try await group.waitForAll()
        }

        return LaunchResult(
            launchedDeviceCount: simulators.count,
            runtimeTargets: simulators.map {
                .iOSSimulator(
                    udid: $0.udid,
                    processName: executableName,
                    deviceLabel: $0.name
                )
            }
        )
    }

    static func buildAndRunAndroid(
        project: AndroidProjectConfiguration,
        devices: [DeviceDescriptor],
        logger: Logger? = nil
    ) async throws -> LaunchResult {
        let avdNames = devices.compactMap { descriptor -> String? in
            guard case let .androidEmulator(avdName, _) = descriptor else { return nil }
            return avdName
        }
        guard !avdNames.isEmpty else {
            return LaunchResult(launchedDeviceCount: 0, runtimeTargets: [])
        }
        let platformPrefix = "[platform Android]"

        var gradleArguments = [project.gradleTask]
        if !gradleArguments.contains("--console=plain") {
            gradleArguments.append("--console=plain")
        }

        let javaEnvironment = try await androidJavaEnvironment()

        let gradleResult = try await runLoggedCommand(.init(
            executableURL: project.gradlewURL,
            arguments: gradleArguments,
            environment: javaEnvironment,
            currentDirectoryURL: project.projectDirectoryURL
        ), context: "gradlew \(project.gradleTask)", logPrefix: platformPrefix, logger: logger)
        try gradleResult.requireSuccess("gradlew \(project.gradleTask)")

        let serials = try await resolveAndroidSerials(for: avdNames, logger: logger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (avdName, serial) in zip(avdNames, serials) {
                group.addTask {
                    let devicePrefix = "[device \(avdName) (\(serial))]"
                    await logger?(.system, "\(devicePrefix) Waiting for emulator to finish booting")
                    try await waitForAndroidBoot(serial: serial, logPrefix: devicePrefix, logger: logger)
                    try await launchAndroidApp(
                        applicationID: project.applicationID,
                        serial: serial,
                        logPrefix: devicePrefix,
                        logger: logger
                    )
                }
            }
            try await group.waitForAll()
        }

        return LaunchResult(
            launchedDeviceCount: serials.count,
            runtimeTargets: zip(avdNames, serials).map { avdName, serial in
                .androidEmulator(serial: serial, applicationID: project.applicationID, deviceLabel: avdName)
            }
        )
    }

    private static func listXcodeSchemes(at projectURL: URL) async throws -> [String] {
        var arguments = ["-list", "-json"]
        if projectURL.pathExtension == "xcworkspace" {
            arguments.append(contentsOf: ["-workspace", projectURL.path])
        } else {
            arguments.append(contentsOf: ["-project", projectURL.path])
        }

        let result = try await ProcessRunner.run(.init(executableURL: xcodebuildURL, arguments: arguments))
        try result.requireSuccess("xcodebuild -list")

        let response = try JSONDecoder().decode(XcodeListResponse.self, from: Data(result.stdout.utf8))
        return response.project?.schemes ?? response.workspace?.schemes ?? []
    }

    private static func preferredScheme(from schemes: [String], projectURL: URL) -> String? {
        let projectName = projectURL.deletingPathExtension().lastPathComponent
        if let matchingProjectName = schemes.first(where: { $0.localizedCaseInsensitiveCompare(projectName) == .orderedSame }) {
            return matchingProjectName
        }

        return schemes.first {
            let lowered = $0.localizedLowercase
            return !lowered.contains("test")
                && !lowered.contains("uitest")
                && !lowered.contains("package")
                && !lowered.contains("extension")
                && !lowered.contains("widget")
                && !lowered.contains("watchkit")
                && !lowered.contains("watch app")
                && !lowered.contains("intent")
        } ?? schemes.first
    }

    private static func selectedScheme(from schemes: [String], requestedScheme: String?, projectURL: URL) -> String? {
        let requestedScheme = requestedScheme?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestedScheme, !requestedScheme.isEmpty else {
            return preferredScheme(from: schemes, projectURL: projectURL)
        }
        if schemes.contains(requestedScheme) {
            return requestedScheme
        }
        return nil
    }

    private static func resolveIOSProjectContainer(from url: URL) throws -> URL {
        let resolvedURL = url.standardizedFileURL
        if ["xcodeproj", "xcworkspace"].contains(resolvedURL.pathExtension) {
            return resolvedURL
        }

        guard directoryExists(at: resolvedURL) else {
            throw BuildPlayError.unsupportedIOSSelection(resolvedURL.path)
        }

        let candidates = try discoverFiles(
            under: resolvedURL,
            matchingExtensions: ["xcworkspace", "xcodeproj"],
            maxDepth: 3
        )
        if let workspace = candidates.first(where: { $0.pathExtension == "xcworkspace" }) {
            return workspace
        }
        if let project = candidates.first(where: { $0.pathExtension == "xcodeproj" }) {
            return project
        }

        throw BuildPlayError.unsupportedIOSSelection(resolvedURL.path)
    }

    private static func resolveAndroidProjectDirectory(from url: URL) throws -> URL {
        let resolvedURL = url.standardizedFileURL

        if resolvedURL.lastPathComponent == "gradlew" {
            return resolvedURL.deletingLastPathComponent()
        }

        if directoryExists(at: resolvedURL),
           fileManager.isExecutableFile(atPath: resolvedURL.appending(path: "gradlew").path) {
            return resolvedURL
        }

        var currentURL = directoryExists(at: resolvedURL) ? resolvedURL : resolvedURL.deletingLastPathComponent()
        while currentURL.path != "/" {
            if fileManager.isExecutableFile(atPath: currentURL.appending(path: "gradlew").path) {
                return currentURL
            }
            currentURL.deleteLastPathComponent()
        }

        if directoryExists(at: resolvedURL),
           let gradlewURL = try discoverFiles(under: resolvedURL, matchingNames: ["gradlew"], maxDepth: 3).first {
            return gradlewURL.deletingLastPathComponent()
        }

        throw BuildPlayError.unsupportedAndroidSelection(resolvedURL.path)
    }

    private static func detectAndroidProjects(in projectDirectoryURL: URL) throws -> [AndroidDiscovery] {
        let candidates = [
            projectDirectoryURL.appending(path: "app/build.gradle.kts"),
            projectDirectoryURL.appending(path: "app/build.gradle"),
            projectDirectoryURL.appending(path: "build.gradle.kts"),
            projectDirectoryURL.appending(path: "build.gradle")
        ]

        var discoveries: [AndroidDiscovery] = []
        var seenBuildFiles: Set<String> = []
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            if let discovery = try detectAndroidProject(in: candidate, projectDirectoryURL: projectDirectoryURL) {
                discoveries.append(discovery)
                seenBuildFiles.insert(candidate.standardizedFileURL.path)
            }
        }

        let buildFiles = try discoverFiles(
            under: projectDirectoryURL,
            matchingNames: ["build.gradle.kts", "build.gradle"],
            maxDepth: 4
        )

        for candidate in buildFiles where !seenBuildFiles.contains(candidate.standardizedFileURL.path) {
            if let discovery = try detectAndroidProject(in: candidate, projectDirectoryURL: projectDirectoryURL) {
                discoveries.append(discovery)
            }
        }

        let uniqueDiscoveries = Dictionary(grouping: discoveries, by: \.gradleTask)
            .compactMap { _, values in values.first }
        return uniqueDiscoveries.sorted { $0.gradleTask < $1.gradleTask }
    }

    private static func preferredAndroidDiscovery(from discoveries: [AndroidDiscovery]) -> AndroidDiscovery? {
        discoveries.first { $0.gradleTask == ":app:installDebug" }
            ?? discoveries.first { $0.gradleTask == "installDebug" }
            ?? discoveries.first
    }

    private static func detectAndroidProject(
        in buildFileURL: URL,
        projectDirectoryURL: URL
    ) throws -> AndroidDiscovery? {
        let contents = try String(contentsOf: buildFileURL, encoding: .utf8)
        guard var applicationID = matchFirst(
            in: contents,
            pattern: #"applicationId\s*(?:=|\s)\s*["']([^"']+)["']"#
        ) else {
            return nil
        }

        let applicationIDSuffixPattern = #"applicationIdSuffix\s*(?:=|\s)\s*["']([^"']+)["']"#
        let debugSuffix = block(named: "debug", in: contents)
            .flatMap { matchFirst(in: $0, pattern: applicationIDSuffixPattern) }
            ?? matchFirst(in: contents, pattern: applicationIDSuffixPattern)

        if let debugSuffix {
            applicationID += debugSuffix
        }

        return AndroidDiscovery(
            applicationID: applicationID,
            gradleTask: androidInstallTask(for: buildFileURL, projectDirectoryURL: projectDirectoryURL),
            moduleName: androidModuleName(for: buildFileURL, projectDirectoryURL: projectDirectoryURL)
        )
    }

    private static func androidInstallTask(for buildFileURL: URL, projectDirectoryURL: URL) -> String {
        let moduleURL = buildFileURL.deletingLastPathComponent().standardizedFileURL
        let rootURL = projectDirectoryURL.standardizedFileURL
        guard moduleURL.path != rootURL.path else {
            return "installDebug"
        }

        let relativePath = moduleURL.path
            .replacingOccurrences(of: rootURL.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let modulePath = relativePath
            .split(separator: "/")
            .joined(separator: ":")

        return modulePath.isEmpty ? "installDebug" : ":\(modulePath):installDebug"
    }

    private static func androidModuleName(for buildFileURL: URL, projectDirectoryURL: URL) -> String {
        let moduleURL = buildFileURL.deletingLastPathComponent().standardizedFileURL
        let rootURL = projectDirectoryURL.standardizedFileURL
        guard moduleURL.path != rootURL.path else {
            return projectDirectoryURL.lastPathComponent
        }

        return moduleURL.path
            .replacingOccurrences(of: rootURL.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func findBuiltIOSApp(in derivedDataURL: URL, preferredName: String) throws -> URL {
        let productsURL = derivedDataURL.appending(path: "Build/Products")
        let appCandidates = try discoverFiles(under: productsURL, matchingExtensions: ["app"], maxDepth: 3)
            .filter { !$0.lastPathComponent.localizedCaseInsensitiveContains("Tests") }

        if let preferred = appCandidates.first(where: { $0.lastPathComponent == "\(preferredName).app" }) {
            return preferred
        }
        if let first = appCandidates.first {
            return first
        }

        throw BuildPlayError.missingBuiltApp(productsURL.path)
    }

    private static func ensureSimulatorReady(
        udid: String,
        logPrefix: String? = nil,
        logger: Logger?
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try PrivateSimulatorBooter.bootDevice(udid: udid)
        }.value

        try await runSimctl(
            ["bootstatus", udid, "-b"],
            context: "simctl bootstatus \(udid)",
            logPrefix: logPrefix,
            logger: logger
        )
    }

    private static func resolveAndroidSerials(
        for avdNames: [String],
        logger: Logger?
    ) async throws -> [String] {
        let adbURL = adbBinaryURL()
        let devicesResult = try await runLoggedCommand(
            .init(executableURL: adbURL, arguments: ["devices"]),
            context: "adb devices",
            logger: logger
        )
        try devicesResult.requireSuccess("adb devices")

        let lines = devicesResult.stdout
            .split(separator: "\n")
            .dropFirst()
            .map(String.init)

        var serialsByAVDName: [String: String] = [:]
        for line in lines {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[1] == "device" else { continue }
            let serial = String(parts[0])
            guard serial.hasPrefix("emulator-") else { continue }

            let avdResult = try await runLoggedCommand(.init(
                executableURL: adbURL,
                arguments: ["-s", serial, "emu", "avd", "name"]
            ), context: "adb emu avd name \(serial)", logger: logger)
            guard avdResult.terminationStatus == 0 else { continue }

            let avdName = avdResult.stdout
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty && $0 != "OK" }) ?? ""
            if !avdName.isEmpty {
                serialsByAVDName[avdName] = serial
            }
        }

        let serials = avdNames.compactMap { serialsByAVDName[$0] }
        if serials.count != avdNames.count {
            let missing = avdNames.filter { serialsByAVDName[$0] == nil }
            throw BuildPlayError.androidSerialLookupFailed(missing.joined(separator: ", "))
        }

        return serials
    }

    private static func waitForAndroidBoot(
        serial: String,
        logPrefix: String? = nil,
        logger: Logger?
    ) async throws {
        let adbURL = adbBinaryURL()
        let waitResult = try await runLoggedCommand(.init(
            executableURL: adbURL,
            arguments: ["-s", serial, "wait-for-device"]
        ), context: "adb wait-for-device \(serial)", logPrefix: logPrefix, logger: logger)
        try waitResult.requireSuccess("adb wait-for-device \(serial)")

        for _ in 0..<30 {
            let result = try await runLoggedCommand(.init(
                executableURL: adbURL,
                arguments: ["-s", serial, "shell", "getprop", "sys.boot_completed"]
            ), context: "adb getprop sys.boot_completed \(serial)", logPrefix: logPrefix, logger: logger)
            if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        throw BuildPlayError.androidBootTimeout(serial)
    }

    private static func launchAndroidApp(
        applicationID: String,
        serial: String,
        logPrefix: String? = nil,
        logger: Logger?
    ) async throws {
        let resolveResult = try await runLoggedCommand(.init(
            executableURL: adbBinaryURL(),
            arguments: ["-s", serial, "shell", "cmd", "package", "resolve-activity", "--brief", applicationID]
        ), context: "adb resolve launcher \(applicationID)", logPrefix: logPrefix, logger: logger)
        try resolveResult.requireSuccess("adb resolve launcher \(applicationID)")

        guard let activity = resolveResult.stdout
            .split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .last(where: { $0.contains("/") && !$0.contains("No activity") }) else {
            throw BuildPlayError.androidLauncherActivityNotFound(applicationID)
        }

        try await runADB(
            ["-s", serial, "shell", "am", "start", "-n", activity],
            context: "adb launch \(applicationID)",
            logPrefix: logPrefix,
            logger: logger
        )
    }

    private static func runSimctl(
        _ arguments: [String],
        context: String,
        logPrefix: String? = nil,
        logger: Logger?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        let result = try await runLoggedCommand(.init(
            executableURL: xcrunURL,
            arguments: ["simctl"] + arguments,
            environment: environment
        ), context: context, logPrefix: logPrefix, logger: logger)
        try result.requireSuccess(context)
    }

    private static func runADB(
        _ arguments: [String],
        context: String,
        logPrefix: String? = nil,
        logger: Logger?
    ) async throws {
        let result = try await runLoggedCommand(.init(
            executableURL: adbBinaryURL(),
            arguments: arguments
        ), context: context, logPrefix: logPrefix, logger: logger)
        try result.requireSuccess(context)
    }

    private static func runLoggedCommand(
        _ command: ProcessRunner.Command,
        context: String,
        logPrefix: String? = nil,
        logger: Logger?
    ) async throws -> ProcessRunner.Result {
        await logger?(.command, prefixed(logPrefix, "$ \(shellCommandDescription(for: command))"))

        let result = try await ProcessRunner.run(command) { event in
            let source: BuildLogSource = event.stream == .stdout ? .stdout : .stderr
            await logger?(source, prefixed(logPrefix, event.text))
        }

        if result.terminationStatus != 0 {
            await logger?(.system, prefixed(logPrefix, "\(context) failed with exit code \(result.terminationStatus)"))
        }

        return result
    }

    private static func prefixed(_ prefix: String?, _ message: String) -> String {
        guard let prefix, !prefix.isEmpty else { return message }
        return "\(prefix) \(message)"
    }

    private static func adbBinaryURL() -> URL {
        ADBUtils.binaryURL
    }

    private static func androidJavaEnvironment() async throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        if let configuredJavaHome = environment["JAVA_HOME"],
           !configuredJavaHome.isEmpty {
            environment["PATH"] = prependToPATH("\(configuredJavaHome)/bin", existing: environment["PATH"])
            return environment
        }

        if let discoveredJavaHome = try await discoverJavaHome() {
            environment["JAVA_HOME"] = discoveredJavaHome
            environment["PATH"] = prependToPATH("\(discoveredJavaHome)/bin", existing: environment["PATH"])
            return environment
        }

        throw BuildPlayError.missingJavaRuntime
    }

    private static func discoverJavaHome() async throws -> String? {
        let candidatePaths = [
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
            "/Applications/Android Studio.app/Contents/jre/Contents/Home"
        ]

        for candidate in candidatePaths where fileManager.fileExists(atPath: candidate) {
            return candidate
        }

        let javaHomeExecutable = URL(fileURLWithPath: "/usr/libexec/java_home")
        guard fileManager.isExecutableFile(atPath: javaHomeExecutable.path) else {
            return nil
        }

        let result = try await ProcessRunner.run(.init(executableURL: javaHomeExecutable))
        guard result.terminationStatus == 0 else {
            return nil
        }

        let javaHome = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return javaHome.isEmpty ? nil : javaHome
    }

    private static func prependToPATH(_ pathComponent: String, existing: String?) -> String {
        let current = existing ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        if current.split(separator: ":").contains(Substring(pathComponent)) {
            return current
        }
        guard !current.isEmpty else { return pathComponent }
        return "\(pathComponent):\(current)"
    }

    private static func tempBuildRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "KittyFarmBuilds")
    }

    private static func recreateDirectory(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func discoverFiles(
        under directoryURL: URL,
        matchingExtensions: Set<String>,
        maxDepth: Int
    ) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: directoryURL.path, with: "")
            let depth = relativePath.split(separator: "/").count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if matchingExtensions.contains(fileURL.pathExtension) {
                results.append(fileURL)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private static func discoverFiles(
        under directoryURL: URL,
        matchingNames: Set<String>,
        maxDepth: Int
    ) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: directoryURL.path, with: "")
            let depth = relativePath.split(separator: "/").count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if matchingNames.contains(fileURL.lastPathComponent) {
                results.append(fileURL)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func matchFirst(in contents: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(contents.startIndex..., in: contents)
        guard let match = regex.firstMatch(in: contents, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: contents) else {
            return nil
        }
        return String(contents[valueRange])
    }

    private static func block(named name: String, in contents: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b\#(name)\b\s*\{"#) else {
            return nil
        }
        let range = NSRange(contents.startIndex..., in: contents)
        guard let match = regex.firstMatch(in: contents, range: range),
              let matchRange = Range(match.range, in: contents),
              let openingBrace = contents[matchRange].lastIndex(of: "{") else {
            return nil
        }

        var depth = 1
        var index = contents.index(after: openingBrace)
        while index < contents.endIndex {
            switch contents[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(contents[contents.index(after: openingBrace)..<index])
                }
            default:
                break
            }
            index = contents.index(after: index)
        }
        return nil
    }

    private static func sanitizedComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.map(String.init).joined()
    }

    private static func shellCommandDescription(for command: ProcessRunner.Command) -> String {
        let parts = [command.executableURL.path] + command.arguments
        return parts.map(shellEscape).joined(separator: " ")
    }

    private static func shellEscape(_ argument: String) -> String {
        guard argument.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || argument.contains("'") else {
            return argument
        }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private struct XcodeListResponse: Decodable {
    struct Container: Decodable {
        let schemes: [String]?
    }

    let project: Container?
    let workspace: Container?
}

enum BuildPlayError: LocalizedError {
    case unsupportedIOSSelection(String)
    case noXcodeScheme(String)
    case missingBuiltApp(String)
    case missingBundleID(String)
    case unsupportedAndroidSelection(String)
    case missingAndroidApplicationID(String)
    case missingJavaRuntime
    case androidSerialLookupFailed(String)
    case androidBootTimeout(String)
    case androidLauncherActivityNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedIOSSelection(path):
            return "No Xcode project or workspace was found in \(path)."
        case let .noXcodeScheme(name):
            return "No runnable Xcode scheme was found for \(name)."
        case let .missingBuiltApp(path):
            return "Couldn't find a built iOS app under \(path)."
        case let .missingBundleID(name):
            return "Couldn't read the iOS bundle identifier from \(name)."
        case let .unsupportedAndroidSelection(path):
            return "No Gradle wrapper was found in \(path)."
        case let .missingAndroidApplicationID(path):
            return "Couldn't detect an Android applicationId in \(path)."
        case .missingJavaRuntime:
            return "Couldn't find a Java runtime for Gradle. Install a JDK or launch Android Studio so its bundled runtime is available."
        case let .androidSerialLookupFailed(names):
            return "Couldn't match running Android emulators for: \(names)."
        case let .androidBootTimeout(serial):
            return "Timed out waiting for Android emulator \(serial) to finish booting."
        case let .androidLauncherActivityNotFound(applicationID):
            return "No launcher activity was found for Android app \(applicationID)."
        }
    }
}
