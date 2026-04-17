import Foundation
import Observation
import OrderedCollections
import SwiftUI

@Observable
@MainActor
final class AppService {
    var isConnected = false
    var connectionError: String?
    var coreVersion: String?
    var proxyMode: ProxyMode = .rule
    var isLoading = true
    var isBusy = false
    var isImportingSubscription = false
    var isLoadingSubscriptions = false
    var uploadSpeed: Int64 = 0
    var downloadSpeed: Int64 = 0
    var uploadSpeedHistory: [Int64] = Array(repeating: 0, count: 60)
    var downloadSpeedHistory: [Int64] = Array(repeating: 0, count: 60)
    var totalUpload: Int64 = 0
    var totalDownload: Int64 = 0
    var proxyGroups: [ProxyGroup] = []
    var subscriptions: [SubscriptionItem] = []
    var proxyDelayResults: [String: Int] = [:]
    var isTestingProxies = false
    var rules: [RuleItem] = []
    var isLoadingRules = false
    var activeConnections: [ConnectionItem] = []
    var connectionUploadTotal: Int64 = 0
    var connectionDownloadTotal: Int64 = 0

    var sysProxyEnabled = false
    var tunEnabled = false
    var isTogglingQuickSwitch = false
    var needsSubscriptionSetup = false

    var lastNonDirectMode: ProxyMode

    private var proxyDelayTestToken = UUID()
    private var pollingTask: Task<Void, Never>?
    private var proxyGroupRefreshTask: Task<Void, Never>?
    private var streamConsumptionTask: Task<Void, Never>?

    let container: AppContainer
    private let configService: ConfigService
    private let profileService: ProfileService
    private let profileGenerator: ProfileGenerator
    private let mihomoAPI: MihomoAPIClient
    private let processManager: MihomoProcessManager
    private let systemProxyService: SystemProxyService
    private let permissionsService: PermissionsService
    private let appInitializer: AppInitializer
    private let ssidMonitor: SSIDMonitor
    private let logService: LogService

    init(container: AppContainer) {
        self.container = container
        self.configService = container.configService
        self.profileService = container.profileService
        self.profileGenerator = container.profileGenerator
        self.mihomoAPI = container.mihomoAPI
        self.processManager = container.processManager
        self.systemProxyService = container.systemProxyService
        self.permissionsService = container.permissionsService
        self.appInitializer = container.appInitializer
        self.ssidMonitor = container.ssidMonitor
        self.logService = container.logService

        if let saved = UserDefaults.standard.string(forKey: "lastNonDirectMode"),
           let mode = ProxyMode(rawValue: saved), mode != .direct {
            lastNonDirectMode = mode
        } else {
            lastNonDirectMode = .rule
        }
    }

    convenience init() {
        self.init(container: AppContainer())
    }

