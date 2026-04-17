import SwiftUI

struct ContentView: View {
    @Bindable var backend: AppService
    let updaterViewModel: CheckForUpdatesViewModel
    var authService: AuthService
    @State var showSettings = false
    // showConnectionSheet removed — no longer need manual backend config
    @State var isHoveringGear = false
    @State var showAccountPopover = false
    @State var isHoveringAccount = false
    @State var isHoveringRenew = false
    @State var isHoveringUpgrade = false
    @State var isHoveringMembershipPlan = false
    @State var subscriptionURL = ""
    @State var selectedSubscription: AppService.SubscriptionItem?
    @State var subscriptionContent = ""
    @State var isLoadingSubscriptionContent = false
    @State var isSavingSubscriptionContent = false
    @State var isEditingSubscription = false
    @State var editedSubscriptionContent = ""
    @State var showSubscriptionViewer = false
    @State var showImportResultAlert = false
    @State var importResultTitle = ""
    @State var importResultMessage = ""
    @State var selectedTab: SidebarTab = .mode
    @State var nodeFilter = ""
    @State var expandedRuleGroups: Set<String> = []
    @State var hoveredTab: SidebarTab?
    @State var hoveredRuleGroup: String?
    @State var isSubscriptionsExpanded = false
    @State var isAddSubscriptionBlinking = false
    @State var isHoveringSubscriptions = false
    @State var showImportSubscriptionSheet = false
    @State var showYamlInputSheet = false
    @State var showDeleteSubscriptionAlert = false
    @State var subscriptionToDelete: AppService.SubscriptionItem?
    @State var yamlConfigName = ""
    @State var yamlConfigContent = ""
    @State var launchAtLogin = true
    @State var showMenuBarIcon = true
    @State var systemNotifications = true
    @State var developerMode = true
    @State var httpPort = "7890"
    @State var socks5Port = "7891"
    @State var connectionFilter = ""
    @State var connectionSortBy: ConnectionSortKey = .download
    @State var connectionSortDirection: SortDirection = .desc
    @State var hoveredConnectionID: String?
    @State var logSearchText = ""
    @State var logLevelFilter: LogLevelFilter = .all
    @State var logAutoScroll = true
    @State var isExportingNodeLogs = false
    @State var isSendingFeedback = false
    @State var showFeedbackAlert = false
    @State var feedbackLogPath = ""
    @State var dnsLoaded = false
    @State var dnsLoading = false
    @State var dnsSaving = false
    @State var dnsEnable = true
    @State var dnsDefaultNameserverText = ""
    @State var dnsNameserverText = ""
    @State var dnsProxyNameserverText = ""
    @State var dnsDirectNameserverText = ""
    @State var dnsHostsText = ""
    @State var dnsPolicyText = ""
    @State var dnsErrorMessage: String?
    @State var dnsSuccessMessage: String?
    @State var dnsSavedSignature = ""
    @State var snifferLoaded = false
    @State var snifferLoading = false
    @State var snifferSaving = false
    @State var snifferControlEnabled = true
    @State var snifferEnable = true
    @State var snifferParsePureIP = true
    @State var snifferForceDNSMapping = true
    @State var snifferOverrideDestination = false
    @State var snifferHTTPPortsText = "80,443"
    @State var snifferTLSPortsText = "443"
    @State var snifferQUICPortsText = ""
    @State var snifferSkipDomainText = ""
    @State var snifferForceDomainText = ""
    @State var snifferSkipDstAddressText = ""
    @State var snifferSkipSrcAddressText = ""
    @State var snifferErrorMessage: String?
    @State var snifferSuccessMessage: String?
    @State var snifferSavedSignature = ""

    @State var toastMessage: String?
    @State var toastVisible = false

    // Login form (local input state)
    @State var loginEmail = ""
    @State var loginCode = ""
    @State var isCodeSent = false
    @State var isSendingCode = false
    @State var codeCooldown = 0
    @State var loginError: String?

    enum SidebarTab: CaseIterable {
        case mode, nodes, connections, logs, dns, sniffing

        var title: String {
            switch self {
            case .mode: "模式切换"
            case .nodes: "节点管理"
            case .connections: "实时连接"
            case .logs: "运行日志"
            case .dns: "DNS覆写"
            case .sniffing: "嗅探覆写"
            }
        }

        var icon: String {
            switch self {
            case .mode: "waveform.path.ecg"
            case .nodes: "point.3.connected.trianglepath.dotted"
            case .connections: "wifi"
            case .logs: "doc.text.magnifyingglass"
            case .dns: "server.rack"
            case .sniffing: "magnifyingglass.circle"
            }
        }

        var isDeveloper: Bool {
            switch self {
            case .connections, .logs, .dns, .sniffing: true
            default: false
            }
        }
    }

    enum ConnectionSortKey: String, CaseIterable {
        case upload
        case download
        case uploadSpeed
        case downloadSpeed
    }

    enum SortDirection {
        case asc
        case desc

        mutating func toggle() {
            self = self == .asc ? .desc : .asc
        }
    }

    enum LogLevelFilter: String, CaseIterable {
        case all
        case debug
        case info
        case warn
        case error

