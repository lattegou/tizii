import Foundation
import OrderedCollections

actor MihomoAPIClient {
    struct ProxyOption: Sendable, Equatable {
        let name: String
        let type: String
    }

    struct ProxyGroup: Sendable, Equatable, Identifiable {
        let name: String
        let type: String
        let now: String
        let all: [ProxyOption]
        let testUrl: String?

        var id: String { name }
    }

    struct RuleItem: Sendable, Equatable, Identifiable {
        let id: Int
        let type: String
        let payload: String
        let proxy: String
        let size: Int
    }

    struct TrafficData: Sendable, Equatable {
        let up: Int64
        let down: Int64
    }

    struct ConnectionItem: Sendable, Equatable, Identifiable {
        struct Metadata: Sendable, Equatable {
            let network: String
            let type: String
            let sourceIP: String
            let destinationIP: String
            let sourcePort: String
            let destinationPort: String
            let host: String
        }

        let id: String
        let metadata: Metadata
        let upload: Int64
        let download: Int64
        let uploadSpeed: Int64
        let downloadSpeed: Int64
        let start: String
        let chains: [String]
        let rule: String
        let rulePayload: String
    }

    struct ConnectionsData: Sendable, Equatable {
        let uploadTotal: Int64
        let downloadTotal: Int64
        let connections: [ConnectionItem]
    }

    struct LogEntry: Sendable, Equatable {
        let level: String
        let payload: String
        let time: String?
    }

    enum APIError: LocalizedError {
        case endpointUnavailable
        case unsupportedUnixSocketTransport
        case invalidResponse
        case httpError(Int)
        case requestEncoding

        var errorDescription: String? {
            switch self {
            case .endpointUnavailable:
                "mihomo controller endpoint is unavailable"
            case .unsupportedUnixSocketTransport:
                "unix socket transport is not implemented yet"
            case .invalidResponse:
                "invalid mihomo response"
            case .httpError(let code):
                "mihomo API http error \(code)"
            case .requestEncoding:
                "failed to encode request payload"
            }
        }
    }

    private let endpointHolder: ControllerEndpointHolder
    private let generator: ProfileGenerator
    private let config: ConfigService

    private let urlSession = URLSession(configuration: .ephemeral)
    private var previousConnectionStats: [String: (upload: Int64, download: Int64)] = [:]

    private var trafficTask: Task<Void, Never>?
    private var connectionsTask: Task<Void, Never>?
    private var logsTask: Task<Void, Never>?
    private var streamsStarted = false

    private var trafficContinuation: AsyncStream<TrafficData>.Continuation?
    private var connectionsContinuation: AsyncStream<ConnectionsData>.Continuation?
    private var logsContinuation: AsyncStream<LogEntry>.Continuation?

    lazy var trafficStream: AsyncStream<TrafficData> = {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.trafficContinuation = continuation
        }
    }()

    lazy var connectionsStream: AsyncStream<ConnectionsData> = {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.connectionsContinuation = continuation
        }
    }()

    lazy var logsStream: AsyncStream<LogEntry> = {
        AsyncStream(bufferingPolicy: .bufferingNewest(200)) { continuation in
            self.logsContinuation = continuation
        }
    }()

    init(
        endpointHolder: ControllerEndpointHolder,
        generator: ProfileGenerator,
        config: ConfigService
    ) {
        self.endpointHolder = endpointHolder
        self.generator = generator
        self.config = config
    }

    // MARK: - REST

    func fetchVersion() async throws -> String {
        let root = try await httpGetObject("/version")
        let version = root["version"] as? String ?? "unknown"
        return version
    }

    func patchMihomoConfig(_ patch: YAMLValue) async throws {
        swiftLog.info("[API] PATCH /configs patch=\(patch)")
        let object = try jsonObject(from: patch)
        _ = try await httpRequest(path: "/configs", method: "PATCH", jsonBody: object)
        swiftLog.info("[API] PATCH /configs 成功")
    }

    func fetchRules() async throws -> [RuleItem] {
        let object = try await httpGetObject("/rules")
        guard let rules = object["rules"] as? [[String: Any]] else { return [] }
        return rules.enumerated().compactMap { index, item in
            guard
                let type = item["type"] as? String,
                let payload = item["payload"] as? String,
                let proxy = item["proxy"] as? String
            else {
                return nil
            }
            return RuleItem(
                id: index,
                type: type,
                payload: payload,
                proxy: proxy,
                size: intValue(item["size"])
            )
        }
    }

    func fetchGroups() async throws -> [ProxyGroup] {
        let controlled = try await config.loadControledMihomoConfig()
        let mode = controlled["mode"]?.stringValue ?? "rule"
        swiftLog.info("[API] fetchGroups mode=\(mode)")
        if mode == "direct" { return [] }

        let object = try await httpGetObject("/proxies")
        guard let proxies = object["proxies"] as? [String: [String: Any]] else {
            swiftLog.warn("[API] fetchGroups: /proxies 响应无 proxies 字段")
            return []
        }

        let runtime = await generator.runtimeConfig
        let runtimeGroups = runtime["proxy-groups"]?.arrayValue ?? []
        swiftLog.info("[API] fetchGroups: REST 返回 \(proxies.count) 个代理, runtimeConfig 有 \(runtimeGroups.count) 个 proxy-groups")

        var groups: [ProxyGroup] = []
        for raw in runtimeGroups {
            guard
                let dict = raw.dictionaryValue,
                let name = dict["name"]?.stringValue,
                let item = proxies[name],
                item["hidden"] as? Bool != true
            else {
                continue
            }

            let testUrl = dict["url"]?.stringValue
            if let parsed = buildGroup(from: item, name: name, allMap: proxies, testUrl: testUrl) {
                groups.append(parsed)
            }
        }

        if !groups.contains(where: { $0.name == "GLOBAL" }),
           let global = proxies["GLOBAL"],
           global["hidden"] as? Bool != true,
           let parsed = buildGroup(from: global, name: "GLOBAL", allMap: proxies, testUrl: nil) {
            groups.append(parsed)
        }

        if mode == "global", let index = groups.firstIndex(where: { $0.name == "GLOBAL" }) {
            let global = groups.remove(at: index)
            groups.insert(global, at: 0)
        }

        swiftLog.info("[API] fetchGroups 完成: \(groups.count) 个组")
        return groups
    }

    func changeProxy(group: String, proxy: String) async throws {
        _ = try await httpRequest(path: "/proxies/\(group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group)", method: "PUT", jsonBody: ["name": proxy])
    }

    func proxyDelay(proxy: String, url: String?, timeout: Int?) async throws -> Int? {
        let app = try await config.loadAppConfig()
        let delayUrl = url ?? app["delayTestUrl"]?.stringValue ?? "http://www.gstatic.com/generate_204"
        let delayTimeout = timeout ?? app["delayTestTimeout"]?.intValue ?? 5000
        let path = "/proxies/\(proxy.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proxy)/delay?url=\(delayUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? delayUrl)&timeout=\(delayTimeout)"
        let object = try await httpGetObject(path)
        let delay = intValue(object["delay"])
        return delay > 0 ? delay : nil
    }

    func closeConnection(id: String) async throws {
        _ = try await httpRequest(path: "/connections/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)", method: "DELETE")
    }

    func closeAllConnections() async throws {
        _ = try await httpRequest(path: "/connections", method: "DELETE")
    }

    // MARK: - Streams

    func startStreams() {
        guard !streamsStarted else {
            swiftLog.info("[API] startStreams 跳过: 已启动")
            return
        }
        streamsStarted = true
        previousConnectionStats = [:]

        swiftLog.info("[API] 启动 3 条 WebSocket streams (traffic/connections/logs)")
        trafficTask = Task { await runTrafficLoop() }
        connectionsTask = Task { await runConnectionsLoop() }
        logsTask = Task { await runLogsLoop() }
    }

    func stopStreams() {
        swiftLog.info("[API] 停止 WebSocket streams streamsStarted=\(streamsStarted)")
        streamsStarted = false
        trafficTask?.cancel()
        connectionsTask?.cancel()
        logsTask?.cancel()
        trafficTask = nil
        connectionsTask = nil
        logsTask = nil
        previousConnectionStats = [:]
    }

    private func runTrafficLoop() async {
        var retry = 10
        swiftLog.info("[API][WS] traffic loop 启动")
        while streamsStarted, !Task.isCancelled, retry > 0 {
            do {
                try await consumeTrafficSocket()
                retry = 10
            } catch {
                retry -= 1
                swiftLog.warn("[API][WS] traffic 连接断开, 剩余重试 \(retry): \(error.localizedDescription)")
                if retry > 0 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        swiftLog.info("[API][WS] traffic loop 退出 streamsStarted=\(streamsStarted) retry=\(retry)")
    }

    private func runConnectionsLoop() async {
        var retry = 10
        swiftLog.info("[API][WS] connections loop 启动")
        while streamsStarted, !Task.isCancelled, retry > 0 {
            do {
                try await consumeConnectionsSocket()
                retry = 10
            } catch {
                retry -= 1
                swiftLog.warn("[API][WS] connections 连接断开, 剩余重试 \(retry): \(error.localizedDescription)")
                if retry > 0 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        swiftLog.info("[API][WS] connections loop 退出 streamsStarted=\(streamsStarted) retry=\(retry)")
    }

    private func runLogsLoop() async {
        var retry = 10
        swiftLog.info("[API][WS] logs loop 启动")
        while streamsStarted, !Task.isCancelled, retry > 0 {
            do {
                try await consumeLogsSocket()
                retry = 10
            } catch {
                retry -= 1
                swiftLog.warn("[API][WS] logs 连接断开, 剩余重试 \(retry): \(error.localizedDescription)")
                if retry > 0 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        swiftLog.info("[API][WS] logs loop 退出 streamsStarted=\(streamsStarted) retry=\(retry)")
    }

    private func consumeTrafficSocket() async throws {
        let socket = try makeWebSocket(path: "/traffic")
        defer { socket.cancel(with: .goingAway, reason: nil) }
        socket.resume()

        while streamsStarted, !Task.isCancelled {
            let message = try await receiveMessage(from: socket)
            let data = switch message {
            case .data(let data): data
            case .string(let text): Data(text.utf8)
            @unknown default: Data()
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let up = int64Value(json["up"]),
                let down = int64Value(json["down"])
            else {
                continue
            }
            trafficContinuation?.yield(TrafficData(up: up, down: down))
        }
    }

    private func consumeConnectionsSocket() async throws {
        let socket = try makeWebSocket(path: "/connections")
        defer { socket.cancel(with: .goingAway, reason: nil) }
        socket.resume()

        while streamsStarted, !Task.isCancelled {
            let message = try await receiveMessage(from: socket)
            let data = switch message {
            case .data(let data): data
            case .string(let text): Data(text.utf8)
            @unknown default: Data()
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let parsed = parseConnections(payload)
            connectionsContinuation?.yield(parsed)
        }
    }

    private func consumeLogsSocket() async throws {
        let controlled = try await config.loadControledMihomoConfig()
        let level = controlled["log-level"]?.stringValue ?? "info"
        let socket = try makeWebSocket(path: "/logs?level=\(level)")
        defer { socket.cancel(with: .goingAway, reason: nil) }
        socket.resume()

        while streamsStarted, !Task.isCancelled {
            let message = try await receiveMessage(from: socket)
            let data = switch message {
            case .data(let data): data
            case .string(let text): Data(text.utf8)
            @unknown default: Data()
            }
            guard
                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = payload["payload"] as? String
            else {
                continue
            }
            logsContinuation?.yield(
                LogEntry(
                    level: payload["type"] as? String ?? "info",
                    payload: message,
                    time: payload["time"] as? String
                )
            )
        }
    }

    // MARK: - Parsing helpers

    private func buildGroup(
        from object: [String: Any],
        name: String,
        allMap: [String: [String: Any]],
        testUrl: String?
    ) -> ProxyGroup? {
        guard
            let type = object["type"] as? String,
            let now = object["now"] as? String
        else {
            return nil
        }

        let all = (object["all"] as? [String] ?? []).compactMap { proxyName -> ProxyOption? in
            guard let proxy = allMap[proxyName] else { return nil }
            let type = proxy["type"] as? String ?? "unknown"
            return ProxyOption(name: proxyName, type: type)
        }

        return ProxyGroup(name: name, type: type, now: now, all: all, testUrl: testUrl)
    }

    private func parseConnections(_ payload: [String: Any]) -> ConnectionsData {
        let uploadTotal = int64Value(payload["uploadTotal"]) ?? 0
        let downloadTotal = int64Value(payload["downloadTotal"]) ?? 0
        let list = payload["connections"] as? [[String: Any]] ?? []

        var nextStats: [String: (upload: Int64, download: Int64)] = [:]
        var parsed: [ConnectionItem] = []
        parsed.reserveCapacity(list.count)

        for item in list {
            guard
                let id = item["id"] as? String,
                let upload = int64Value(item["upload"]),
                let download = int64Value(item["download"])
            else {
                continue
            }

            let metadataObject = item["metadata"] as? [String: Any] ?? [:]
            let metadata = ConnectionItem.Metadata(
                network: metadataObject["network"] as? String ?? "",
                type: metadataObject["type"] as? String ?? "",
                sourceIP: metadataObject["sourceIP"] as? String ?? "",
                destinationIP: metadataObject["destinationIP"] as? String ?? "",
                sourcePort: metadataObject["sourcePort"] as? String ?? "",
                destinationPort: metadataObject["destinationPort"] as? String ?? "",
                host: metadataObject["host"] as? String ?? ""
            )

            let previous = previousConnectionStats[id]
            let uploadSpeed = max(upload - (previous?.upload ?? upload), Int64(0))
            let downloadSpeed = max(download - (previous?.download ?? download), Int64(0))

            parsed.append(
                ConnectionItem(
                    id: id,
                    metadata: metadata,
                    upload: upload,
                    download: download,
                    uploadSpeed: uploadSpeed,
                    downloadSpeed: downloadSpeed,
                    start: item["start"] as? String ?? "",
                    chains: item["chains"] as? [String] ?? [],
                    rule: item["rule"] as? String ?? "",
                    rulePayload: item["rulePayload"] as? String ?? ""
                )
            )
            nextStats[id] = (upload: upload, download: download)
        }

        previousConnectionStats = nextStats
        return ConnectionsData(
            uploadTotal: uploadTotal,
            downloadTotal: downloadTotal,
            connections: parsed
        )
    }

    // MARK: - HTTP helpers

    private func httpGetObject(_ path: String) async throws -> [String: Any] {
        let data = try await httpRequest(path: path, method: "GET")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return json
    }

    private func httpRequest(path: String, method: String, jsonBody: Any? = nil) async throws -> Data {
        guard let url = try makeHTTPURL(path: path) else {
            swiftLog.warn("[API] HTTP \(method) \(path) 失败: endpoint 不可用")
            throw APIError.endpointUnavailable
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if let jsonBody {
            guard JSONSerialization.isValidJSONObject(jsonBody) else {
                throw APIError.requestEncoding
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            swiftLog.warn("[API] HTTP \(method) \(path) 响应非 HTTPURLResponse")
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            swiftLog.warn("[API] HTTP \(method) \(path) 返回 \(http.statusCode): \(bodyPreview)")
            throw APIError.httpError(http.statusCode)
        }
        return data
    }

    private func makeHTTPURL(path: String) throws -> URL? {
        guard let endpoint = endpointHolder.current else {
            return nil
        }
        switch endpoint {
        case .tcp(let host, let port):
            return URL(string: "http://\(host):\(port)\(path)")
        case .unix:
            throw APIError.unsupportedUnixSocketTransport
        }
    }

    private func makeWebSocket(path: String) throws -> URLSessionWebSocketTask {
        guard let endpoint = endpointHolder.current else {
            swiftLog.warn("[API][WS] makeWebSocket(\(path)) 失败: endpoint 不可用")
            throw APIError.endpointUnavailable
        }
        switch endpoint {
        case .tcp(let host, let port):
            guard let url = URL(string: "ws://\(host):\(port)\(path)") else {
                throw APIError.invalidResponse
            }
            swiftLog.info("[API][WS] 创建 WebSocket: \(url.absoluteString)")
            return urlSession.webSocketTask(with: url)
        case .unix:
            throw APIError.unsupportedUnixSocketTransport
        }
    }

    private func receiveMessage(from task: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            task.receive { result in
                continuation.resume(with: result)
            }
        }
    }

    private func intValue(_ any: Any?) -> Int {
        if let value = any as? Int { return value }
        if let value = any as? Int64 { return Int(value) }
        if let value = any as? Double { return Int(value) }
        if let value = any as? NSNumber { return value.intValue }
        if let value = any as? String, let parsed = Int(value) { return parsed }
        return 0
    }

    private func int64Value(_ any: Any?) -> Int64? {
        if let value = any as? Int64 { return value }
        if let value = any as? Int { return Int64(value) }
        if let value = any as? Double { return Int64(value) }
        if let value = any as? NSNumber { return value.int64Value }
        if let value = any as? String, let parsed = Int64(value) { return parsed }
        return nil
    }

    private func jsonObject(from value: YAMLValue) throws -> Any {
        switch value {
        case .string(let string):
            return string
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .bool(let bool):
            return bool
        case .array(let array):
            return try array.map(jsonObject)
        case .dictionary(let dict):
            return try dict.reduce(into: [String: Any]()) { partialResult, element in
                partialResult[element.key] = try jsonObject(from: element.value)
            }
        case .null:
            return NSNull()
        }
    }
}
