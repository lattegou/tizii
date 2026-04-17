import SwiftUI

extension ContentView {

    private var dnsCurrentSignature: String {
        [
            dnsEnable ? "1" : "0",
            dnsDefaultNameserverText.trimmingCharacters(in: .whitespacesAndNewlines),
            dnsNameserverText.trimmingCharacters(in: .whitespacesAndNewlines),
            dnsProxyNameserverText.trimmingCharacters(in: .whitespacesAndNewlines),
            dnsDirectNameserverText.trimmingCharacters(in: .whitespacesAndNewlines),
            dnsHostsText.trimmingCharacters(in: .whitespacesAndNewlines),
            dnsPolicyText.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\n---\n")
    }

    private var dnsHasChanges: Bool {
        dnsLoaded && dnsCurrentSignature != dnsSavedSignature
    }

    var dnsTabContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            dnsTopBar
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    dnsToggleCard
                    dnsUpstreamCard
                    dnsHostsCard
                    dnsPolicyCard
                    if let message = dnsErrorMessage {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 2)
                    } else if let message = dnsSuccessMessage {
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
            await ensureDNSLoaded()
        }
    }

    private var dnsTopBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("DNS 覆写")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.35))
                    .textCase(.uppercase)
                    .tracking(1.7)
              
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if dnsLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if dnsHasChanges {
                Button {
                    swiftLog.ui("tap dns.save")
                    Task { await applyDNSConfig() }
                } label: {
                    if dnsSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("保存", systemImage: "checkmark.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(dnsLoading || dnsSaving)
            }
        }
    }

    private var dnsToggleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("基础开关")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("启用 DNS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.55))

                    Text("关闭后不使用 DNS 覆写配置")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { dnsEnable },
                    set: { enabled in
                        swiftLog.ui("tap dns.toggle dnsEnable=\(enabled)")
                        dnsEnable = enabled
                    }
                ))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var dnsUpstreamCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("上游 DNS")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            dnsMultilineField(
                title: "default-nameserver",
                hint: "一行一个，如：tls://223.5.5.5",
                text: $dnsDefaultNameserverText
            )
            dnsMultilineField(
                title: "nameserver",
                hint: "一行一个，如：https://doh.pub/dns-query",
                text: $dnsNameserverText
            )
            dnsMultilineField(
                title: "proxy-server-nameserver",
                hint: "代理服务器域名解析使用",
                text: $dnsProxyNameserverText
            )
            dnsMultilineField(
                title: "direct-nameserver",
                hint: "直连流量 DNS，可留空",
                text: $dnsDirectNameserverText
            )
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var dnsHostsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hosts 覆写")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("每行一条：domain ip，例如：api.example.com 1.1.1.1")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            dnsTextEditor(text: $dnsHostsText, minHeight: 120)
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var dnsPolicyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nameserver Policy")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("每行一条：domainPattern dns[,dns2]，例如：+.google.com https://dns.google/dns-query")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            dnsTextEditor(text: $dnsPolicyText, minHeight: 140)
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func dnsMultilineField(title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.55))
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            dnsTextEditor(text: text, minHeight: 68)
        }
    }

    private func dnsTextEditor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(Color.black.opacity(0.8))
            .padding(8)
            .frame(minHeight: minHeight)
            .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
            )
    }

    private func ensureDNSLoaded() async {
        if dnsLoaded { return }
        await reloadDNSConfig()
    }

    private func reloadDNSConfig() async {
        guard !dnsLoading, !dnsSaving else { return }
        dnsLoading = true
        dnsErrorMessage = nil
        dnsSuccessMessage = nil
        defer { dnsLoading = false }

        do {
            let config = try await backend.fetchDNSOverrideConfig()
            dnsEnable = config.enable
            dnsDefaultNameserverText = Self.lines(from: config.defaultNameserver)
            dnsNameserverText = Self.lines(from: config.nameserver)
            dnsProxyNameserverText = Self.lines(from: config.proxyServerNameserver)
            dnsDirectNameserverText = Self.lines(from: config.directNameserver)
            dnsHostsText = Self.lines(fromHosts: config.hosts)
            dnsPolicyText = Self.lines(fromPolicy: config.nameserverPolicy)
            dnsLoaded = true
            dnsSavedSignature = dnsCurrentSignature
        } catch {
            dnsErrorMessage = "加载 DNS 配置失败: \(error.localizedDescription)"
        }
    }

    private func applyDNSConfig() async {
        guard !dnsSaving, !dnsLoading else { return }
        dnsSaving = true
        dnsErrorMessage = nil
        dnsSuccessMessage = nil
        defer { dnsSaving = false }

        do {
            let hosts = try Self.parseHosts(from: dnsHostsText)
            let policy = try Self.parsePolicy(from: dnsPolicyText)
            let config = AppService.DNSOverrideConfig(
                enable: dnsEnable,
                defaultNameserver: Self.parseLines(from: dnsDefaultNameserverText),
                nameserver: Self.parseLines(from: dnsNameserverText),
                proxyServerNameserver: Self.parseLines(from: dnsProxyNameserverText),
                directNameserver: Self.parseLines(from: dnsDirectNameserverText),
                hosts: hosts,
                nameserverPolicy: policy
            )
            try await backend.applyDNSOverrideConfig(config)
            dnsSuccessMessage = "DNS 配置已应用，核心已重启"
            dnsSavedSignature = dnsCurrentSignature
            await backend.fetchSwitchStates()
        } catch {
            dnsErrorMessage = "应用失败: \(error.localizedDescription)"
        }
    }

    private static func parseLines(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func lines(from values: [String]) -> String {
        values.joined(separator: "\n")
    }

    private static func lines(fromHosts hosts: [String: String]) -> String {
        hosts
            .map { "\($0.key) \($0.value)" }
            .sorted()
            .joined(separator: "\n")
    }

    private static func lines(fromPolicy policy: [String: [String]]) -> String {
        policy
            .map { key, values in
                "\(key) \(values.joined(separator: ","))"
            }
            .sorted()
            .joined(separator: "\n")
    }

    private static func parseHosts(from text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let normalized = line.replacingOccurrences(of: "=", with: " ")
            let parts = normalized
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            guard parts.count == 2 else {
                throw DNSInputError.invalidHostsFormat(line: idx + 1)
            }
            result[parts[0]] = parts[1]
        }
        return result
    }

    private static func parsePolicy(from text: String) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let segments = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            guard segments.count == 2 else {
                throw DNSInputError.invalidPolicyFormat(line: idx + 1)
            }
            let key = segments[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let dnsValues = segments[1]
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !key.isEmpty, !dnsValues.isEmpty else {
                throw DNSInputError.invalidPolicyFormat(line: idx + 1)
            }
            result[key] = dnsValues
        }
        return result
    }
}

private enum DNSInputError: LocalizedError {
    case invalidHostsFormat(line: Int)
    case invalidPolicyFormat(line: Int)

    var errorDescription: String? {
        switch self {
        case .invalidHostsFormat(let line):
            return "Hosts 第 \(line) 行格式错误，需为: domain ip"
        case .invalidPolicyFormat(let line):
            return "Policy 第 \(line) 行格式错误，需为: domainPattern dns[,dns2]"
        }
    }
}
