import Foundation
import Network
import OrderedCollections

actor SystemProxyService {
    enum ProxyError: LocalizedError {
        case invalidService
        case helperRequestFailed(String)
        case pacPortUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidService:
                return "failed to resolve default network service"
            case .helperRequestFailed(let detail):
                return "helper request failed: \(detail)"
            case .pacPortUnavailable:
                return "pac server port unavailable"
            }
        }
    }

    private enum SysProxyMode: String {
        case auto
        case manual
    }

    private let config: ConfigService

    private let helperSocketPath = "/tmp/mihomo-party-helper.sock"
    private let helperPlistPath = "/Library/LaunchDaemons/party.mihomo.helper.plist"
    private let defaultPacScript = """
function FindProxyForURL(url, host) {
  return "PROXY 127.0.0.1:%mixed-port%; SOCKS5 127.0.0.1:%mixed-port%; DIRECT;";
}
"""
    private let defaultBypass = [
        "127.0.0.1",
        "192.168.0.0/16",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "localhost",
        "*.local",
        "*.crashlytics.com",
        "<local>"
    ]
    private let commandEnvironment = [
        "PATH": "/sbin:/usr/sbin:/usr/bin:/bin"
    ]

    private var triggerRetryTask: Task<Void, Never>?
    private var isSettingProxy = false

    private var pacListener: NWListener?
    private var pacPort: Int?
    private var pacResponseBody: String?

    init(config: ConfigService) {
        self.config = config
    }

    deinit {
        triggerRetryTask?.cancel()
        pacListener?.cancel()
    }

    func triggerSysProxy(_ enable: Bool) async throws {
        guard !isSettingProxy else {
            logInfo("[SysProxy] triggerSysProxy(\(enable)) 跳过: 正在设置中")
            return
        }
        isSettingProxy = true
        defer { isSettingProxy = false }

        let online = await SystemSupport.isOnline()
        logInfo("[SysProxy] triggerSysProxy enable=\(enable) online=\(online)")
        if online {
            triggerRetryTask?.cancel()
            triggerRetryTask = nil
            if enable {
                try await disableSysProxy()
                try await enableSysProxy()
            } else {
                try await disableSysProxy()
            }
            logInfo("[SysProxy] triggerSysProxy(\(enable)) 完成")
            return
        }

        logInfo("[SysProxy] 网络离线, 5 秒后重试")
        triggerRetryTask?.cancel()
        triggerRetryTask = Task {
            try? await Task.sleep(for: .seconds(5))
            try? await self.triggerSysProxy(enable)
        }
    }

    func setDNSViaHelper(service: String, dns: String) async throws {
        let body = """
{"service":"\(escapeJSONString(service))","dns":"\(escapeJSONString(dns))"}
"""
        _ = try await helperRequest {
            try await self.unixSocketHTTPRequest(
                method: "POST",
                path: "/dns",
                body: body
            )
        }
    }

    // MARK: - SysProxy

    private func enableSysProxy() async throws {
        try await startPacServer()

        let appConfig = try await config.loadAppConfig()
        let controlled = try await config.loadControledMihomoConfig()

        let sysProxy = appConfig["sysProxy"]?.dictionaryValue ?? OrderedDictionary<String, YAMLValue>()
        let mode = SysProxyMode(rawValue: sysProxy["mode"]?.stringValue ?? "manual") ?? .manual
        let host = sysProxy["host"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyHost = (host?.isEmpty == false ? host! : "127.0.0.1")
        let mixedPort = intValue(from: controlled["mixed-port"]) ?? 7890
        let bypass = stringArray(from: sysProxy["bypass"])
        let bypassDomains = bypass.isEmpty ? defaultBypass : bypass

        logInfo("[SysProxy] enableSysProxy: mode=\(mode.rawValue) host=\(proxyHost) mixedPort=\(mixedPort) pacPort=\(pacPort ?? -1) bypass=\(bypassDomains.count) 条")

        if isHelperAvailable() {
            do {
                if mode == .auto {
                    guard let pacPort else { throw ProxyError.pacPortUnavailable }
                    let body = """
{"url":"http://\(escapeJSONString(proxyHost)):\(pacPort)/pac"}
"""
                    let resp = try await helperRequest {
                        try await self.unixSocketHTTPRequest(
                            method: "POST",
                            path: "/pac",
                            body: body
                        )
                    }
                    logInfo("[SysProxy] helper /pac 成功: status=\(resp.statusCode)")
                } else {
                    let bypassCSV = bypassDomains.joined(separator: ",")
                    let body = """
{"host":"\(escapeJSONString(proxyHost))","port":"\(mixedPort)","bypass":"\(escapeJSONString(bypassCSV))"}
"""
                    let resp = try await helperRequest {
                        try await self.unixSocketHTTPRequest(
                            method: "POST",
                            path: "/global",
                            body: body
                        )
                    }
                    logInfo("[SysProxy] helper /global 成功: status=\(resp.statusCode)")
                }
                return
            } catch {
                logWarn("[SysProxy] Helper request failed, fallback to networksetup: \(error.localizedDescription)")
            }
        } else {
            logInfo("[SysProxy] helper 不可用, 直接使用 networksetup")
        }

        let service = try getDefaultService()
        logInfo("[SysProxy] networksetup 服务: \(service)")
        var argsList: [[String]] = []
        if mode == .auto {
            guard let pacPort else { throw ProxyError.pacPortUnavailable }
            argsList.append(["-setautoproxyurl", service, "http://\(proxyHost):\(pacPort)/pac"])
            argsList.append(["-setautoproxystate", service, "on"])
        } else {
            argsList.append(["-setwebproxy", service, proxyHost, "\(mixedPort)"])
            argsList.append(["-setsecurewebproxy", service, proxyHost, "\(mixedPort)"])
            argsList.append(["-setwebproxystate", service, "on"])
            argsList.append(["-setsecurewebproxystate", service, "on"])
            argsList.append(["-setproxybypassdomains", service] + bypassDomains)
        }
        try networkSetupBatch(argsList)
        logInfo("[SysProxy] networksetup 设置完成")
    }

    private func disableSysProxy() async throws {
        stopPacServer()
        logInfo("[SysProxy] disableSysProxy 开始")

        if isHelperAvailable() {
            do {
                let resp = try await helperRequest {
                    try await self.unixSocketHTTPRequest(method: "GET", path: "/off", body: nil)
                }
                logInfo("[SysProxy] helper /off 成功: status=\(resp.statusCode)")
                return
            } catch {
                logWarn("[SysProxy] Helper disable failed, fallback to networksetup: \(error.localizedDescription)")
            }
        }

        let service = try getDefaultService()
        try networkSetupBatch([
            ["-setwebproxystate", service, "off"],
            ["-setsecurewebproxystate", service, "off"],
            ["-setautoproxystate", service, "off"],
            ["-setsocksfirewallproxystate", service, "off"]
        ])
        logInfo("[SysProxy] disableSysProxy networksetup 完成")
    }

    private func networkSetupBatch(_ argsList: [[String]]) throws {
        do {
            for args in argsList {
                _ = try SystemSupport.runCommand(
                    executable: "/usr/sbin/networksetup",
                    arguments: args,
                    environment: commandEnvironment
                )
            }
        } catch {
            let commands = argsList.map { args in
                "/usr/sbin/networksetup " + args.map(SystemSupport.shellEscapeSingleQuoted).joined(separator: " ")
            }.joined(separator: " && ")
            let escaped = commands.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escaped)\" with administrator privileges"
            _ = try SystemSupport.runCommand(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script],
                environment: commandEnvironment
            )
        }
    }

    // MARK: - Helper recover

    private func isHelperAvailable() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: helperSocketPath) || fm.fileExists(atPath: helperPlistPath)
    }

    private func isSocketFileExists() -> Bool {
        FileManager.default.fileExists(atPath: helperSocketPath)
    }

    private func isHelperRunning() -> Bool {
        do {
            let result = try SystemSupport.runCommand(
                executable: "/usr/bin/pgrep",
                arguments: ["-f", "party.mihomo.helper"],
                environment: commandEnvironment,
                allowFailure: true
            )
            return result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    private func startHelperService() throws {
        let shell = "/bin/launchctl kickstart -k system/party.mihomo.helper"
        let script = "do shell script \"\(shell)\" with administrator privileges"
        _ = try SystemSupport.runCommand(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            environment: commandEnvironment
        )
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func requestSocketRecreation() throws {
        let shell = "/usr/bin/pkill -USR1 -f party.mihomo.helper"
        let script = "do shell script \"\(shell)\" with administrator privileges"
        _ = try SystemSupport.runCommand(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            environment: commandEnvironment
        )
        Thread.sleep(forTimeInterval: 1.0)
    }

    private func helperRequest(
        maxRetries: Int = 2,
        request: @Sendable () async throws -> HTTPResponse
    ) async throws -> HTTPResponse {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                let response = try await request()
                if (200..<300).contains(response.statusCode) {
                    return response
                }
                throw ProxyError.helperRequestFailed("http \(response.statusCode)")
            } catch {
                lastError = error
                guard attempt < maxRetries else { break }

                let message = String(describing: error)
                let shouldRecover = message.contains("ECONNREFUSED")
                    || message.contains("ENOENT")
                    || message.contains("connect failed")
                if !shouldRecover { continue }

                let running = isHelperRunning()
                let socketExists = isSocketFileExists()
                if !running {
                    if FileManager.default.fileExists(atPath: helperPlistPath) {
                        do {
                            try startHelperService()
                            continue
                        } catch {
                            logWarn("start helper service failed: \(error.localizedDescription)")
                        }
                    }
                } else if !socketExists {
                    do {
                        try requestSocketRecreation()
                        continue
                    } catch {
                        logWarn("request socket recreation failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        throw lastError ?? ProxyError.helperRequestFailed("unknown")
    }

    // MARK: - Unix socket HTTP

    private struct HTTPResponse: Sendable {
        let statusCode: Int
        let body: String
    }

    private func unixSocketHTTPRequest(method: String, path: String, body: String?) async throws -> HTTPResponse {
        final class RequestState: @unchecked Sendable {
            var finished = false
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
            let endpoint = NWEndpoint.unix(path: helperSocketPath)
            let connection = NWConnection(to: endpoint, using: .tcp)
            let queue = DispatchQueue(label: "airtiz.helper.\(UUID().uuidString)")
            var received = Data()
            let requestState = RequestState()

            func finish(_ result: Result<HTTPResponse, Error>) {
                guard !requestState.finished else { return }
                requestState.finished = true
                connection.cancel()
                continuation.resume(with: result)
            }

            func receiveLoop() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        finish(.failure(error))
                        return
                    }
                    if let data, !data.isEmpty {
                        received.append(data)
                    }
                    if isComplete {
                        do {
                            let parsed = try self.parseHTTPResponse(received)
                            finish(.success(parsed))
                        } catch {
                            finish(.failure(error))
                        }
                        return
                    }
                    receiveLoop()
                }
            }

            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    var request = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
                    if let body {
                        let bodyData = Data(body.utf8)
                        request += "Content-Type: application/json\r\n"
                        request += "Content-Length: \(bodyData.count)\r\n"
                        request += "\r\n"
                        request += body
                    } else {
                        request += "\r\n"
                    }

                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(error))
                            return
                        }
                        receiveLoop()
                    })
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    if !requestState.finished {
                        finish(.failure(ProxyError.helperRequestFailed("connection cancelled")))
                    }
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    private nonisolated func parseHTTPResponse(_ data: Data) throws -> HTTPResponse {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProxyError.helperRequestFailed("invalid utf8 response")
        }
        let parts = text.components(separatedBy: "\r\n\r\n")
        let headerPart = parts.first ?? text
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let statusLine = headerPart.components(separatedBy: "\r\n").first ?? ""
        let statusCode = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        return HTTPResponse(statusCode: statusCode, body: body)
    }

    // MARK: - PAC server

    private func startPacServer() async throws {
        stopPacServer()

        let appConfig = try await config.loadAppConfig()
        let controlled = try await config.loadControledMihomoConfig()
        let sysProxy = appConfig["sysProxy"]?.dictionaryValue ?? OrderedDictionary<String, YAMLValue>()
        let mode = SysProxyMode(rawValue: sysProxy["mode"]?.stringValue ?? "manual") ?? .manual
        guard mode == .auto else { return }
        let host = sysProxy["host"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let listenHost = (host?.isEmpty == false ? host! : "127.0.0.1")

        let mixedPort = intValue(from: controlled["mixed-port"]) ?? 7890
        var pacScript = sysProxy["pacScript"]?.stringValue ?? defaultPacScript
        pacScript = pacScript.replacingOccurrences(of: "%mixed-port%", with: "\(mixedPort)")

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(listenHost), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue.global(qos: .utility))
            self?.handlePACConnection(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Task { @MainActor in
                    swiftLog.error("PAC listener failed: \(error.localizedDescription)")
                }
            }
        }
        listener.start(queue: DispatchQueue(label: "airtiz.pac.listener"))

        var waitCount = 0
        while listener.port == nil, waitCount < 20 {
            try? await Task.sleep(for: .milliseconds(50))
            waitCount += 1
        }
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw ProxyError.pacPortUnavailable
        }

        listener.service = nil

        pacListener = listener
        pacPort = Int(port)
        pacResponseBody = pacScript
    }

    private nonisolated func handlePACConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] _, _, _, _ in
            Task {
                guard let self else { return }
                let body = await self.pacResponseBody ?? ""
                let response = """
HTTP/1.1 200 OK\r
Content-Type: application/x-ns-proxy-autoconfig\r
Content-Length: \(body.utf8.count)\r
Connection: close\r
\r
\(body)
"""
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func stopPacServer() {
        pacListener?.cancel()
        pacListener = nil
        pacPort = nil
        pacResponseBody = nil
    }

    // MARK: - DNS helpers for M8

    func getDefaultService() throws -> String {
        let device = try getDefaultDevice()
        let result = try SystemSupport.runCommand(
            executable: "/usr/sbin/networksetup",
            arguments: ["-listnetworkserviceorder"],
            environment: commandEnvironment
        )

        let blocks = result.stdout.components(separatedBy: "\n\n")
        guard let block = blocks.first(where: { $0.contains("Device: \(device)") }) else {
            throw ProxyError.invalidService
        }

        for line in block.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("("), let closing = trimmed.firstIndex(of: ")") else { continue }
            let name = trimmed[trimmed.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return name
            }
        }
        throw ProxyError.invalidService
    }

    private func getDefaultDevice() throws -> String {
        let result = try SystemSupport.runCommand(
            executable: "/sbin/route",
            arguments: ["-n", "get", "default"],
            environment: commandEnvironment
        )
        for line in result.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                let device = trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
                if !device.isEmpty {
                    return device
                }
            }
        }
        throw ProxyError.invalidService
    }

    // MARK: - Utils

    private func intValue(from value: YAMLValue?) -> Int? {
        if let intValue = value?.intValue { return intValue }
        if let string = value?.stringValue { return Int(string) }
        return nil
    }

    private func stringArray(from value: YAMLValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func escapeJSONString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private nonisolated func logWarn(_ message: String) {
        SwiftLogger.shared.warn(message)
    }

    private nonisolated func logInfo(_ message: String) {
        SwiftLogger.shared.info(message)
    }
}
