import SwiftUI

extension ContentView {

    private var snifferCurrentSignature: String {
        [
            snifferControlEnabled ? "1" : "0",
            snifferEnable ? "1" : "0",
            snifferParsePureIP ? "1" : "0",
            snifferForceDNSMapping ? "1" : "0",
            snifferOverrideDestination ? "1" : "0",
            snifferHTTPPortsText.trimmingCharacters(in: .whitespacesAndNewlines),
            snifferTLSPortsText.trimmingCharacters(in: .whitespacesAndNewlines),
            snifferQUICPortsText.trimmingCharacters(in: .whitespacesAndNewlines),
            snifferSkipDomainText.trimmingCharacters(in: .whitespacesAndNewlines),
            snifferForceDomainText.trimmingCharacters(in: .whitespacesAndNewlines),
            snifferSkipDstAddressText.trimmingCharacters(in: .whitespacesAndNewlines),
            snifferSkipSrcAddressText.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\n---\n")
    }

    private var snifferHasChanges: Bool {
        snifferLoaded && snifferCurrentSignature != snifferSavedSignature
    }

    var snifferTabContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            snifferTopBar
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    snifferBasicCard
                    snifferPortsCard
                    snifferListCard(
                        title: "skip-domain",
                        hint: "每行一条，如：+.push.apple.com",
                        text: $snifferSkipDomainText
                    )
                    snifferListCard(
                        title: "force-domain",
                        hint: "每行一条，强制嗅探域名",
                        text: $snifferForceDomainText
                    )
                    snifferListCard(
                        title: "skip-dst-address",
                        hint: "每行一条 CIDR，如：149.154.160.0/20",
                        text: $snifferSkipDstAddressText
                    )
                    snifferListCard(
                        title: "skip-src-address",
                        hint: "每行一条 CIDR，可留空",
                        text: $snifferSkipSrcAddressText
                    )
                    if let message = snifferErrorMessage {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 2)
                    } else if let message = snifferSuccessMessage {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            await ensureSnifferLoaded()
        }
    }

    private var snifferTopBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("嗅探覆写")
                          .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.35))
                    .textCase(.uppercase)
                    .tracking(1.7)
        
            }
            Spacer()
            if snifferLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if snifferHasChanges {
                Button {
                    swiftLog.ui("tap sniffer.save")
                    Task { await applySnifferConfig() }
                } label: {
                    if snifferSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(snifferControlEnabled ? "保存并应用" : "仅保存", systemImage: "checkmark.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(snifferLoading || snifferSaving)
            }
        }
    }

    private var snifferBasicCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("基础开关")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            snifferToggleRow(
                title: "启用嗅探",
                description: "关闭后不会进行域名嗅探",
                value: $snifferEnable,
                logKey: "snifferEnable"
            )
            snifferToggleRow(
                title: "覆写目标地址",
                description: "同时同步到 sniff.HTTP.override-destination",
                value: $snifferOverrideDestination,
                logKey: "snifferOverrideDestination"
            )
            .onChange(of: snifferOverrideDestination) { _, _ in
                snifferSuccessMessage = nil
                snifferErrorMessage = nil
            }
            snifferToggleRow(
                title: "force-dns-mapping",
                description: "将嗅探域名映射到 DNS 结果",
                value: $snifferForceDNSMapping,
                logKey: "snifferForceDNSMapping"
            )
            snifferToggleRow(
                title: "parse-pure-ip",
                description: "尝试解析纯 IP 连接",
                value: $snifferParsePureIP,
                logKey: "snifferParsePureIP"
            )
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var snifferPortsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("嗅探端口")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            snifferPortField(
                title: "HTTP ports",
                hint: "逗号分隔，例如：80,443",
                text: $snifferHTTPPortsText
            )
            snifferPortField(
                title: "TLS ports",
                hint: "逗号分隔，例如：443",
                text: $snifferTLSPortsText
            )
            snifferPortField(
                title: "QUIC ports",
                hint: "逗号分隔，可留空",
                text: $snifferQUICPortsText
            )
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func snifferToggleRow(
        title: String,
        description: String,
        value: Binding<Bool>,
        logKey: String
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.55))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { value.wrappedValue },
                set: { newValue in
                    swiftLog.ui("tap sniffer.toggle \(logKey)=\(newValue)")
                    value.wrappedValue = newValue
                }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func snifferPortField(title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.55))
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private func snifferListCard(title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color.black.opacity(0.8))
                .padding(8)
                .frame(minHeight: 110)
                .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func ensureSnifferLoaded() async {
        if snifferLoaded { return }
        await reloadSnifferConfig()
    }

    private func reloadSnifferConfig() async {
        guard !snifferLoading, !snifferSaving else { return }
        snifferLoading = true
        snifferErrorMessage = nil
        snifferSuccessMessage = nil
        defer { snifferLoading = false }

        do {
            let payload = try await backend.fetchSnifferOverrideConfig()
            let config = payload.config
            snifferControlEnabled = payload.controlSniff
            snifferEnable = config.enable
            snifferParsePureIP = config.parsePureIP
            snifferForceDNSMapping = config.forceDNSMapping
            snifferOverrideDestination = config.overrideDestination
            snifferHTTPPortsText = Self.snifferPortsLine(from: config.httpPorts)
            snifferTLSPortsText = Self.snifferPortsLine(from: config.tlsPorts)
            snifferQUICPortsText = Self.snifferPortsLine(from: config.quicPorts)
            snifferSkipDomainText = Self.snifferListLines(from: config.skipDomain)
            snifferForceDomainText = Self.snifferListLines(from: config.forceDomain)
            snifferSkipDstAddressText = Self.snifferListLines(from: config.skipDstAddress)
            snifferSkipSrcAddressText = Self.snifferListLines(from: config.skipSrcAddress)
            snifferLoaded = true
            snifferSavedSignature = snifferCurrentSignature
        } catch {
            snifferErrorMessage = "加载嗅探配置失败: \(error.localizedDescription)"
        }
    }

    private func applySnifferConfig() async {
        guard !snifferSaving, !snifferLoading else { return }
        snifferSaving = true
        snifferErrorMessage = nil
        snifferSuccessMessage = nil
        defer { snifferSaving = false }

        do {
            let httpPorts = try Self.parsePorts(from: snifferHTTPPortsText, name: "HTTP")
            let tlsPorts = try Self.parsePorts(from: snifferTLSPortsText, name: "TLS")
            let quicPorts = try Self.parsePorts(from: snifferQUICPortsText, name: "QUIC")
            let config = AppService.SnifferOverrideConfig(
                enable: snifferEnable,
                parsePureIP: snifferParsePureIP,
                forceDNSMapping: snifferForceDNSMapping,
                overrideDestination: snifferOverrideDestination,
                httpPorts: httpPorts,
                tlsPorts: tlsPorts,
                quicPorts: quicPorts,
                skipDomain: Self.parseLineList(from: snifferSkipDomainText),
                forceDomain: Self.parseLineList(from: snifferForceDomainText),
                skipDstAddress: Self.parseLineList(from: snifferSkipDstAddressText),
                skipSrcAddress: Self.parseLineList(from: snifferSkipSrcAddressText)
            )
            try await backend.applySnifferOverrideConfig(config, controlSniff: snifferControlEnabled)
            snifferSuccessMessage = snifferControlEnabled
                ? "嗅探配置已应用，核心已重启"
                : "嗅探配置已保存到受控配置"
            snifferSavedSignature = snifferCurrentSignature
        } catch {
            snifferErrorMessage = "应用失败: \(error.localizedDescription)"
        }
    }

    private static func snifferPortsLine(from values: [Int]) -> String {
        values.map(String.init).joined(separator: ",")
    }

    private static func snifferListLines(from values: [String]) -> String {
        values.joined(separator: "\n")
    }

    private static func parseLineList(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func parsePorts(from text: String, name: String) throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let values = trimmed.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var ports: [Int] = []
        for item in values {
            guard let port = Int(item), (1...65535).contains(port) else {
                throw SnifferInputError.invalidPort(name: name, value: item)
            }
            ports.append(port)
        }
        return ports
    }
}

private enum SnifferInputError: LocalizedError {
    case invalidPort(name: String, value: String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let name, let value):
            return "\(name) 端口无效: \(value)"
        }
    }
}
