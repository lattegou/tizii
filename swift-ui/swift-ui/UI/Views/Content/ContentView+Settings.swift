import AppKit
import SwiftUI

extension ContentView {

    // MARK: - Disconnected

    var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)

            Text(disconnectedStatusText)
                .font(.title3.weight(.medium))

            Text(disconnectedHintText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = backend.connectionError, !isKnownDisconnectedStatus(error) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .padding(20)
    }

    private var disconnectedStatusText: String {
        backend.connectionError ?? "核心未运行"
    }

    private var disconnectedHintText: String {
        if let error = backend.connectionError, !error.isEmpty {
            return "启动遇到问题，请检查日志或重试"
        }
        return "正在启动 mihomo 核心服务…"
    }

    private func isKnownDisconnectedStatus(_ value: String) -> Bool {
        value == "核心未运行" || value == "核心启动失败"
    }

    // MARK: - Settings Panel (Right Side)

    var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsGeneralSection
                settingsNetworkSection
                settingsAboutSection
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Sections

    var settingsGeneralSection: some View {
        settingsSectionCard(title: "常规") {
            settingsToggleRow("开机自启动", description: "系统启动时自动运行", isOn: $launchAtLogin, logKey: "launchAtLogin")
            settingsRowDivider()
            settingsToggleRow("菜单栏图标", description: "在菜单栏显示状态图标", isOn: $showMenuBarIcon, logKey: "showMenuBarIcon")
            settingsRowDivider()
            settingsToggleRow("系统通知", description: "连接状态变化时发送通知", isOn: $systemNotifications, logKey: "systemNotifications")
            settingsRowDivider()
            developerModeRow
        }
    }

    var settingsNetworkSection: some View {
        settingsSectionCard(title: "网络") {
            settingsPortRow("HTTP 端口", text: $httpPort)
            settingsRowDivider()
            settingsPortRow("SOCKS5 端口", text: $socks5Port)
            settingsRowDivider()
            settingsToggleRow("允许局域网连接", description: "其他设备可通过本机代理上网", isOn: .constant(false))
                .disabled(true)
                .opacity(0.45)
        }
    }

    private var appVersion: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let build { return "v\(ver) (\(build))" }
        return "v\(ver)"
    }

    var settingsAboutSection: some View {
        settingsSectionCard(title: "关于") {
            settingsInfoRow("当前版本", value: appVersion)
            settingsRowDivider()
            settingsCheckUpdateRow
            settingsRowDivider()
            settingsFeedbackRow
            settingsRowDivider()
            settingsLegalRow
        }
    }

    private var settingsLegalRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("版权与致谢")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.65))
                Text("© 2024-2026 Tam Diep Van")
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.38))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
            
                Text("Powered by mihomo © 2023 KT")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.38))
                Text("MIT License")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.32))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Feedback

    var settingsFeedbackRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("反馈问题")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.65))
                Text("导出日志压缩包，查看反馈邮箱")
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.38))
            }
            Spacer()
            Button {
                swiftLog.ui("tap sendFeedback")
                exportLogsAndShowFeedback()
            } label: {
                if isSendingFeedback {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("发送反馈")
                }
            }
            .disabled(isSendingFeedback)
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .font(.system(size: 13))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func exportLogsAndShowFeedback() {
        guard !isSendingFeedback else { return }
        isSendingFeedback = true

        Task {
            defer { isSendingFeedback = false }

            do {
                let archiveURL = try await backend.exportRecentServiceLogsArchive(days: 7)
                feedbackLogPath = archiveURL.path
                showFeedbackAlert = true
            } catch {
                showImportResult(title: "反馈失败", message: "日志导出失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Row Helpers

    var developerModeRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("开发者模式")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.65))
                Text("显示 DNS、日志、嗅探等调试面板")
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.38))
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { developerMode },
                set: { enabled in
                    swiftLog.ui("tap settings.toggle developerMode=\(enabled)")
                    developerMode = enabled
                }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(developerMode ? .orange : .accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    var settingsCheckUpdateRow: some View {
        HStack(spacing: 12) {
            Text("检查更新")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color(nsColor: .labelColor).opacity(0.65))
            Spacer()
            Button("立即检查") {
                swiftLog.ui("tap checkForUpdates")
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .font(.system(size: 13))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    func settingsRowDivider() -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.35))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    func settingsSectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.gray.opacity(0.13), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity)
    }

    func settingsToggleRow(_ label: String, description: String? = nil, isOn: Binding<Bool>, logKey: String? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.65))
                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: .labelColor).opacity(0.38))
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn.wrappedValue },
                set: { newValue in
                    swiftLog.ui("tap settings.toggle \(logKey ?? label)=\(newValue)")
                    isOn.wrappedValue = newValue
                }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    func settingsPortRow(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color(nsColor: .labelColor).opacity(0.65))
            Spacer()
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(nsColor: .labelColor))
                .frame(width: 72)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    func settingsInfoRow(_ label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color(nsColor: .labelColor).opacity(0.65))
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(Color(nsColor: .labelColor).opacity(0.38))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

}