    enum ProxyMode: String, CaseIterable, Identifiable {
        case direct, rule, global

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .rule: "规则"
            case .direct: "直连"
            case .global: "全局"
            }
        }

        var icon: String {
            switch self {
            case .rule: "doc.text"
            case .direct: "link"
            case .global: "globe"
            }
        }

        var highlightColor: Color {
            switch self {
            case .rule: Color(red: 0.14, green: 0.67, blue: 0.46)
            case .direct: .gray
            case .global: Color(red: 0.95, green: 0.69, blue: 0.42)
            }
        }

        var trayIcon: String {
            switch self {
            case .rule: "list.bullet.rectangle"
            case .direct: "arrow.right.circle"
            case .global: "globe"
            }
        }

        var description: String {
            switch self {
            case .rule: "按规则分流流量"
            case .direct: "所有流量直接连接"
            case .global: "所有流量走代理"
            }
        }
    }

    struct ProxyGroup: Identifiable, Equatable {
        let name: String
        let type: String
        var now: String
        let all: [String]

        var id: String { name }
    }

    struct RuleItem: Identifiable, Equatable {
        let id: Int
        let type: String
        let payload: String
        let proxy: String
        let size: Int
    }

    struct SubscriptionItem: Identifiable, Equatable {
        struct TrafficInfo: Equatable {
            let upload: Int64?
            let download: Int64?
            let total: Int64?
            let expire: Int64?
        }

        let id: String
        let name: String
        let type: String
        let url: String?
        let isCurrent: Bool
        let extra: TrafficInfo?
    }

    struct ConnectionItem: Identifiable, Equatable {
        struct Metadata: Equatable {
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
        let startDate: Date?
        let chains: [String]
        let rule: String
        let rulePayload: String
    }

    struct LogEntry: Identifiable, Equatable {
        let id: UUID
        let level: String
        let payload: String
        let timeDisplay: String
        let receivedAt: Date
    }

    struct DNSOverrideConfig: Equatable {
        var enable: Bool
        var defaultNameserver: [String]
        var nameserver: [String]
        var proxyServerNameserver: [String]
        var directNameserver: [String]
        var hosts: [String: String]
        var nameserverPolicy: [String: [String]]
    }

    struct SnifferOverrideConfig: Equatable {
        var enable: Bool
        var parsePureIP: Bool
        var forceDNSMapping: Bool
        var overrideDestination: Bool
        var httpPorts: [Int]
        var tlsPorts: [Int]
        var quicPorts: [Int]
        var skipDomain: [String]
        var forceDomain: [String]
        var skipDstAddress: [String]
        var skipSrcAddress: [String]
    }

    static let maxLogEntries = 500

    var logEntries: [LogEntry] = []

    func clearLogs() {
        logEntries = []
    }

    // MARK: - Public API

    func connectToCore() async {
        isLoading = true
        connectionError = nil
        swiftLog.info("[App] connectToCore 开始")

        do {
            let version = try await mihomoAPI.fetchVersion()
            coreVersion = version
            swiftLog.info("[App] mihomo version=\(version)")

            await fetchProxyMode()
            swiftLog.info("[App] 当前代理模式: \(proxyMode.rawValue)")
            await fetchSwitchStates()
            swiftLog.info("[App] 快捷开关: sysProxy=\(sysProxyEnabled) tun=\(tunEnabled)")
            await fetchProxyGroups()
            swiftLog.info("[App] 代理组数: \(proxyGroups.count)")
            await fetchRules()
            swiftLog.info("[App] 规则数: \(rules.count)")
            await fetchSubscriptions()
            isConnected = true
            startStreamConsumption()
            startProxyGroupRefreshTimer()
            await appInitializer.validateAfterCoreReady()
            await startSSIDMonitor()
            swiftLog.info("已连接 mihomo coreVersion=\(coreVersion ?? "unknown")")
        } catch {
            isConnected = false
            coreVersion = nil
            stopProxyGroupRefreshTimer()
            stopStreamConsumption()
            await stopSSIDMonitor()
            connectionError = error.localizedDescription
            swiftLog.error("连接 mihomo 失败: \(error.localizedDescription)")
            AnalyticsService.trackError("connect_to_core", error: error)
        }

        isLoading = false
    }

    func fetchProxyMode() async {
        do {
            let controlled = try await configService.loadControledMihomoConfig(force: true)
            if let mode = controlled["mode"]?.stringValue,
               let parsed = ProxyMode(rawValue: mode) {
                proxyMode = parsed
                if parsed != .direct {
                    lastNonDirectMode = parsed
                    UserDefaults.standard.set(parsed.rawValue, forKey: "lastNonDirectMode")
                }
            }
        } catch {
            connectionError = "获取代理模式失败: \(error.localizedDescription)"
        }
    }

    func fetchRules() async {
        guard !isLoadingRules else { return }
        isLoadingRules = true
        defer { isLoadingRules = false }
        do {
            let apiRules = try await mihomoAPI.fetchRules()
            rules = apiRules.map { item in
                RuleItem(id: item.id, type: item.type, payload: item.payload, proxy: item.proxy, size: item.size)
            }
        } catch {
            rules = []
            connectionError = "获取规则列表失败: \(error.localizedDescription)"
        }
    }

    func closeConnection(id: String) async {
        do {
            try await mihomoAPI.closeConnection(id: id)
        } catch {
            connectionError = "关闭连接失败: \(error.localizedDescription)"
        }
    }

    func closeAllConnections() async {
        do {
            try await mihomoAPI.closeAllConnections()
        } catch {
            connectionError = "关闭全部连接失败: \(error.localizedDescription)"
        }
    }

    private static let builtInProxyNames: Set<String> = ["DIRECT", "REJECT"]

    func fetchProxyGroups() async {
        connectionError = nil
        do {
            let apiGroups = try await mihomoAPI.fetchGroups()
            proxyGroups = apiGroups.map { group in
                var allNames = group.all.map(\.name)
                if group.name == "GLOBAL" {
                    allNames = allNames.filter { !Self.builtInProxyNames.contains($0) }
                }
                return ProxyGroup(
                    name: group.name,
                    type: group.type,
                    now: group.now,
                    all: allNames
                )
            }
            proxyDelayResults = proxyDelayResults.filter { key, _ in
                proxyGroups.contains { $0.all.contains(key) }
            }
        } catch {
            proxyGroups = []
            proxyDelayResults = [:]
            connectionError = "获取节点列表失败: \(error.localizedDescription)"
        }
    }

    func changeProxy(group: String, proxy: String) async {
        guard !isBusy else { return }
        isBusy = true
        connectionError = nil
        defer { isBusy = false }

        do {
            try await mihomoAPI.changeProxy(group: group, proxy: proxy)
            if let index = proxyGroups.firstIndex(where: { $0.name == group }) {
                proxyGroups[index].now = proxy
            }
        } catch {
            connectionError = "切换节点失败: \(error.localizedDescription)"
        }
    }

    func testActiveProxyDelays() async {
        guard let group = activeProxyGroup else { return }
        let token = UUID()
        proxyDelayTestToken = token
        isTestingProxies = true
        connectionError = nil
        proxyDelayResults = [:]

        let api = mihomoAPI
        let proxies = group.all

        let maxConcurrency = 5
        await withTaskGroup(of: (String, Int?).self) { taskGroup in
            for (i, proxy) in proxies.enumerated() {
                if i >= maxConcurrency {
                    if let (name, delay) = await taskGroup.next() {
                        if proxyDelayTestToken != token { return }
                        if let delay { proxyDelayResults[name] = delay }
                    }
                }
                taskGroup.addTask {
                    do {
                        let delay = try await api.proxyDelay(proxy: proxy, url: nil, timeout: nil)
                        return (proxy, delay)
                    } catch {
                        return (proxy, nil)
                    }
                }
            }
            for await (proxy, delay) in taskGroup {
                guard proxyDelayTestToken == token else { return }
                if let delay {
                    proxyDelayResults[proxy] = delay
                }
            }
        }
        if proxyDelayTestToken == token {
            isTestingProxies = false
        }
    }

    func setProxyMode(_ mode: ProxyMode) async {
        guard !isBusy else {
            swiftLog.info("[App] setProxyMode(\(mode.rawValue)) 跳过: isBusy")
            return
        }
        isBusy = true
        connectionError = nil
        let previous = proxyMode
        let previousNode = activeProxyGroup?.now
        proxyMode = mode
        defer { isBusy = false }
        swiftLog.info("[App] setProxyMode \(previous.rawValue) -> \(mode.rawValue)")
        let patch: YAMLValue = .dictionary(OrderedDictionary(uniqueKeysWithValues: [
            ("mode", .string(mode.rawValue))
        ]))
        do {
            swiftLog.info("[App] setProxyMode: patchControledMihomoConfig...")
            try await configService.patchControledMihomoConfig(patch)
            swiftLog.info("[App] setProxyMode: patchMihomoConfig (REST API)...")
            try await mihomoAPI.patchMihomoConfig(patch)
            if mode != .direct {
                lastNonDirectMode = mode
                UserDefaults.standard.set(mode.rawValue, forKey: "lastNonDirectMode")
            }
            swiftLog.info("[App] setProxyMode: fetchProxyGroups...")
            await fetchProxyGroups()
            if let newGroup = activeProxyGroup,
               let previousNode,
               newGroup.now != previousNode,
               newGroup.all.contains(previousNode) {
                swiftLog.info("[App] setProxyMode: 同步节点选择 \(newGroup.name) -> \(previousNode)")
                try await mihomoAPI.changeProxy(group: newGroup.name, proxy: previousNode)
                if let index = proxyGroups.firstIndex(where: { $0.name == newGroup.name }) {
                    proxyGroups[index].now = previousNode
                }
            }
            if mode == .rule {
                await fetchRules()
            }
            swiftLog.info("代理模式切换为 \(mode.rawValue)")
            AnalyticsService.track("proxy_mode_changed", with: ["from": previous.rawValue, "to": mode.rawValue])
        } catch {
            swiftLog.error("切换代理模式失败 \(previous.rawValue)->\(mode.rawValue): \(error.localizedDescription)")
            proxyMode = previous
            connectionError = "切换模式失败: \(error.localizedDescription)"
            AnalyticsService.trackError("set_proxy_mode", error: error)
        }
    }

    func importRemoteSubscription(url: String) async -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isImportingSubscription else { return false }

        isImportingSubscription = true
        connectionError = nil
        defer { isImportingSubscription = false }

        do {
            let draft = ProfileService.ProfileDraft(
                type: "remote",
                url: trimmed
            )
            _ = try await profileService.addProfileItem(draft)
            await fetchProxyMode()
            await fetchSwitchStates()
            await fetchProxyGroups()
            await fetchRules()
            await fetchSubscriptions()
            AnalyticsService.track("subscription_added", with: ["type": "remote"])
            return true
        } catch {
            connectionError = "导入订阅失败: \(error.localizedDescription)"
            AnalyticsService.trackError("import_remote_subscription", error: error)
            return false
        }
    }

    func importYamlConfig(name: String, content: String) async -> Bool {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }
        guard !isImportingSubscription else { return false }

        isImportingSubscription = true
        connectionError = nil
        defer { isImportingSubscription = false }

        do {
            let draft = ProfileService.ProfileDraft(
                name: trimmedName.isEmpty ? "手动配置 \(Date().formatted(.dateTime.month().day().hour().minute()))" : trimmedName,
                type: "local",
                file: trimmedContent
            )
            _ = try await profileService.addProfileItem(draft)
            await fetchProxyMode()
            await fetchSwitchStates()
            await fetchProxyGroups()
            await fetchRules()
            await fetchSubscriptions()
            AnalyticsService.track("subscription_added", with: ["type": "local"])
            return true
        } catch {
            connectionError = "导入配置失败: \(error.localizedDescription)"
            AnalyticsService.trackError("import_yaml_config", error: error)
            return false
        }
    }

    func fetchSubscriptions() async {
        guard !isLoadingSubscriptions else { return }
        isLoadingSubscriptions = true
        defer { isLoadingSubscriptions = false }

        do {
            let config = try await profileService.getProfileConfig(force: true)
            subscriptions = config.items.map { item in
                SubscriptionItem(
                    id: item.id,
                    name: item.name.isEmpty ? "未命名订阅" : item.name,
                    type: item.type,
                    url: item.url,
                    isCurrent: config.current == item.id,
                    extra: item.extra.map { extra in
                        SubscriptionItem.TrafficInfo(
                            upload: extra["upload"].map(Int64.init),
                            download: extra["download"].map(Int64.init),
                            total: extra["total"].map(Int64.init),
                            expire: extra["expire"].map(Int64.init)
                        )
                    }
                )
            }
        } catch {
            subscriptions = []
            connectionError = "获取订阅列表失败: \(error.localizedDescription)"
        }
    }

    func changeCurrentSubscription(id: String) async {
        guard !isBusy else { return }
        isBusy = true
        connectionError = nil
        defer { isBusy = false }

        do {
            try await profileService.changeCurrentProfile(to: id)
            await fetchProxyMode()
            await fetchSwitchStates()
            await fetchProxyGroups()
            await fetchRules()
            await fetchSubscriptions()
        } catch {
            connectionError = "切换订阅失败: \(error.localizedDescription)"
            AnalyticsService.trackError("change_subscription", error: error)
        }
    }

    func removeSubscription(id: String) async {
        guard !isBusy else { return }
        isBusy = true
        connectionError = nil
        defer { isBusy = false }

        do {
            try await profileService.removeProfileItem(id: id)
            await fetchSubscriptions()
        } catch {
            connectionError = "删除订阅失败: \(error.localizedDescription)"
            AnalyticsService.trackError("remove_subscription", error: error)
        }
    }

    func refreshRemoteSubscription(id: String) async {
        guard !isBusy else { return }
        isBusy = true
        connectionError = nil
        defer { isBusy = false }

        do {
            try await profileService.refreshRemoteProfile(id: id)
            swiftLog.info("[App] refreshRemoteSubscription 成功 id=\(id)")
            await fetchProxyGroups()
            await fetchRules()
            await fetchSubscriptions()
        } catch {
            swiftLog.error("[App] refreshRemoteSubscription 失败 id=\(id) error=\(error)")
            connectionError = "刷新订阅失败: \(error.localizedDescription)"
            AnalyticsService.trackError("refresh_subscription", error: error)
        }
    }

    func loadSubscriptionContent(id: String) async throws -> String {
        try await profileService.getProfileString(id: id)
    }

    func saveSubscriptionContent(id: String, content: String) async throws {
        try await profileService.setProfileString(id: id, content: content)
    }

    // MARK: - Quick Switch (SysProxy + TUN)

    func fetchSwitchStates() async {
        do {
            let app = try await configService.loadAppConfig(force: true)
            sysProxyEnabled = app["sysProxy"]?["enable"]?.boolValue ?? false
        } catch {}
        do {
            let controlled = try await configService.loadControledMihomoConfig(force: true)
            tunEnabled = controlled["tun"]?["enable"]?.boolValue ?? false
        } catch {}
    }

    var quickSwitchEnabled: Bool {
        sysProxyEnabled && tunEnabled
    }

    func toggleQuickSwitch(_ enable: Bool) async {
        guard !isTogglingQuickSwitch else { return }
        isTogglingQuickSwitch = true
        connectionError = nil
        defer { isTogglingQuickSwitch = false }

        swiftLog.info("[App] toggleQuickSwitch enable=\(enable) (prev sysProxy=\(sysProxyEnabled) tun=\(tunEnabled))")
        let prevSysProxy = sysProxyEnabled
        let prevTun = tunEnabled
        sysProxyEnabled = enable
        tunEnabled = enable

        do {
            if enable {
                let hasPermissions = (try? await permissionsService.checkMihomoCorePermissions()) ?? false
                if !hasPermissions {
                    try await permissionsService.requestTunPermissions()
                }
                do {
                    try await permissionsService.setPublicDNS()
                } catch {
                    swiftLog.warn("设置公共 DNS 失败（继续执行）: \(error.localizedDescription)")
                }
            }

            try await configService.patchAppConfig(
                .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                    ("sysProxy", .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                        ("enable", .bool(enable))
                    ])))
                ]))
            )
            try await systemProxyService.triggerSysProxy(enable)

            if enable {
                try await configService.patchControledMihomoConfig(
                    .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                        ("tun", .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                            ("enable", .bool(true))
                        ]))),
                        ("dns", .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                            ("enable", .bool(true))
                        ])))
                    ]))
                )
            } else {
                do {
                    try await permissionsService.recoverDNS()
                } catch {
                    swiftLog.warn("恢复 DNS 失败（继续执行）: \(error.localizedDescription)")
                }
                try await configService.patchControledMihomoConfig(
                    .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                        ("tun", .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                            ("enable", .bool(false))
                        ])))
                    ]))
                )
            }
            try await processManager.restartCore()
            AnalyticsService.track("proxy_toggled", with: ["enabled": enable])

        } catch {
            swiftLog.error("快捷开关切换失败 enable=\(enable): \(error.localizedDescription)")
            sysProxyEnabled = prevSysProxy
            tunEnabled = prevTun
            connectionError = "切换失败: \(error.localizedDescription)"
            AnalyticsService.trackError("toggle_quick_switch", error: error)
        }
    }

    // MARK: - DNS Override

    func fetchDNSOverrideConfig() async throws -> DNSOverrideConfig {
        let controlled = try await configService.loadControledMihomoConfig(force: true)
        let dns = controlled["dns"]
        let hostsNode = controlled["hosts"]?.dictionaryValue ?? OrderedDictionary<String, YAMLValue>()
        let policyNode = dns?["nameserver-policy"]?.dictionaryValue ?? OrderedDictionary<String, YAMLValue>()

        var hosts: [String: String] = [:]
        for (key, value) in hostsNode {
            if let text = value.stringValue {
                hosts[key] = text
            }
        }

        var policy: [String: [String]] = [:]
        for (domainPattern, rawValue) in policyNode {
            if let single = rawValue.stringValue {
                policy[domainPattern] = [single]
            } else if let list = rawValue.arrayValue {
                let values = list.compactMap(\.stringValue)
                if !values.isEmpty {
                    policy[domainPattern] = values
                }
            }
        }

        return DNSOverrideConfig(
            enable: dns?["enable"]?.boolValue ?? true,
            defaultNameserver: dns?["default-nameserver"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            nameserver: dns?["nameserver"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            proxyServerNameserver: dns?["proxy-server-nameserver"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            directNameserver: dns?["direct-nameserver"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            hosts: hosts,
            nameserverPolicy: policy
        )
    }

    func applyDNSOverrideConfig(_ config: DNSOverrideConfig) async throws {
        var policyPayload = OrderedDictionary<String, YAMLValue>()
        for (domainPattern, values) in config.nameserverPolicy {
            let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if trimmed.isEmpty { continue }
            policyPayload[domainPattern] = trimmed.count == 1
                ? .string(trimmed[0])
                : .array(trimmed.map(YAMLValue.string))
        }

        var hosts = OrderedDictionary<String, YAMLValue>()
        for (domain, ip) in config.hosts {
            hosts[domain] = .string(ip)
        }

        let patch: YAMLValue = .dictionary(OrderedDictionary(uniqueKeysWithValues: [
            ("hosts", .dictionary(hosts)),
            ("dns", .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                ("enable", .bool(config.enable)),
                ("default-nameserver", .array(config.defaultNameserver.map(YAMLValue.string))),
                ("nameserver", .array(config.nameserver.map(YAMLValue.string))),
                ("proxy-server-nameserver", .array(config.proxyServerNameserver.map(YAMLValue.string))),
                ("direct-nameserver", .array(config.directNameserver.map(YAMLValue.string))),
                ("nameserver-policy", .dictionary(policyPayload))
            ])))
        ]))

        try await configService.patchControledMihomoConfig(patch)
        try await processManager.restartCore()
    }

    // MARK: - Sniffer Override

    func fetchSnifferOverrideConfig() async throws -> (config: SnifferOverrideConfig, controlSniff: Bool) {
        let appConfig = try await configService.loadAppConfig(force: true)
        let controlled = try await configService.loadControledMihomoConfig(force: true)

        let controlSniff = appConfig["controlSniff"]?.boolValue ?? true
        let sniffer = controlled["sniffer"]
        let sniff = sniffer?["sniff"]
        let http = sniff?["HTTP"]
        let tls = sniff?["TLS"]
        let quic = sniff?["QUIC"]

        let httpPorts = Self.yamlIntList(http?["ports"])
        let tlsPorts = Self.yamlIntList(tls?["ports"])
        let skipDomain = Self.yamlStringList(sniffer?["skip-domain"])
        let skipDstAddress = Self.yamlStringList(sniffer?["skip-dst-address"])

        let config = SnifferOverrideConfig(
            enable: sniffer?["enable"]?.boolValue ?? true,
            parsePureIP: sniffer?["parse-pure-ip"]?.boolValue ?? true,
            forceDNSMapping: sniffer?["force-dns-mapping"]?.boolValue ?? true,
            overrideDestination: sniffer?["override-destination"]?.boolValue ?? false,
            httpPorts: httpPorts.isEmpty ? [80, 443] : httpPorts,
            tlsPorts: tlsPorts.isEmpty ? [443] : tlsPorts,
            quicPorts: Self.yamlIntList(quic?["ports"]),
            skipDomain: skipDomain.isEmpty
                ? ["+.push.apple.com"]
                : skipDomain,
            forceDomain: Self.yamlStringList(sniffer?["force-domain"]),
            skipDstAddress: skipDstAddress.isEmpty
                ? [
                    "91.105.192.0/23",
                    "91.108.4.0/22",
                    "91.108.8.0/21",
                    "91.108.16.0/21",
                    "91.108.56.0/22",
                    "95.161.64.0/20",
                    "149.154.160.0/20",
                    "185.76.151.0/24",
                    "2001:67c:4e8::/48",
                    "2001:b28:f23c::/47",
                    "2001:b28:f23f::/48",
                    "2a0a:f280:203::/48"
                ]
                : skipDstAddress,
            skipSrcAddress: Self.yamlStringList(sniffer?["skip-src-address"])
        )

        return (config, controlSniff)
    }

    func applySnifferOverrideConfig(_ config: SnifferOverrideConfig, controlSniff: Bool) async throws {
        let patch: YAMLValue = .dictionary(OrderedDictionary(uniqueKeysWithValues: [
            ("sniffer", .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                ("enable", .bool(config.enable)),
                ("parse-pure-ip", .bool(config.parsePureIP)),
                ("force-dns-mapping", .bool(config.forceDNSMapping)),
                ("override-destination", .bool(config.overrideDestination)),
                ("sniff", .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                    ("HTTP", .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                        ("ports", .array(config.httpPorts.map { YAMLValue.int($0) })),
                        ("override-destination", .bool(config.overrideDestination))
                    ]))),
                    ("TLS", .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                        ("ports", .array(config.tlsPorts.map { YAMLValue.int($0) }))
                    ]))),
                    ("QUIC", .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                        ("ports", .array(config.quicPorts.map { YAMLValue.int($0) }))
                    ])))
                ]))),
                ("skip-domain", .array(config.skipDomain.map(YAMLValue.string))),
                ("force-domain", .array(config.forceDomain.map(YAMLValue.string))),
                ("skip-dst-address", .array(config.skipDstAddress.map(YAMLValue.string))),
                ("skip-src-address", .array(config.skipSrcAddress.map(YAMLValue.string)))
            ])))
        ]))

        try await configService.patchControledMihomoConfig(patch)
        if controlSniff {
            try await mihomoAPI.patchMihomoConfig(patch)
            try await processManager.restartCore()
        }
    }

    var activeProxyGroup: ProxyGroup? {
        if proxyMode == .global {
            return proxyGroups.first(where: { $0.name == "GLOBAL" }) ?? proxyGroups.first
        }
        return proxyGroups.first
    }

    // MARK: - Log Export

    func exportRecentServiceLogsArchive(days: Int = 7) async throws -> URL {
        let exported = try await logService.exportServiceLogs(days: days)
        try FileManager.default.createDirectory(at: PathManager.logDir, withIntermediateDirectories: true)
        let archiveURL = PathManager.logDir.appendingPathComponent(exported.filename, isDirectory: false)
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
        try exported.data.write(to: archiveURL)
        return archiveURL
    }

    // MARK: - Periodic Proxy Group Refresh

    private static let proxyGroupRefreshInterval: Duration = .seconds(12 * 60 * 60)

    func startProxyGroupRefreshTimer() {
        guard proxyGroupRefreshTask == nil else { return }
        swiftLog.info("启动节点组定时刷新（间隔 12 小时）")
        proxyGroupRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.proxyGroupRefreshInterval)
                guard !Task.isCancelled, isConnected else { continue }
                guard proxyMode == .rule || proxyMode == .global else {
                    swiftLog.info("定时刷新跳过（当前模式: \(proxyMode.rawValue)，非规则/全局）")
                    continue
                }
                swiftLog.info("定时刷新节点组（当前模式: \(proxyMode.rawValue)）")
                await fetchProxyGroups()
            }
            proxyGroupRefreshTask = nil
        }
    }

    func stopProxyGroupRefreshTimer() {
        guard proxyGroupRefreshTask != nil else { return }
        swiftLog.info("停止节点组定时刷新")
        proxyGroupRefreshTask?.cancel()
        proxyGroupRefreshTask = nil
    }

    // MARK: - Connection Polling (Startup)

    func startConnectionPolling() {
        guard pollingTask == nil else { return }
        swiftLog.info("[App] startConnectionPolling 开始")
        pollingTask = Task {
            guard !Task.isCancelled else {
                pollingTask = nil
                return
            }

            do {
                swiftLog.info("[App] 执行 initBasic...")
                try await appInitializer.initBasic()
                swiftLog.info("[App] 执行 initRuntime...")
                await appInitializer.initRuntime()
                swiftLog.info("[App] 初始化完成")
            } catch {
                swiftLog.warn("启动初始化失败: \(error.localizedDescription)")
            }

            do {
                swiftLog.info("[App] 启动 mihomo 核心...")
                try await processManager.startCore()
                await processManager.initCoreWatcher()
                swiftLog.info("[App] mihomo 核心已启动, 开始连接...")
                await connectToCore()
            } catch {
                swiftLog.error("启动 mihomo 核心失败: \(error.localizedDescription)")
                connectionError = "启动核心失败: \(error.localizedDescription)"
                AnalyticsService.trackError("start_core", error: error)
            }

            if !isConnected {
                isLoading = false
                await stopSSIDMonitor()
                if connectionError == nil || connectionError?.isEmpty == true {
                    connectionError = "核心启动失败"
                }
                swiftLog.error("[App] 启动完成但未连接: \(connectionError ?? "unknown")")
            } else {
                swiftLog.info("[App] 启动流程全部完成, 已连接")
            }
            pollingTask = nil
        }
    }

    func stopConnectionPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        Task { await stopSSIDMonitor() }
    }

    func terminateBackend() {
        swiftLog.infoSync("[Terminate] 开始终止服务")
        stopStreamConsumption()
        stopConnectionPolling()
        stopProxyGroupRefreshTimer()

        TerminationCleanup.perform()

        swiftLog.infoSync("[Terminate] terminateBackend 返回")
    }

    // MARK: - SSID Monitor

    private func startSSIDMonitor() async {
        await ssidMonitor.setModeSwitchHandler { [weak self] mode in
            guard let self, let targetMode = ProxyMode(rawValue: mode) else { return }
            if self.proxyMode == targetMode { return }
            await self.setProxyMode(targetMode)
        }
        await ssidMonitor.start()
    }

    private func stopSSIDMonitor() async {
        await ssidMonitor.stop()
    }

    // MARK: - Stream Consumption

    private func startStreamConsumption() {
        guard streamConsumptionTask == nil else { return }
        swiftLog.info("开始消费 mihomo 实时数据流")
        streamConsumptionTask = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.consumeTraffic() }
                group.addTask { await self.consumeConnections() }
                group.addTask { await self.consumeLogs() }
            }
        }
    }

    private func stopStreamConsumption() {
        streamConsumptionTask?.cancel()
        streamConsumptionTask = nil
        uploadSpeed = 0
        downloadSpeed = 0
    }

    private func consumeTraffic() async {
        swiftLog.info("[App] consumeTraffic 开始等待数据...")
        let stream = await mihomoAPI.trafficStream
        var firstMessage = true
        for await data in stream {
            guard !Task.isCancelled else { break }
            if firstMessage {
                swiftLog.info("[App] consumeTraffic 收到首条数据 up=\(data.up) down=\(data.down)")
                firstMessage = false
            }
            uploadSpeed = data.up
            downloadSpeed = data.down
            totalUpload += data.up
            totalDownload += data.down
            uploadSpeedHistory.append(data.up)
            if uploadSpeedHistory.count > 60 { uploadSpeedHistory.removeFirst() }
            downloadSpeedHistory.append(data.down)
            if downloadSpeedHistory.count > 60 { downloadSpeedHistory.removeFirst() }
        }
    }

    private func consumeConnections() async {
        swiftLog.info("[App] consumeConnections 开始等待数据...")
        let stream = await mihomoAPI.connectionsStream
        var firstMessage = true
        for await data in stream {
            guard !Task.isCancelled else { break }
            if firstMessage {
                swiftLog.info("[App] consumeConnections 收到首条数据: \(data.connections.count) 个连接")
                firstMessage = false
            }
            connectionUploadTotal = data.uploadTotal
            connectionDownloadTotal = data.downloadTotal
            activeConnections = data.connections.map { item in
                ConnectionItem(
                    id: item.id,
                    metadata: ConnectionItem.Metadata(
                        network: item.metadata.network,
                        type: item.metadata.type,
                        sourceIP: item.metadata.sourceIP,
                        destinationIP: item.metadata.destinationIP,
                        sourcePort: item.metadata.sourcePort,
                        destinationPort: item.metadata.destinationPort,
                        host: item.metadata.host
                    ),
                    upload: item.upload,
                    download: item.download,
                    uploadSpeed: item.uploadSpeed,
                    downloadSpeed: item.downloadSpeed,
                    start: item.start,
                    startDate: Self.parseConnectionDate(item.start),
                    chains: item.chains,
                    rule: item.rule,
                    rulePayload: item.rulePayload
                )
            }
        }
    }

    private func consumeLogs() async {
        swiftLog.info("[App] consumeLogs 开始等待数据...")
        let stream = await mihomoAPI.logsStream
        var firstMessage = true
        for await entry in stream {
            guard !Task.isCancelled else { break }
            if firstMessage {
                swiftLog.info("[App] consumeLogs 收到首条日志: [\(entry.level)] \(entry.payload.prefix(80))")
                firstMessage = false
            }
            let now = Date()
            let logEntry = LogEntry(
                id: UUID(),
                level: entry.level,
                payload: entry.payload,
                timeDisplay: Self.logDisplayFormatter.string(from: now),
                receivedAt: now
            )
            logEntries.append(logEntry)
            if logEntries.count > Self.maxLogEntries {
                logEntries.removeFirst()
            }
        }
    }

    // MARK: - Helpers

    private static let logDisplayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func yamlStringList(_ value: YAMLValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private static func yamlIntList(_ value: YAMLValue?) -> [Int] {
        value?.arrayValue?.compactMap(\.intValue) ?? []
    }

    static func formatSpeed(_ bytesPerSecond: Int64) -> String {
        if bytesPerSecond < 1024 {
            return "0 KB/s"
        }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytesPerSecond) / 1024
        for unit in units {
            if value < 1024 {
                return String(format: "%.1f \(unit)/s", value)
            }
            value /= 1024
        }
        return String(format: "%.1f PB/s", value)
    }

    static func formatSpeedCompact(_ bytesPerSecond: Int64) -> String {
        if bytesPerSecond < 1024 {
            return "0K"
        }
        let units = ["K", "M", "G", "T"]
        var value = Double(bytesPerSecond) / 1024
        for unit in units {
            if value < 1024 {
                let fmt = value >= 100 ? "%.0f\(unit)" : "%.1f\(unit)"
                return String(format: fmt, value)
            }
            value /= 1024
        }
        let fmt = value >= 100 ? "%.0fP" : "%.1fP"
        return String(format: fmt, value)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(max(bytes, 0)) B"
        }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(max(bytes, 0)) / 1024
        for unit in units {
            if value < 1024 {
                let fmt = value >= 100 ? "%.0f \(unit)" : "%.1f \(unit)"
                return String(format: fmt, value)
            }
            value /= 1024
        }
        let fmt = value >= 100 ? "%.0f PB" : "%.1f PB"
        return String(format: fmt, value)
    }

    private static let connectionDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseConnectionDate(_ value: String) -> Date? {
        if let date = connectionDateFormatter.date(from: value) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }
}
