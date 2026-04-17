import SwiftUI

extension ContentView {

    // MARK: - Master Switch

    var masterSwitchOn: Bool {
        backend.sysProxyEnabled || backend.tunEnabled
    }

    var masterSwitchToggle: some View {
        Group {
            if backend.isTogglingQuickSwitch {
                ProgressView()
                    .controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { masterSwitchOn },
                    set: { enabled in
                        if enabled && backend.subscriptions.isEmpty {
                            swiftLog.ui("toggle masterSwitch blocked: no subscriptions")
                            promptSubscriptionSetup()
                            return
                        }
                        swiftLog.ui("toggle masterSwitch=\(enabled)")
                        Task { await backend.toggleQuickSwitch(enabled) }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.green)
            }
        }
    }

    func promptSubscriptionSetup() {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedTab = .nodes
            showSettings = false
        }
        showImportSubscriptionSheet = true
    }

    var masterOffPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("已关闭系统代理和虚拟网卡，不再实时统计流量")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    // MARK: - Mode Tab Panel

    var modeTabContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
            Text("实时流量")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .padding(.top, 8)
                trafficView
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                Text("模式切换")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Spacer()
                    masterSwitchToggle
                }

                if masterSwitchOn {
                    modeSelector
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    masterOffPlaceholder
                }
            }
            .animation(.easeInOut(duration: 0.25), value: masterSwitchOn)

            if masterSwitchOn {
                if backend.proxyMode != .rule {
                    modeBanner(backend.proxyMode)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .animation(.easeInOut(duration: 0.25), value: backend.proxyMode)
                }

                if backend.proxyMode == .rule {
                    VStack(alignment: .leading, spacing: 10) {
                    Text("规则组")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.6))
                        ruleGroupsView
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: masterSwitchOn)
    }

    var nodesTabContent: some View {
        VStack(spacing: 0) {
            subscriptionManagementView
            if backend.activeProxyGroup != nil {
                Divider()
                    .opacity(0.6)
                    .padding(.top, 21)
                    .padding(.bottom, 16)
                nodeSelectionView
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Mode Selector

    var modeSelector: some View {
        HStack(spacing: 10) {
            ForEach(AppService.ProxyMode.allCases) { mode in
                modeCard(mode)
            }
        }
    }

    func modeBanner(_ mode: AppService.ProxyMode) -> some View {
        let color = mode.highlightColor
        let (detail, tip): (String, String) = switch mode {
        case .direct:
            ("所有流量直接连接目标服务器，不经过任何代理节点。", "适合访问国内资源或代理节点异常时临时使用。")
        case .rule:
            ("流量根据规则集自动分流，匹配规则的请求走代理，其余直连。", "需在下方选择代理节点，规则可在配置文件中自定义。")
        case .global:
            ("所有流量均通过当前代理节点转发，不做分流判断。", "适合需要完整代理访问或排查分流问题时使用。")
        }

        return VStack(spacing: 8) {
            Image(systemName: mode.icon)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(color.opacity(0.7))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    func modeCard(_ mode: AppService.ProxyMode) -> some View {
        let isActive = backend.proxyMode == mode
        let disabled = backend.isBusy
        let color = mode.highlightColor

        return Button {
            guard !isActive, !disabled else { return }
            swiftLog.ui("tap setProxyMode=\(mode.rawValue)")
            Task { await backend.setProxyMode(mode) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isActive ? color : .secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        (isActive ? color : Color.secondary).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isActive ? color.opacity(0.75) : .secondary)
                    Text(mode.description)
                        .font(.system(size: 12))
                        .foregroundStyle(isActive ? AnyShapeStyle(color.opacity(0.5)) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                isActive
                    ? color.opacity(0.06)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.4),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isActive ? color.opacity(0.25) : Color.secondary.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.7 : 1)
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .animation(.easeInOut(duration: 0.2), value: disabled)
    }
}