        var label: String {
            switch self {
            case .all: return "全部"
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }

        func matches(level: String) -> Bool {
            let normalized = level.lowercased() == "warning" ? "warn" : level.lowercased()
            if self == .all { return true }
            return normalized == rawValue
        }
    }

    var canImportSubscription: Bool {
        !subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !backend.isImportingSubscription
    }

    var canImportYamlConfig: Bool {
        !yamlConfigContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !backend.isImportingSubscription
    }

    var body: some View {
        VStack(spacing: 0) {
            if backend.isConnected {
                proxyModeView
            } else {
                connectingView
            }

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .ignoresSafeArea()
        .frame(minWidth: 560, idealWidth: 900, minHeight: 640, idealHeight: 640)
        .sheet(isPresented: $showSubscriptionViewer) {
            subscriptionViewerSheet
        }
        .sheet(isPresented: $showImportSubscriptionSheet) {
            importSubscriptionSheet
        }
        .sheet(isPresented: $showYamlInputSheet) {
            yamlInputSheet
        }
        .alert(importResultTitle, isPresented: $showImportResultAlert) {
            Button("确定", role: .cancel) {
                swiftLog.ui("tap importResult.confirm title=\(importResultTitle)")
            }
        } message: {
            Text(importResultMessage)
        }
        .alert("反馈问题", isPresented: $showFeedbackAlert) {
            Button("复制邮箱地址") {
                swiftLog.ui("tap feedback.copyEmail")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("lattegou@gmail.com", forType: .string)
            }
            Button("在 Finder 中显示日志") {
                swiftLog.ui("tap feedback.revealLogs")
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: feedbackLogPath)]
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("反馈邮箱：lattegou@gmail.com\n\n日志文件：\(feedbackLogPath)\n\n如果碰到Bug，你可将日志压缩包作为附件发送至上述邮箱，并描述您遇到的问题。如果是功能优化等诉求，可不添加日志。")
        }
        .onChange(of: backend.isConnected) { _, isConnected in
            if isConnected && backend.subscriptions.isEmpty {
                selectedTab = .nodes
            }
            if !isConnected {
                showSettings = false
                backend.startConnectionPolling()
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .nodes {
                let empty = backend.subscriptions.isEmpty
                withAnimation(.easeInOut(duration: 0.25)) {
                    isSubscriptionsExpanded = empty
                }
                isAddSubscriptionBlinking = empty
                if (backend.proxyMode == .rule || backend.proxyMode == .global),
                   !backend.isTestingProxies {
                    Task { await backend.testActiveProxyDelays() }
                }
            } else {
                isAddSubscriptionBlinking = false
            }
        }
        .onChange(of: backend.subscriptions.count) { old, new in
            if old == 0 && new > 0 {
                isAddSubscriptionBlinking = false
            }
            if new == 0 && selectedTab == .nodes {
                isAddSubscriptionBlinking = true
                withAnimation(.easeInOut(duration: 0.25)) {
                    isSubscriptionsExpanded = true
                }
            }
        }
        .onChange(of: developerMode) { _, enabled in
            if !enabled && selectedTab.isDeveloper {
                selectedTab = .mode
            }
        }
        .onChange(of: backend.needsSubscriptionSetup) { _, needs in
            if needs {
                backend.needsSubscriptionSetup = false
                promptSubscriptionSetup()
            }
        }
    }

    var connectingView: some View {
        VStack(spacing: 20) {
            if backend.isLoading {
                ProgressView()
                    .controlSize(.large)
                Text("正在启动核心服务…")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                disconnectedView
                Button("重新连接") {
                    swiftLog.ui("tap connection.retry")
                    backend.startConnectionPolling()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    func importSubscription() {
        guard canImportSubscription else { return }
        let url = subscriptionURL
        swiftLog.ui("tap importSubscription.submit")
        Task {
            let imported = await backend.importRemoteSubscription(url: url)
            if imported {
                subscriptionURL = ""
                showImportSubscriptionSheet = false
                showImportResult(title: "导入成功", message: "订阅已导入并刷新列表")
            } else {
                showImportResult(
                    title: "导入失败",
                    message: backend.connectionError ?? "请检查订阅链接或连接状态"
                )
            }
        }
    }

    func importYamlConfig() {
        guard canImportYamlConfig else { return }
        let name = yamlConfigName
        let content = yamlConfigContent
        swiftLog.ui("tap importYamlConfig.submit name=\(name)")
        Task {
            let imported = await backend.importYamlConfig(name: name, content: content)
            if imported {
                yamlConfigName = ""
                yamlConfigContent = ""
                showYamlInputSheet = false
                showImportResult(title: "导入成功", message: "YAML 配置已导入并刷新列表")
            } else {
                showImportResult(
                    title: "导入失败",
                    message: backend.connectionError ?? "请检查配置内容或连接状态"
                )
            }
        }
    }

    func showImportResult(title: String, message: String) {
        importResultTitle = title
        importResultMessage = message
        showImportResultAlert = true
    }
}

#Preview {
    ContentView(backend: AppService(), updaterViewModel: CheckForUpdatesViewModel(), authService: AuthService())
}
