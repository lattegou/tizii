import SwiftUI

extension ContentView {

    // MARK: - Node Selection

    var filteredProxyNodes: [String] {
        guard let group = backend.activeProxyGroup else { return [] }
        let query = nodeFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nodes = query.isEmpty ? group.all : group.all.filter { $0.lowercased().contains(query) }
        guard !backend.isTestingProxies, !backend.proxyDelayResults.isEmpty else {
            return nodes
        }
        return nodes.sorted { lhs, rhs in
            let l = backend.proxyDelayResults[lhs] ?? Int.max
            let r = backend.proxyDelayResults[rhs] ?? Int.max
            if l == r {
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            return l < r
        }
    }

    var nodeSelectionView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("节点选择")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                if backend.isTestingProxies {
                    ProgressView().controlSize(.mini)
                }

                Spacer()

                Button {
                    swiftLog.ui("tap testProxyDelays")
                    Task { await backend.testActiveProxyDelays() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12))
                        Text("测速")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(backend.isTestingProxies)
            }
            .padding(.horizontal, 6)

            let items = filteredProxyNodes
            ScrollView(.vertical, showsIndicators: true) {
                if items.isEmpty {
                    Text(nodeFilter.isEmpty ? "暂无节点" : "无匹配结果")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    let columns = [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ]
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(items, id: \.self) { proxy in
                            nodeCard(proxy)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

 

    func nodeCard(_ proxy: String) -> some View {
        let isActive = backend.activeProxyGroup?.now == proxy
        let delay = backend.proxyDelayResults[proxy]

        return Button {
            guard !isActive, let group = backend.activeProxyGroup else { return }
            swiftLog.ui("tap selectProxy=\(proxy)")
            Task { await backend.changeProxy(group: group.name, proxy: proxy) }
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    if let emoji = extractLeadingEmoji(proxy) {
                        Text(emoji)
                            .font(.system(size: 18))
                    } else {
                        Image(systemName: "network")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(strippedProxyName(proxy))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(proxySubtitle(proxy))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 4) {
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor.opacity(0.6))
                    }
                    if let d = delay {
                        Text("\(d)ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(delayColor(d))
                    } else if backend.isTestingProxies {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("—")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isActive
                    ? Color.accentColor.opacity(0.08)
                    : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isActive ? Color.accentColor.opacity(0.19) : Color.secondary.opacity(0.08),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    func delayColor(_ delay: Int) -> Color {
        switch delay {
        case ..<200: .green
        case ..<500: .orange
        default: .red
        }
    }

    // MARK: - Helpers

    func extractLeadingEmoji(_ text: String) -> String? {
        guard let firstChar = text.first,
              let firstScalar = firstChar.unicodeScalars.first,
              firstScalar.value > 127 else { return nil }
        return String(text.prefix(1))
    }

    func strippedProxyName(_ proxy: String) -> String {
        guard let firstChar = proxy.first,
              let firstScalar = firstChar.unicodeScalars.first,
              firstScalar.value > 127 else { return proxy }
        return String(proxy.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    func proxySubtitle(_ proxy: String) -> String {
        let name = strippedProxyName(proxy).lowercased()
        let protocols = ["vmess", "vless", "trojan", "shadowsocks", "hysteria", "tuic", "socks5", "http"]
        for proto in protocols {
            if name.contains(proto) {
                return proto == "shadowsocks" ? "Shadowsocks" : proto.capitalized
            }
        }
        return "代理节点"
    }
}
