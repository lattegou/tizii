import SwiftUI
import AppKit

struct TrayView: View {
    var backend: AppService
    @Environment(\.openWindow) private var openWindow
    

    private func openMainWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = NSApp.windows.first(where: { $0.title == "AirTiz" }) {
            existing.deminiaturize(nil)
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        openWindow(id: "main")

        DispatchQueue.main.async {
            guard let created = NSApp.windows.first(where: { $0.title == "AirTiz" }) else { return }
            created.deminiaturize(nil)
            created.makeKeyAndOrderFront(nil)
            created.orderFrontRegardless()
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            if backend.isConnected {
                modeSection
                proxySection
            } else {
                disconnectedSection
            }

            // Divider()
            footer
        }
        .frame(width: 320)
        .onAppear {
            if !backend.isConnected && !backend.isLoading {
                backend.startConnectionPolling()
            }
        }
    }

    // MARK: - Header

    // private var header: some View {
    //     HStack(spacing: 6) {
    //         Circle()
    //             .fill(backend.isConnected ? .green : .red)
    //             .frame(width: 7, height: 7)
    //         Text(backend.isConnected ? "已连接" : "未连接")
    //             .font(.caption)
    //             .foregroundStyle(.secondary)

    //         if let version = backend.coreVersion {
    //             Text("Mihomo \(version)")
    //                 .font(.caption2)
    //                 .foregroundStyle(.tertiary)
    //                 .padding(.horizontal, 4)
    //                 .padding(.vertical, 1)
    //                 .background(.quaternary.opacity(0.5), in: Capsule())
    //         }
    //         Spacer()
    //     }
    //     .padding(.horizontal, 12)
    //     .padding(.vertical, 8)
    // }

    // MARK: - Mode Section

    private var masterSwitchOn: Bool { backend.sysProxyEnabled || backend.tunEnabled }

