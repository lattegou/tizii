import Foundation
import Darwin

actor MihomoProcessManager {
    enum CoreState {
        case idle
        case starting
        case stopping
        case restarting
    }

    enum ProcessError: LocalizedError {
        case corePathMissing(String)
        case startupTimeout
        case startupFailed(String)
        case profileCheckFailed(String)
        case invalidControllerAddress

        var errorDescription: String? {
            switch self {
            case .corePathMissing(let path):
                "mihomo core binary not found at \(path)"
            case .startupTimeout:
                "mihomo core startup timed out"
            case .startupFailed(let reason):
                reason
            case .profileCheckFailed(let detail):
                "profile check failed: \(detail)"
            case .invalidControllerAddress:
                "invalid controller address"
            }
        }
    }

    private struct PreparedCore {
        let corePath: URL
        let workDir: URL
        let endpoint: ControllerEndpointHolder.Endpoint
        let tunEnabled: Bool
        let autoSetDNS: Bool
    }

    private let config: ConfigService
    private let generator: ProfileGenerator
    private let endpointHolder: ControllerEndpointHolder
    private let api: MihomoAPIClient
    private let permissions: PermissionsService?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var logFileHandle: FileHandle?
    private var currentCoreLogDate: String = ""
    private var coreState: CoreState = .idle
    private var startupReady = false
    private var startupError: Error?

    private var coreWatcherSource: DispatchSourceFileSystemObject?
    private var coreWatcherFD: Int32 = -1
    private var metaUpdateDirExists: Bool = false
    private let coreLogDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    init(
        config: ConfigService,
        generator: ProfileGenerator,
        endpointHolder: ControllerEndpointHolder,
        api: MihomoAPIClient,
        permissions: PermissionsService? = nil
    ) {
        self.config = config
        self.generator = generator
        self.endpointHolder = endpointHolder
        self.api = api
        self.permissions = permissions
    }

    func startCore(allowRestarting: Bool = false, skipStop: Bool = false) async throws {
        guard coreState == .idle || (allowRestarting && coreState == .restarting) else {
            swiftLog.info("[ProcessMgr] startCore 跳过: coreState=\(coreState)")
            return
        }
        let wasRestarting = coreState == .restarting
        coreState = .starting
        defer { coreState = wasRestarting ? .restarting : .idle }

        swiftLog.info("[ProcessMgr] startCore 开始 allowRestarting=\(allowRestarting) skipStop=\(skipStop)")
        let prepared = try await prepareCore(skipStop: skipStop)
        swiftLog.info("[ProcessMgr] prepareCore 完成: endpoint=\(prepared.endpoint) tun=\(prepared.tunEnabled) autoSetDNS=\(prepared.autoSetDNS)")
        if prepared.tunEnabled {
            flushSystemDNSCache()
            swiftLog.info("[ProcessMgr] DNS 缓存已刷新 (TUN 模式)")
        }
        let proc = try spawnCoreProcess(prepared)
        process = proc
        swiftLog.info("[ProcessMgr] mihomo 进程已启动 pid=\(proc.processIdentifier) args=\(proc.arguments ?? [])")

        try await waitForStartupReady(timeoutSeconds: 20)
        swiftLog.info("[ProcessMgr] mihomo stdout 就绪信号已收到")
        try await waitForCoreReady(maxAttempts: 30, retryIntervalMs: 500)
        swiftLog.info("[ProcessMgr] mihomo REST API 可达，开始启动 WebSocket streams")
        await api.startStreams()
        swiftLog.info("[ProcessMgr] startCore 完成")
    }

    func stopCore() async {
        guard coreState == .idle || coreState == .restarting else {
            swiftLog.info("[ProcessMgr] stopCore 跳过: coreState=\(coreState)")
            return
        }
        let wasRestarting = coreState == .restarting
        coreState = .stopping
        defer { coreState = wasRestarting ? .restarting : .idle }

        swiftLog.info("[ProcessMgr] stopCore 开始")
        if let permissions {
            try? await permissions.recoverDNS()
        }
        await api.stopStreams()
        await stopRunningProcess()
        cleanupSocketFiles()
        endpointHolder.clear()
        swiftLog.info("[ProcessMgr] stopCore 完成")
    }

    func restartCore() async throws {
        guard coreState == .idle else {
            swiftLog.info("[ProcessMgr] restartCore 跳过: coreState=\(coreState)")
            return
        }
        coreState = .restarting
        defer { coreState = .idle }

        swiftLog.info("[ProcessMgr] restartCore 开始（最多 3 次尝试）")
        var lastError: Error?
        for attempt in 1...3 {
            await stopCore()
            do {
                try await startCore(allowRestarting: true, skipStop: true)
                swiftLog.info("[ProcessMgr] restartCore 成功 (第 \(attempt) 次尝试)")
                return
            } catch {
                lastError = error
                swiftLog.warn("[ProcessMgr] restartCore 第 \(attempt) 次尝试失败: \(error.localizedDescription)")
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(Double(attempt)))
                    cleanupSocketFiles()
                }
            }
        }
        if let lastError {
            swiftLog.error("[ProcessMgr] restartCore 全部 3 次尝试失败")
            throw lastError
        }
    }

    // MARK: - Prepare

    private func prepareCore(skipStop: Bool) async throws -> PreparedCore {
        let appConfig = try await config.loadAppConfig()
        let mihomoConfig = try await config.loadControledMihomoConfig()

        let core = appConfig["core"]?.stringValue ?? "mihomo"
        let autoSetDNS = appConfig["autoSetDNS"]?.boolValue ?? true
        let diffWorkDir = appConfig["diffWorkDir"]?.boolValue ?? false
        let tunEnabled = mihomoConfig["tun"]?["enable"]?.boolValue ?? false
        await cleanupPidFileProcess()

        let generatedPath = try await generator.generate()
        let currentProfileID = generatedPath.deletingLastPathComponent().lastPathComponent
        let workConfigPath = diffWorkDir ? PathManager.mihomoWorkConfigPath(id: currentProfileID) : PathManager.mihomoWorkConfigPath(id: "work")
        try checkProfile(configPath: workConfigPath, core: core)

        if !skipStop {
            await stopCore()
        }
        cleanupSocketFiles()
        if tunEnabled, autoSetDNS, let permissions {
            try? await permissions.setPublicDNS()
        }

        let endpoint = try await resolveControllerEndpoint()
        endpointHolder.update(endpoint)

        let workDir = diffWorkDir ? PathManager.mihomoProfileWorkDir(id: currentProfileID) : PathManager.mihomoWorkDir
        let corePath = PathManager.mihomoCorePath(core: core)
        guard FileManager.default.isExecutableFile(atPath: corePath.path) else {
            throw ProcessError.corePathMissing(corePath.path)
        }

        return PreparedCore(
            corePath: corePath,
            workDir: workDir,
            endpoint: endpoint,
            tunEnabled: tunEnabled,
            autoSetDNS: autoSetDNS
        )
    }

    private func resolveControllerEndpoint() async throws -> ControllerEndpointHolder.Endpoint {
        let port = try await resolveControllerPort()
        return .tcp(host: "127.0.0.1", port: port)
    }

    private func resolveControllerPort() async throws -> Int {
        if let env = ProcessInfo.processInfo.environment["MIHOMO_CONTROLLER_PORT"],
           let value = Int(env), isValidPort(value) {
            return value
        }

        var tried = Set<Int>()
        for _ in 0..<30 {
            let candidate = Int.random(in: 39_000...58_999)
            if tried.contains(candidate) { continue }
            tried.insert(candidate)
            if await isPortAvailable(candidate) {
                return candidate
            }
        }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        return 39_000 + (pid % (58_999 - 39_000))
    }

    private func isValidPort(_ port: Int) -> Bool {
        port > 0 && port <= 65_535
    }

    private func isPortAvailable(_ port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else {
                continuation.resume(returning: false)
                return
            }
            defer { close(socketFD) }

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            continuation.resume(returning: result == 0)
        }
    }

    // MARK: - Process lifecycle

    private func spawnCoreProcess(_ prepared: PreparedCore) throws -> Process {
        let proc = Process()
        proc.executableURL = prepared.corePath

        switch prepared.endpoint {
        case .tcp(let host, let port):
            proc.arguments = ["-d", prepared.workDir.path, "-ext-ctl", "\(host):\(port)"]
        case .unix(let socketPath):
            proc.arguments = ["-d", prepared.workDir.path, "-ext-ctl-unix", socketPath]
        }

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        stdoutPipe = stdout
        stderrPipe = stderr

        ensureCoreLogFileHandle()

        startupReady = false
        startupError = nil
        installPipeHandler(stdout.fileHandleForReading)
        installPipeHandler(stderr.fileHandleForReading)

        proc.terminationHandler = { [weak self] _ in
            Task {
                await self?.handleUnexpectedTermination()
            }
        }

        try proc.run()
        return proc
    }

    private func installPipeHandler(_ fileHandle: FileHandle) {
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeCoreOutput(data) }
        }
    }

    private func consumeCoreOutput(_ data: Data) {
        ensureCoreLogFileHandle()
        logFileHandle?.write(data)
        guard let text = String(data: data, encoding: .utf8) else { return }

        if text.contains("configure tun interface: operation not permitted") {
            resolveStartup(with: .failure(ProcessError.startupFailed("tun permission denied")))
            return
        }

        let isControllerError = text.contains("External controller unix listen error")
            || (text.contains("External controller") && text.contains("listen error"))
        if isControllerError {
            resolveStartup(with: .failure(ProcessError.startupFailed("external controller listen error")))
            return
        }

        if text.contains("RESTful API") {
            resolveStartup(with: .success(()))
        }
    }

    private func waitForStartupReady(timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let startupError {
                throw startupError
            }
            if startupReady {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProcessError.startupTimeout
    }

    private func resolveStartup(with result: Result<Void, Error>) {
        switch result {
        case .success:
            startupReady = true
            startupError = nil
        case .failure(let error):
            startupError = error
        }
    }

    private func handleUnexpectedTermination() async {
        swiftLog.warn("[ProcessMgr] mihomo 进程意外终止 coreState=\(coreState)")
        cleanupStreamsAndProcessReferences()
        if coreState == .restarting || coreState == .stopping {
            return
        }
    }

    private func stopRunningProcess() async {
        guard let proc = process else {
            cleanupStreamsAndProcessReferences()
            return
        }

        proc.terminationHandler = nil
        proc.terminate()

        for _ in 0..<20 where proc.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            for _ in 0..<10 where proc.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        cleanupStreamsAndProcessReferences()

        // Wait for BoltDB (cache.db) file lock to be fully released by the OS.
        // Without this, rapid stop/start cycles cause "[CacheFile] can't open
        // cache file: timeout", losing fake-ip mappings and breaking TUN routing.
        try? await Task.sleep(for: .milliseconds(500))
    }

    nonisolated private func flushSystemDNSCache() {
        // Clear stale fake-ip entries from macOS DNS cache before TUN starts.
        // Without this, apps retain fake-ip addresses from previous core instances
        // that the new core can't resolve, causing TUN routing loops and timeouts.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        task.arguments = ["-flushcache"]
        try? task.run()
        task.waitUntilExit()
    }

    private func cleanupStreamsAndProcessReferences() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        startupReady = false
        startupError = nil
        try? logFileHandle?.close()
        logFileHandle = nil
        currentCoreLogDate = ""
    }

    private func ensureCoreLogFileHandle() {
        let today = coreLogDayFormatter.string(from: Date())
        if today == currentCoreLogDate, logFileHandle != nil {
            return
        }

        try? logFileHandle?.close()
        logFileHandle = nil
        currentCoreLogDate = today

        let logPath = PathManager.logDir.appendingPathComponent("core-\(today).log", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: PathManager.logDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logPath.path) {
                FileManager.default.createFile(atPath: logPath.path, contents: nil)
            }
            logFileHandle = try FileHandle(forWritingTo: logPath)
            logFileHandle?.seekToEndOfFile()
        } catch {
            swiftLog.error("Failed to open core log file at \(logPath.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Utils

    private func waitForCoreReady(maxAttempts: Int, retryIntervalMs: Int) async throws {
        for attempt in 0..<maxAttempts {
            do {
                let version = try await api.fetchVersion()
                swiftLog.info("[ProcessMgr] REST API 就绪: version=\(version) (第 \(attempt + 1) 次探测)")
                return
            } catch {
                if attempt == maxAttempts - 1 {
                    swiftLog.warn("[ProcessMgr] REST API 探测耗尽 \(maxAttempts) 次，放弃等待: \(error.localizedDescription)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(retryIntervalMs))
            }
        }
    }

    private func checkProfile(configPath: URL, core: String) throws {
        let task = Process()
        task.executableURL = PathManager.mihomoCorePath(core: core)
        task.arguments = ["-t", "-f", configPath.path, "-d", PathManager.dataDir.appendingPathComponent("test", isDirectory: true).path]

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            throw ProcessError.profileCheckFailed(error.localizedDescription)
        }

        guard task.terminationStatus == 0 else {
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outText = String(data: outData, encoding: .utf8) ?? ""
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let merged = [outText, errText].filter { !$0.isEmpty }.joined(separator: "\n")
            throw ProcessError.profileCheckFailed(merged.isEmpty ? "unknown error" : merged)
        }
    }

    private func cleanupPidFileProcess() async {
        let pidPath = PathManager.dataDir.appendingPathComponent("core.pid", isDirectory: false)
        guard FileManager.default.fileExists(atPath: pidPath.path),
              let text = try? String(contentsOf: pidPath, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return
        }

        _ = kill(pid, SIGINT)
        try? FileManager.default.removeItem(at: pidPath)

        // Wait for old process to fully exit so BoltDB (cache.db) file lock
        // is released. Without this, the new mihomo instance gets
        // "[CacheFile] can't open cache file: timeout", losing fake-ip
        // mappings and store-selected state — breaking TUN routing and
        // causing suboptimal proxy node selection.
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

    private func cleanupSocketFiles() {
        let uid = getuid()
        let legacy = [
            "/tmp/mihomo-party.sock",
            "/tmp/mihomo-party-admin.sock",
            "/tmp/mihomo-party-\(uid).sock"
        ]
        for path in legacy where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }

        if case .unix(let socketPath) = endpointHolder.current,
           FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    // MARK: - Core Watcher (self-update directory monitoring)

    func initCoreWatcher() {
        guard coreWatcherSource == nil else { return }

        // Watch the external runnable sidecar dir (not the read-only bundle),
        // because mihomo's self-update creates/removes `meta-update/` next to
        // the running binary, which now lives under dataDir/sidecar.
        let dirPath = PathManager.mihomoCoreDir.path
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else {
            swiftLog.warn("Core watcher: cannot open \(dirPath) for monitoring")
            return
        }

        coreWatcherFD = fd
        metaUpdateDirExists = FileManager.default.fileExists(
            atPath: PathManager.mihomoCoreDir.appendingPathComponent("meta-update").path
        )

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleCoreDirectoryChange() }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        coreWatcherSource = source
    }

    private func handleCoreDirectoryChange() async {
        let exists = FileManager.default.fileExists(
            atPath: PathManager.mihomoCoreDir.appendingPathComponent("meta-update").path
        )

        if metaUpdateDirExists && !exists {
            metaUpdateDirExists = false
            swiftLog.info("Core watcher: meta-update directory removed, restarting core after delay")

            try? await Task.sleep(for: .seconds(3))

            guard coreState == .idle else { return }

            do {
                await stopCore()
                try await startCore()
            } catch {
                swiftLog.error("Core start failed after self-update: \(error)")
            }
        } else {
            metaUpdateDirExists = exists
        }
    }

    func cleanupCoreWatcher() {
        coreWatcherSource?.cancel()
        coreWatcherSource = nil
        coreWatcherFD = -1
    }
}
