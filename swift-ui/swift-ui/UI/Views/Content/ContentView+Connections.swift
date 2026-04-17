import SwiftUI

extension ContentView {

    var filteredSortedConnections: [AppService.ConnectionItem] {
        let query = connectionFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = backend.activeConnections.filter { connection in
            if query.isEmpty { return true }
            let text = [
                connection.metadata.host,
                connection.metadata.sourceIP,
                connection.metadata.destinationIP,
                connection.metadata.sourcePort,
                connection.metadata.destinationPort,
                connection.rule,
                connection.rulePayload,
                connection.chains.joined(separator: " ")
            ]
            .joined(separator: " ")
            .lowercased()
            return text.contains(query)
        }

        return filtered.sorted { lhs, rhs in
            let lValue: Int64
            let rValue: Int64
            switch connectionSortBy {
            case .upload:
                lValue = lhs.upload
                rValue = rhs.upload
            case .download:
                lValue = lhs.download
                rValue = rhs.download
            case .uploadSpeed:
                lValue = lhs.uploadSpeed
                rValue = rhs.uploadSpeed
            case .downloadSpeed:
                lValue = lhs.downloadSpeed
                rValue = rhs.downloadSpeed
            }
            return connectionSortDirection == .asc ? lValue < rValue : lValue > rValue
        }
    }

    var totalUploadRate: Int64 {
        backend.activeConnections.reduce(0) { $0 + $1.uploadSpeed }
    }

    var totalDownloadRate: Int64 {
        backend.activeConnections.reduce(0) { $0 + $1.downloadSpeed }
    }

