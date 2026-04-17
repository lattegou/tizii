import Foundation
import CFNetwork
import OrderedCollections

actor ProfileService {
    struct ProfileItem: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var type: String
        var url: String?
        var interval: Int?
        var overrideIDs: [String]?
        var useProxy: Bool?
        var allowFixedInterval: Bool?
        var autoUpdate: Bool?
        var authToken: String?
        var updated: Int64?
        var updateTimeout: Int?
        var home: String?
        var extra: [String: Int]?
        var file: String?
    }

    struct ProfileDraft: Sendable {
        var id: String?
        var name: String?
        var type: String?
        var url: String?
        var interval: Int?
        var overrideIDs: [String]?
        var useProxy: Bool?
        var allowFixedInterval: Bool?
        var autoUpdate: Bool?
        var authToken: String?
        var updateTimeout: Int?
        var file: String?
    }

    struct ProfileConfig: Sendable, Equatable {
        var items: [ProfileItem]
        var current: String?
    }

    enum ProfileError: LocalizedError {
        case profileNotFound
        case emptyURL
        case invalidProfileYAML
        case profileMissingNodes
        case subscriptionReturnsHTML
        case requestFailed(Int)
        case requestFailedWithMessage(Int, String)

        var errorDescription: String? {
            switch self {
            case .profileNotFound:
                return "Profile not found"
            case .emptyURL:
                return "Empty URL"
            case .invalidProfileYAML:
                return "Subscription failed: Profile is not a valid YAML"
            case .profileMissingNodes:
                return "Subscription failed: Profile missing proxies or providers"
            case .subscriptionReturnsHTML:
                return "Profile contains HTML instead of YAML"
            case .requestFailed(let code):
                return "Subscription failed: Request status code \(code)"
            case .requestFailedWithMessage(let code, let message):
                return "[\(code)] \(message)"
            }
        }
    }

    private let config: ConfigService
    private var restartCore: @Sendable () async throws -> Void
    private var reloadCurrentProfile: @Sendable () async throws -> Void

    private var profileConfigCache: ProfileConfig?
    private var changeProfileQueue: Task<Void, Never> = Task {}
    private var autoUpdateTasks: [String: Task<Void, Never>] = [:]

    init(
        config: ConfigService,
        restartCore: @escaping @Sendable () async throws -> Void = {},
        reloadCurrentProfile: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.config = config
        self.restartCore = restartCore
        self.reloadCurrentProfile = reloadCurrentProfile
    }

    func setCallbacks(
        restartCore: @escaping @Sendable () async throws -> Void,
        reloadCurrentProfile: @escaping @Sendable () async throws -> Void
    ) {
        self.restartCore = restartCore
        self.reloadCurrentProfile = reloadCurrentProfile
    }

    deinit {
        for task in autoUpdateTasks.values {
            task.cancel()
        }
    }

    func getProfileConfig(force: Bool = false) async throws -> ProfileConfig {
        if !force, let cached = profileConfigCache {
            return cached
        }
        try PathManager.ensureBaseDirectories()

        let fallback = ProfileConfig(items: [], current: nil)
        let loaded = try loadOrInitializeProfileConfig(fallback: fallback)
        profileConfigCache = loaded
        return loaded
    }

    func setProfileConfig(_ profileConfig: ProfileConfig) async throws {
        try await writeProfileConfig(profileConfig)
        profileConfigCache = profileConfig
        refreshAutoUpdaters(with: profileConfig)
    }

    func updateProfileConfig(
        _ updater: @Sendable (ProfileConfig) async throws -> ProfileConfig
    ) async throws -> ProfileConfig {
        let current = try await getProfileConfig(force: true)
        let next = try await updater(current)
        try await setProfileConfig(next)
        return next
    }

    func getProfileItem(id: String?) async throws -> ProfileItem? {
        guard let id, !id.isEmpty, id != "default" else {
            return ProfileItem(id: "default", name: "Empty Profile", type: "local")
        }
        return try await getProfileConfig().items.first(where: { $0.id == id })
    }

    func addProfileItem(_ draft: ProfileDraft) async throws -> ProfileItem {
        let newItem = try await createProfile(draft)
        let shouldChangeCurrent = try await getProfileConfig(force: true).current == nil
        _ = try await updateProfileConfig { config in
            var next = config
            if let index = next.items.firstIndex(where: { $0.id == newItem.id }) {
                next.items[index] = newItem
            } else {
                next.items.append(newItem)
            }
            return next
        }
        registerAutoUpdaterIfNeeded(for: newItem)
        if shouldChangeCurrent {
            try await changeCurrentProfile(to: newItem.id)
        }
        return newItem
    }

    func updateProfileItem(_ item: ProfileItem) async throws {
        _ = try await updateProfileConfig { config in
            var next = config
            guard let index = next.items.firstIndex(where: { $0.id == item.id }) else {
                throw ProfileError.profileNotFound
            }
            next.items[index] = item
            return next
        }
        registerAutoUpdaterIfNeeded(for: item)
    }

    func removeProfileItem(id: String) async throws {
        let shouldRestart = try await getProfileConfig(force: true).current == id
        _ = try await updateProfileConfig { config in
            var next = config
            next.items.removeAll(where: { $0.id == id })
            if next.current == id {
                next.current = next.items.first?.id
            }
            return next
        }

        autoUpdateTasks[id]?.cancel()
        autoUpdateTasks[id] = nil

        let fileURL = PathManager.profilePath(id: id)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        let workDir = PathManager.mihomoProfileWorkDir(id: id)
        if FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }
        if shouldRestart {
            try await restartCore()
        }
    }

    func changeCurrentProfile(to id: String) async throws {
        let previousQueue = changeProfileQueue
        let task = Task { [previousQueue] in
            await previousQueue.value

            let previousId = try await self.getProfileConfig(force: true).current
            guard previousId != id else { return }

            _ = try await self.updateProfileConfig { config in
                var next = config
                next.current = id
                return next
            }
            do {
                try await self.restartCore()
            } catch {
                _ = try await self.updateProfileConfig { config in
                    var next = config
                    next.current = previousId
                    return next
                }
                throw error
            }
        }

        changeProfileQueue = Task {
            _ = try? await task.value
        }
        try await task.value
    }

    func getProfileString(id: String?) async throws -> String {
        let targetId = (id?.isEmpty == false ? id! : "default")
        let path = PathManager.profilePath(id: targetId)
        if FileManager.default.fileExists(atPath: path.path) {
            return try String(contentsOf: path, encoding: .utf8)
        }
        return """
proxies: []
proxy-groups: []
rules: []
"""
    }

    func getProfileYAML(id: String?) async throws -> YAMLValue {
        let raw = try await getProfileString(id: id)
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .dictionary([:])
        }
        return try YAMLValue(yamlString: raw)
    }

    func setProfileString(id: String, content: String) async throws {
        try PathManager.ensureBaseDirectories()
        try Data(content.utf8).write(to: PathManager.profilePath(id: id), options: .atomic)
        if try await getProfileConfig(force: true).current == id {
            try await reloadCurrentProfile()
        }
    }

    func startAutoUpdate() async throws {
        let cfg = try await getProfileConfig(force: true)
        refreshAutoUpdaters(with: cfg)
    }

    func stopAutoUpdate() {
        for task in autoUpdateTasks.values {
            task.cancel()
        }
        autoUpdateTasks.removeAll()
    }

    func refreshRemoteProfile(id: String) async throws {
        guard var item = try await getProfileItem(id: id) else {
            throw ProfileError.profileNotFound
        }
        guard item.type == "remote" else { return }

        let maskedToken = item.authToken.map { t in t.count > 8 ? "\(t.prefix(4))...\(t.suffix(4))" : "***" } ?? "<nil>"
        swiftLog.info("[Profile] refreshRemoteProfile id=\(id) url=\(item.url ?? "<nil>") authToken=\(maskedToken) useProxy=\(item.useProxy ?? false) timeout=\(item.updateTimeout ?? 5)")

        let fetch = try await fetchRemoteProfile(
            urlString: item.url ?? "",
            authToken: item.authToken,
            useProxy: item.useProxy ?? false,
            perItemTimeoutSeconds: item.updateTimeout ?? 5
        )

        item.updated = Int64(Date().timeIntervalSince1970 * 1000)
        if let userInfo = fetch.subscriptionUserInfo {
            item.extra = userInfo
        }
        try await setProfileString(id: item.id, content: fetch.content)
        try await updateProfileItem(item)
    }

    // MARK: - Internal

    private func createProfile(_ draft: ProfileDraft) async throws -> ProfileItem {
        let id = draft.id ?? String(Int(Date().timeIntervalSince1970 * 1000), radix: 16)
        var item = ProfileItem(
            id: id,
            name: draft.name ?? ((draft.type ?? "local") == "remote" ? "Remote File" : "Local File"),
            type: draft.type ?? "local",
            url: draft.url,
            interval: draft.interval ?? 0,
            overrideIDs: draft.overrideIDs ?? [],
            useProxy: draft.useProxy ?? false,
            allowFixedInterval: draft.allowFixedInterval ?? false,
            autoUpdate: draft.autoUpdate ?? false,
            authToken: draft.authToken,
            updated: Int64(Date().timeIntervalSince1970 * 1000),
            updateTimeout: draft.updateTimeout ?? 5
        )

        if item.type == "local" {
            try await setProfileString(id: id, content: draft.file ?? "")
            return item
        }

        guard let urlString = draft.url, !urlString.isEmpty else {
            throw ProfileError.emptyURL
        }

        swiftLog.info("[Profile] createProfile 开始拉取远程配置, url=\(urlString), 当前name=\"\(item.name)\"")
        let fetched = try await fetchRemoteProfile(
            urlString: urlString,
            authToken: draft.authToken,
            useProxy: item.useProxy ?? false,
            perItemTimeoutSeconds: item.updateTimeout ?? 5
        )
        swiftLog.info("[Profile] createProfile 拉取完成, fetched.filename=\(fetched.filename ?? "<nil>")")
        if let fetchedName = fetched.filename, item.name == "Remote File" {
            swiftLog.info("[Profile] createProfile 用 fetched.filename 替换名称: \"\(item.name)\" -> \"\(fetchedName)\"")
            item.name = fetchedName
        } else {
            swiftLog.info("[Profile] createProfile 未替换名称, item.name=\"\(item.name)\", fetched.filename=\(fetched.filename ?? "<nil>")")
        }
        if let home = fetched.home {
            item.home = home
        }
        if let intervalInHours = fetched.updateIntervalHours, !(draft.allowFixedInterval ?? false) {
            item.interval = intervalInHours * 60
        }
        if let extra = fetched.subscriptionUserInfo {
            item.extra = extra
        }
        try await setProfileString(id: id, content: fetched.content)
        return item
    }

    private func loadOrInitializeProfileConfig(fallback: ProfileConfig) throws -> ProfileConfig {
        let path = PathManager.profileConfigPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            try writeProfileConfigSync(fallback)
            return fallback
        }
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try writeProfileConfigSync(fallback)
            return fallback
        }
        do {
            let value = try YAMLValue(yamlString: text)
            return normalizeProfileConfig(value)
        } catch {
            try writeProfileConfigSync(fallback)
            return fallback
        }
    }

    private func writeProfileConfigSync(_ config: ProfileConfig) throws {
        let yaml = try profileConfigToYAML(config).toYAMLString()
        try Data(yaml.utf8).write(to: PathManager.profileConfigPath, options: .atomic)
    }

    private func writeProfileConfig(_ config: ProfileConfig) async throws {
        try writeProfileConfigSync(config)
    }

    private func normalizeProfileConfig(_ yaml: YAMLValue) -> ProfileConfig {
        guard let dict = yaml.dictionaryValue else {
            return ProfileConfig(items: [], current: nil)
        }
        let current = dict["current"]?.stringValue
        let items = (dict["items"]?.arrayValue ?? []).compactMap { value -> ProfileItem? in
            guard let obj = value.dictionaryValue else { return nil }
            guard let id = obj["id"]?.stringValue else { return nil }
            return ProfileItem(
                id: id,
                name: obj["name"]?.stringValue ?? "Unnamed Profile",
                type: obj["type"]?.stringValue ?? "local",
                url: obj["url"]?.stringValue,
                interval: intValue(obj["interval"]),
                overrideIDs: stringArray(obj["override"]),
                useProxy: obj["useProxy"]?.boolValue,
                allowFixedInterval: obj["allowFixedInterval"]?.boolValue,
                autoUpdate: obj["autoUpdate"]?.boolValue,
                authToken: obj["authToken"]?.stringValue,
                updated: int64Value(obj["updated"]),
                updateTimeout: intValue(obj["updateTimeout"]),
                home: obj["home"]?.stringValue,
                extra: intDictionary(obj["extra"]),
                file: obj["file"]?.stringValue
            )
        }
        return ProfileConfig(items: items, current: current)
    }

    private func profileConfigToYAML(_ config: ProfileConfig) -> YAMLValue {
        var root = OrderedDictionary<String, YAMLValue>()
        root["items"] = .array(config.items.map(profileItemToYAML))
        if let current = config.current {
            root["current"] = .string(current)
        }
        return .dictionary(root)
    }

    private func profileItemToYAML(_ item: ProfileItem) -> YAMLValue {
        var dict = OrderedDictionary<String, YAMLValue>()
        dict["id"] = .string(item.id)
        dict["name"] = .string(item.name)
        dict["type"] = .string(item.type)
        if let value = item.url { dict["url"] = .string(value) }
        if let value = item.interval { dict["interval"] = .int(value) }
        if let value = item.overrideIDs { dict["override"] = .array(value.map(YAMLValue.string)) }
        if let value = item.useProxy { dict["useProxy"] = .bool(value) }
        if let value = item.allowFixedInterval { dict["allowFixedInterval"] = .bool(value) }
        if let value = item.autoUpdate { dict["autoUpdate"] = .bool(value) }
        if let value = item.authToken { dict["authToken"] = .string(value) }
        if let value = item.updated { dict["updated"] = .int(Int(value)) }
        if let value = item.updateTimeout { dict["updateTimeout"] = .int(value) }
        if let value = item.home { dict["home"] = .string(value) }
        if let value = item.extra {
            var extra = OrderedDictionary<String, YAMLValue>()
            for (key, intValue) in value {
                extra[key] = .int(intValue)
            }
            dict["extra"] = .dictionary(extra)
        }
        if let value = item.file { dict["file"] = .string(value) }
        return .dictionary(dict)
    }

    private func refreshAutoUpdaters(with config: ProfileConfig) {
        let activeIds = Set(config.items.map(\.id))
        for (id, task) in autoUpdateTasks where !activeIds.contains(id) {
            task.cancel()
            autoUpdateTasks[id] = nil
        }
        for item in config.items {
            registerAutoUpdaterIfNeeded(for: item)
        }
    }

    private func registerAutoUpdaterIfNeeded(for item: ProfileItem) {
        autoUpdateTasks[item.id]?.cancel()
        autoUpdateTasks[item.id] = nil

        guard item.type == "remote", item.autoUpdate == true else { return }
        guard let minutes = item.interval, minutes > 0 else { return }

        let id = item.id
        autoUpdateTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    try await self?.refreshRemoteProfile(id: id)
                } catch {
                    // Keep loop alive; next tick retries.
                }
            }
        }
    }

    private struct RemoteFetchResult {
        var content: String
        var filename: String?
        var home: String?
        var updateIntervalHours: Int?
        var subscriptionUserInfo: [String: Int]?
    }

    private func fetchRemoteProfile(
        urlString: String,
        authToken: String?,
        useProxy: Bool,
        perItemTimeoutSeconds: Int
    ) async throws -> RemoteFetchResult {
        let appConfig = try await config.loadAppConfig()
        let controlled = try await config.loadControledMihomoConfig()
        let mixedPort = intValue(controlled["mixed-port"]) ?? 7890
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let configUA = appConfig["userAgent"]?.stringValue
        let defaultUA = "mihomo.party/v\(appVersion) (clash.meta)"
        let userAgent = configUA ?? defaultUA
        let fallbackTimeoutMs = intValue(appConfig["subscriptionTimeout"]) ?? 30_000

        swiftLog.info("[Profile] fetchRemoteProfile 开始: url=\(urlString) useProxy=\(useProxy) timeout=\(perItemTimeoutSeconds)s")
        swiftLog.info("[Profile] fetchRemoteProfile UA=\(userAgent) (configUA=\(configUA ?? "<nil>"))")

        guard let parsedURL = URL(string: urlString) else {
            throw ProfileError.emptyURL
        }

        let tryFetch: @Sendable (Bool, Int) async throws -> (String, [String: String]) = { useProxyFlag, timeoutMs in
            var request = URLRequest(url: parsedURL)
            request.httpMethod = "GET"
            request.timeoutInterval = TimeInterval(timeoutMs) / 1000
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let authToken, !authToken.isEmpty {
                request.setValue(authToken, forHTTPHeaderField: "Authorization")
            }

            swiftLog.info("[Profile] tryFetch proxy=\(useProxyFlag) timeout=\(timeoutMs)ms")

            let session: URLSession
            if useProxyFlag {
                let cfg = URLSessionConfiguration.ephemeral
                cfg.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: 1,
                    kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                    kCFNetworkProxiesHTTPPort as String: mixedPort,
                    kCFNetworkProxiesHTTPSEnable as String: 1,
                    kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                    kCFNetworkProxiesHTTPSPort as String: mixedPort
                ]
                session = URLSession(configuration: cfg)
            } else {
                session = URLSession.shared
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            let allHeaders = http.allHeaderFields.reduce(into: [String: String]()) { partial, item in
                partial[String(describing: item.key).lowercased()] = String(describing: item.value)
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(decoding: data, as: UTF8.self)
                let bodyPreview = String(body.prefix(500))
                swiftLog.error("[Profile] tryFetch 失败 status=\(http.statusCode) proxy=\(useProxyFlag)")
                swiftLog.error("[Profile] tryFetch 响应体前500字: \(bodyPreview)")
                for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
                    swiftLog.error("[Profile] tryFetch 响应头 \(key): \(value)")
                }
                if let jsonData = body.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let message = json["message"] as? String, !message.isEmpty {
                    throw ProfileError.requestFailedWithMessage(http.statusCode, message)
                }
                throw ProfileError.requestFailed(http.statusCode)
            }

            let content = String(decoding: data, as: UTF8.self)
            return (content, allHeaders)
        }

        let primaryTimeoutMs = max(1, perItemTimeoutSeconds) * 1000

        let fetched: (String, [String: String])
        if useProxy {
            fetched = try await tryFetch(true, primaryTimeoutMs)
        } else {
            do {
                fetched = try await tryFetch(false, primaryTimeoutMs)
            } catch {
                swiftLog.warn("[Profile] 直连请求失败: \(error.localizedDescription), 尝试代理")
                fetched = try await tryFetch(true, fallbackTimeoutMs)
            }
        }

        let content = fetched.0.trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = fetched.1

        swiftLog.info("[Profile] fetchRemoteProfile url=\(urlString)")
        swiftLog.info("[Profile] 响应头数量: \(headers.count)")
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            swiftLog.info("[Profile]   header[\(key)] = \(value)")
        }

        if content.hasPrefix("<!DOCTYPE") || content.hasPrefix("<html") || content.hasPrefix("<HTML") {
            throw ProfileError.subscriptionReturnsHTML
        }

        let parsed = try YAMLValue(yamlString: content)
        guard let parsedDict = parsed.dictionaryValue else {
            throw ProfileError.invalidProfileYAML
        }
        let hasProxies = parsedDict.index(forKey: "proxies") != nil
        let hasProviders = parsedDict.index(forKey: "proxy-providers") != nil
        if !hasProxies, !hasProviders {
            throw ProfileError.profileMissingNodes
        }

        let contentDisposition = headers["content-disposition"]
        swiftLog.info("[Profile] content-disposition 原始值: \(contentDisposition ?? "<nil>")")

        let parsedFilename = contentDisposition.flatMap(parseFilename)
        swiftLog.info("[Profile] parseFilename 结果: \(parsedFilename ?? "<nil>")")

        return RemoteFetchResult(
            content: content,
            filename: parsedFilename,
            home: headers["profile-web-page-url"],
            updateIntervalHours: headers["profile-update-interval"].flatMap(Int.init),
            subscriptionUserInfo: headers["subscription-userinfo"].map(parseSubscriptionUserInfo)
        )
    }

    private func parseFilename(_ raw: String) -> String {
        swiftLog.info("[Profile] parseFilename 输入: \"\(raw)\"")

        if let range = raw.range(of: "filename*="),
           let utfPart = raw[range.upperBound...].split(separator: "''", maxSplits: 1).last {
            let result = String(utfPart).removingPercentEncoding ?? String(utfPart)
            swiftLog.info("[Profile] parseFilename 匹配 filename*=, 结果: \"\(result)\"")
            return result
        }
        swiftLog.info("[Profile] parseFilename 未匹配 filename*=")

        if let range = raw.range(of: "filename=") {
            let afterEquals = String(raw[range.upperBound...])
            swiftLog.info("[Profile] parseFilename 匹配 filename=, 等号后原始值: \"\(afterEquals)\"")
            let value = afterEquals.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            swiftLog.info("[Profile] parseFilename 去引号后: \"\(value)\"")
            if !value.isEmpty {
                return value
            }
        } else {
            swiftLog.info("[Profile] parseFilename 也未匹配 filename=")
        }

        swiftLog.info("[Profile] parseFilename 兜底返回 Remote File")
        return "Remote File"
    }

    private func parseSubscriptionUserInfo(_ raw: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, let value = Int(pair[1]) {
                result[pair[0]] = value
            }
        }
        return result
    }

    private func intValue(_ value: YAMLValue?) -> Int? {
        if let int = value?.intValue { return int }
        if let text = value?.stringValue, let int = Int(text) { return int }
        return nil
    }

    private func int64Value(_ value: YAMLValue?) -> Int64? {
        if let int = value?.intValue { return Int64(int) }
        if let text = value?.stringValue, let int = Int64(text) { return int }
        return nil
    }

    private func stringArray(_ value: YAMLValue?) -> [String]? {
        guard let array = value?.arrayValue else { return nil }
        return array.compactMap(\.stringValue)
    }

    private func intDictionary(_ value: YAMLValue?) -> [String: Int]? {
        guard let dict = value?.dictionaryValue else { return nil }
        var result: [String: Int] = [:]
        for (key, item) in dict {
            if let int = item.intValue {
                result[key] = int
            } else if let text = item.stringValue, let int = Int(text) {
                result[key] = int
            }
        }
        return result.isEmpty ? nil : result
    }
}