    private var modeSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text(masterSwitchOn ? backend.proxyMode.description : "系统代理和虚拟网卡已关闭")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if backend.isTogglingQuickSwitch {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(
                        get: { masterSwitchOn },
                        set: { enabled in
                            if enabled && backend.subscriptions.isEmpty {
                                swiftLog.ui("tap tray.toggle blocked: no subscriptions")
                                backend.needsSubscriptionSetup = true
                                openMainWindow()
                                return
                            }
                            swiftLog.ui("tap tray.toggle masterSwitch=\(enabled)")
                            Task {
                                await backend.toggleQuickSwitch(enabled)
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)

            if masterSwitchOn {
                HStack(spacing: 6) {
                    modePickerButton(.direct)
                    modePickerButton(.rule)
                    modePickerButton(.global)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if masterSwitchOn, let error = backend.connectionError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

        }
        .animation(.easeOut(duration: 0.2), value: backend.proxyMode)
    }

    private func modePickerButton(_ mode: AppService.ProxyMode) -> some View {
        let isActive = backend.proxyMode == mode
        let activeForeground = mode.trayActiveForegroundColor
        let activeBackground = mode.trayActiveBackgroundColor
        let activeBorder = mode.trayActiveBorderColor

        return Button {
            guard !isActive, !backend.isBusy, !backend.isTogglingQuickSwitch else { return }
            let wasDirectMode = backend.proxyMode == .direct
            swiftLog.ui("tap tray.setProxyMode=\(mode.rawValue)")
            Task {
                await backend.setProxyMode(mode)
                if wasDirectMode && mode != .direct {
                    await backend.testActiveProxyDelays()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.icon)
                    .font(.caption2)
                Text(mode.displayName)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? activeForeground : .primary)
            .background(isActive ? activeBackground : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isActive ? activeBorder : Color.secondary.opacity(0.2),
                        lineWidth: isActive ? 1 : 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(backend.isBusy || backend.isTogglingQuickSwitch)
        .opacity((backend.isBusy || backend.isTogglingQuickSwitch) && !isActive ? 0.5 : 1)
    }

    // MARK: - Proxy Section

    private var proxySection: some View {
        Group {
            if masterSwitchOn, backend.proxyMode != .direct, let group = backend.activeProxyGroup {
                VStack(spacing: 8) {
                    Divider()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("当前节点")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                swiftLog.ui("tap tray.testProxyDelays")
                                Task {
                                    await backend.testActiveProxyDelays()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("测速")
                                        .font(.caption2)
                                    if backend.isTestingProxies {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "speedometer")
                                            .font(.caption)
                                    }
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        ScrollViewReader { scrollProxy in
                            let proxies = sortedProxies(group)
                            let rowCount = max(1, Int(ceil(Double(proxies.count) / 2.0)))
                            let rowHeight: CGFloat = 26
                            let gridSpacing: CGFloat = 6
                            let contentHeight = CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * gridSpacing + 2
                            let listHeight = min(contentHeight, 150)

                            ScrollView {
                                LazyVGrid(
                                    columns: [
                                        GridItem(.flexible(), spacing: 6),
                                        GridItem(.flexible(), spacing: 6)
                                    ],
                                    spacing: 6
                                ) {
                                    ForEach(proxies, id: \.self) { proxy in
                                        proxyNodeButton(group: group.name, proxy: proxy, current: group.now)
                                            .id(proxy)
                                    }
                                }
                                .padding(1)
                            }
                            .frame(height: listHeight)
                            .onAppear {
                                scrollToCurrentProxy(group.now, using: scrollProxy)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func sortedProxies(_ group: AppService.ProxyGroup) -> [String] {
        guard !backend.isTestingProxies, !backend.proxyDelayResults.isEmpty else {
            return group.all
        }
        return group.all.sorted { lhs, rhs in
            let l = backend.proxyDelayResults[lhs] ?? Int.max
            let r = backend.proxyDelayResults[rhs] ?? Int.max
            if l == r {
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            return l < r
        }
    }

    private func scrollToCurrentProxy(_ current: String, using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(current, anchor: .center)
            }
        }
    }

    private func proxyNodeButton(group: String, proxy: String, current: String) -> some View {
        let isActive = current == proxy
        let delay = backend.proxyDelayResults[proxy]
        return Button {
            guard !isActive, !backend.isBusy else { return }
            Task {
                swiftLog.ui("tap tray.selectProxy group=\(group) proxy=\(proxy)")
                await backend.changeProxy(group: group, proxy: proxy)
                await backend.fetchProxyGroups()
            }
        } label: {
            HStack(spacing: 5) {
                Text(proxy)
                    .font(.caption2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                let tested = !backend.proxyDelayResults.isEmpty && !backend.isTestingProxies
                Text(delayText(delay, tested: tested))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(delayColor(delay, tested: tested))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.09) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15),
                        lineWidth: isActive ? 1 : 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(backend.isBusy)
        .opacity(backend.isBusy && !isActive ? 0.6 : 1)
    }

    private func delayText(_ delay: Int?, tested: Bool) -> String {
        if let delay { return "\(delay)ms" }
        return tested ? "未响应" : ""
    }

    private func delayColor(_ delay: Int?, tested: Bool) -> Color {
        guard let delay else { return .secondary }
        return delay < 100 ? .green.opacity(0.7) : .orange.opacity(0.7)
    }

    // MARK: - Disconnected

    private var disconnectedSection: some View {
        VStack(spacing: 6) {
            Image(systemName: "network.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("未连接到后端服务")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                swiftLog.ui("tap tray.openMainWindow")
                openMainWindow()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "gearshape")
                    Text("设置")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                swiftLog.ui("tap tray.exit")
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "power")
                    Text("退出")
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 14)
    }
}

private extension AppService.ProxyMode {
    var trayActiveForegroundColor: Color {
        switch self {
        case .direct:
            return Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
        case .rule:
            return Color(red: 10 / 255, green: 142 / 255, blue: 103 / 255)
        case .global:
            return Color(red: 234 / 255, green: 120 / 255, blue: 50 / 255)
        }
    }

    var trayActiveBackgroundColor: Color {
        switch self {
        case .direct:
            return Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255).opacity(0.08)
        case .rule:
            return Color(red: 16 / 255, green: 185 / 255, blue: 129 / 255).opacity(0.12)
        case .global:
            return Color(red: 249 / 255, green: 115 / 255, blue: 22 / 255).opacity(0.09)
        }
    }

    var trayActiveBorderColor: Color {
        switch self {
        case .direct:
            return Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255).opacity(0.18)
        case .rule:
            return Color(red: 16 / 255, green: 185 / 255, blue: 129 / 255).opacity(0.24)
        case .global:
            return Color(red: 249 / 255, green: 115 / 255, blue: 22 / 255).opacity(0.18)
        }
    }
}