    var connectionsTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("实时连接")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.35))
                .textCase(.uppercase)
                .tracking(1.7)

            connectionStatsGrid
            connectionToolbar
            connectionTableContainer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var directConnectionCount: Int {
        backend.activeConnections.filter { conn in
            let chain = conn.chains.last?.lowercased() ?? "direct"
            return chain == "direct" || chain == "reject"
        }.count
    }

    var proxiedConnectionCount: Int {
        backend.activeConnections.count - directConnectionCount
    }

    var connectionStatsGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            connectionStatCard(
                icon: "wifi",
                iconColor: Color.blue.opacity(0.9),
                label: "活跃连接",
                value: "\(backend.activeConnections.count)",
                subtitle: "直连 \(directConnectionCount) · 代理 \(proxiedConnectionCount)",
                background: Color.blue.opacity(0.08)
            )
            connectionStatCard(
                icon: "arrow.up",
                iconColor: Color.green.opacity(0.9),
                label: "上传总计",
                value: AppService.formatBytes(backend.connectionUploadTotal),
                subtitle: "↑ \(AppService.formatSpeed(totalUploadRate))",
                background: Color.green.opacity(0.08)
            )
            connectionStatCard(
                icon: "arrow.down",
                iconColor: Color.blue.opacity(0.9),
                label: "下载总计",
                value: AppService.formatBytes(backend.connectionDownloadTotal),
                subtitle: "↓ \(AppService.formatSpeed(totalDownloadRate))",
                background: Color.blue.opacity(0.08)
            )
            connectionRateCard
        }
    }

    var connectionRateCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                PulsingDot(color: .green)
                Text("实时速率")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.4))
            }
            Text(AppService.formatSpeed(totalDownloadRate))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text("↑ \(AppService.formatSpeed(totalUploadRate))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.3))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    func connectionStatCard(
        icon: String,
        iconColor: Color,
        label: String,
        value: String,
        subtitle: String?,
        background: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.4))
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.3))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 12))
    }

    var connectionToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.black.opacity(0.25))

                TextField("搜索主机、IP 或代理...", text: $connectionFilter)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)

                if !connectionFilter.isEmpty {
                    Button {
                        swiftLog.ui("tap connections.clearSearch")
                        connectionFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.black.opacity(0.28))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            Spacer(minLength: 8)

            Button {
                swiftLog.ui("tap closeAllConnections")
                Task { await backend.closeAllConnections() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11))
                    Text("关闭全部")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.red.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    var connectionTableContainer: some View {
        VStack(spacing: 0) {
            connectionTableHeader

            Divider().overlay(Color.black.opacity(0.01))

            ScrollView(.vertical, showsIndicators: true) {
                if filteredSortedConnections.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "wifi")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(Color.black.opacity(0.12))
                        Text(connectionFilter.isEmpty ? "暂无活跃连接" : "无匹配连接")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.black.opacity(0.3))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSortedConnections) { connection in
                            connectionRow(connection)
                        }
                    }
                }
            }

            Divider().overlay(Color.black.opacity(0.05))

            HStack {
                Text("显示 \(filteredSortedConnections.count) / \(backend.activeConnections.count) 条连接")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.black.opacity(0.25))
                Spacer()
                HStack(spacing: 5) {
                    PulsingDot(color: .green)
                    Text("实时更新中")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.black.opacity(0.25))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.01))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        )
        .clipped()
    }

    var connectionTableHeader: some View {
        HStack(spacing: 0) {
            Text("主机")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
            Text("类型")
                .frame(width: 60, alignment: .leading)
            sortableHeader("上传", key: .upload)
            sortableHeader("下载", key: .download)
            sortableHeader("上行速率", key: .uploadSpeed)
            sortableHeader("下行速率", key: .downloadSpeed)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.black.opacity(0.35))
        .textCase(.uppercase)
        .tracking(1)
        .padding(.vertical, 4)
        .frame(height: 24)
        // .background(Color.black.opacity(0.02))
    }

    func sortableHeader(_ title: String, key: ConnectionSortKey) -> some View {
        Button {
            swiftLog.ui("tap connections.sort=\(key.rawValue)")
            if connectionSortBy == key {
                connectionSortDirection.toggle()
            } else {
                connectionSortBy = key
                connectionSortDirection = .desc
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if connectionSortBy == key {
                    Image(systemName: connectionSortDirection == .asc ? "triangle.fill" : "triangle.fill")
                        .font(.system(size: 6))
                        .rotationEffect(.degrees(connectionSortDirection == .asc ? 0 : 180))
                }
            }
            .frame(width: 80, alignment: .leading)
            .foregroundStyle(connectionSortBy == key ? Color.blue.opacity(0.75) : Color.black.opacity(0.35))
        }
        .buttonStyle(.plain)
    }

    func connectionRow(_ connection: AppService.ConnectionItem) -> some View {
        let isHovered = hoveredConnectionID == connection.id
        let host = connection.metadata.host.isEmpty ? connection.metadata.destinationIP : connection.metadata.host
        let chainName = connection.chains.last ?? "DIRECT"
        let isDirect = chainName.lowercased() == "direct" || chainName.lowercased() == "reject"
        let routePrefix = isDirect ? "直连" : "代理"
        let ruleTag = connection.rulePayload.isEmpty
            ? "\(routePrefix)/\(connection.rule)"
            : "\(routePrefix)/\(connection.rulePayload)"
        let ipPort = "\(connection.metadata.destinationIP):\(connection.metadata.destinationPort)"

        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.isEmpty ? "Unknown Host" : host)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.7))
                        .lineLimit(1)
                    Text(ruleTag)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(colorForChain(chainName).opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(colorForChain(chainName).opacity(0.14), in: Capsule())
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(ipPort)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.black.opacity(0.3))
                    Circle()
                        .fill(Color.black.opacity(0.2))
                        .frame(width: 2.5, height: 2.5)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(durationText(from: connection.startDate))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.25))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)

            Text(connection.metadata.network.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(connection.metadata.network.lowercased() == "udp"
                                 ? Color.orange.opacity(0.8)
                                 : Color.blue.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    (connection.metadata.network.lowercased() == "udp"
                     ? Color.orange.opacity(0.12)
                     : Color.blue.opacity(0.12)),
                    in: Capsule()
                )
                .frame(width: 60, alignment: .leading)

            Text(AppService.formatBytes(connection.upload))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.45))
                .frame(width: 80, alignment: .leading)

            Text(AppService.formatBytes(connection.download))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.45))
                .frame(width: 80, alignment: .leading)

            Text(AppService.formatSpeed(connection.uploadSpeed))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.green.opacity(0.85))
                .frame(width: 80, alignment: .leading)

            Text(AppService.formatSpeed(connection.downloadSpeed))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.blue.opacity(0.85))
                .frame(width: 80, alignment: .leading)
        }
        .padding(.vertical, 8)
        .background(isHovered ? Color.black.opacity(0.02) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.04))
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
            hoveredConnectionID = hovering ? connection.id : nil
        }
        .contextMenu {
            Button(role: .destructive) {
                swiftLog.ui("tap closeConnection=\(connection.id)")
                Task { await backend.closeConnection(id: connection.id) }
            } label: {
                Label("关闭连接", systemImage: "xmark.circle")
            }
        }
    }

    func durationText(from startDate: Date?) -> String {
        guard let startDate else { return "0s" }
        let seconds = max(Int(Date().timeIntervalSince(startDate)), 0)
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minute = seconds / 60
        let remain = seconds % 60
        if minute < 60 {
            return remain == 0 ? "\(minute)m" : "\(minute)m \(remain)s"
        }
        let hour = minute / 60
        let minRemain = minute % 60
        return minRemain == 0 ? "\(hour)h" : "\(hour)h \(minRemain)m"
    }

    func colorForChain(_ name: String) -> Color {
        let lowered = name.lowercased()
        if lowered.contains("tokyo") { return .pink }
        if lowered.contains("singapore") { return .purple }
        if lowered.contains("hk") { return .orange }
        if lowered.contains("us") { return .blue }
        if lowered.contains("direct") { return .green }
        return .blue
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color.opacity(0.85))
            .frame(width: 7, height: 7)
            .scaleEffect(pulse ? 1.15 : 0.85)
            .opacity(pulse ? 1 : 0.6)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear {
                pulse = true
            }
    }
}
