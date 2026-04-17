import AppKit
import SwiftUI

extension ContentView {

    private static let logTimeGapThreshold: TimeInterval = 60

    var filteredLogEntries: [AppService.LogEntry] {
        let query = logSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return backend.logEntries.filter { entry in
            if !logLevelFilter.matches(level: entry.level) { return false }
            if query.isEmpty { return true }
            return entry.payload.lowercased().contains(query) || entry.level.lowercased().contains(query)
        }
    }

    var logsErrorCount: Int {
        backend.logEntries.filter { $0.level.lowercased() == "error" }.count
    }

    var logsWarnCount: Int {
        backend.logEntries.filter { $0.level.lowercased() == "warning" || $0.level.lowercased() == "warn" }.count
    }

    var logsTabContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            logsToolbar
            logsFilterBar
            logsListArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var logsToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.black.opacity(0.35))

                TextField("搜索日志…", text: $logSearchText)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)

                if !logSearchText.isEmpty {
                    Button {
                        swiftLog.ui("tap logs.clearSearch")
                        logSearchText = ""
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
                swiftLog.ui("tap toggleAutoScroll=\(!logAutoScroll)")
                logAutoScroll.toggle()
            } label: {
                Image(systemName: logAutoScroll ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(logAutoScroll ? Color.accentColor : Color.black.opacity(0.4))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .help(logAutoScroll ? "自动滚动已开启" : "自动滚动已关闭")
            }
            .buttonStyle(.plain)

            Button {
                swiftLog.ui("tap exportLogs")
                exportRecentServiceLogs()
            } label: {
                Group {
                    if isExportingNodeLogs {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.black.opacity(0.5))
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.4))
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .help("导出日志")
            }
            .buttonStyle(.plain)
            .disabled(isExportingNodeLogs)

            Button {
                swiftLog.ui("tap clearLogs")
                backend.clearLogs()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.4))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .help("清空日志")
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 12)
    }

    private var logsFilterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(ContentView.LogLevelFilter.allCases, id: \.self) { level in
                    logsLevelButton(level)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Text("\(filteredLogEntries.count) 条")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.4))

                if logsErrorCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 5, height: 5)
                        Text("\(logsErrorCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                }
                if logsWarnCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 5, height: 5)
                        Text("\(logsWarnCount)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.orange.opacity(0.9))
                    }
                }
            }
        }
        .padding(.bottom, 10)
    }

    private func logsLevelButton(_ level: ContentView.LogLevelFilter) -> some View {
        let isSelected = logLevelFilter == level
        return Button {
            swiftLog.ui("tap logLevel=\(level.label)")
            logLevelFilter = level
        } label: {
            HStack(spacing: 4) {
                if level != .all {
                    Circle()
                        .fill(logsLevelDotColor(level))
                        .frame(width: 3, height: 3)
                }
                Text(level.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(logsLevelBackground(level, isSelected: isSelected))
            )
            .foregroundStyle(logsLevelForeground(level, isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    private func logsLevelDotColor(_ level: ContentView.LogLevelFilter) -> Color {
        switch level {
        case .all: return Color.black.opacity(0.3)
        case .debug: return Color.gray
        case .info: return Color.blue
        case .warn: return Color.orange
        case .error: return Color.red
        }
    }

    private func logsLevelBackground(_ level: ContentView.LogLevelFilter, isSelected: Bool) -> Color {
        guard isSelected else { return Color.clear }
        switch level {
        case .all: return Color.black.opacity(0.08)
        case .debug: return Color.gray.opacity(0.15)
        case .info: return Color.blue.opacity(0.12)
        case .warn: return Color.orange.opacity(0.12)
        case .error: return Color.red.opacity(0.12)
        }
    }

    private func logsLevelForeground(_ level: ContentView.LogLevelFilter, isSelected: Bool) -> Color {
        if !isSelected { return Color.black.opacity(0.5) }
        switch level {
        case .all: return Color.black.opacity(0.65)
        case .debug: return Color.gray
        case .info: return Color.blue
        case .warn: return Color.orange
        case .error: return Color.red
        }
    }

    private var logsListArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                if filteredLogEntries.isEmpty {
                    Text("暂无日志")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.black.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredLogEntries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                let prev = filteredLogEntries[index - 1]
                                if entry.receivedAt.timeIntervalSince(prev.receivedAt) > Self.logTimeGapThreshold {
                                    logsTimeGapSeparator(from: prev.receivedAt, to: entry.receivedAt)
                                }
                            }
                            logsRow(entry)
                                .id(entry.id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.018), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            )
            .onChange(of: filteredLogEntries.count) { _, _ in
                if logAutoScroll, let last = filteredLogEntries.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func logsTimeGapSeparator(from: Date, to: Date) -> some View {
        let gap = Int(to.timeIntervalSince(from))
        return HStack(spacing: 8) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
            Text("\(gap)s 间隔")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.35))
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
    }

    private func logsRow(_ entry: AppService.LogEntry) -> some View {
        let level = entry.level.lowercased() == "warning" ? "warn" : entry.level.lowercased()
        return HStack(alignment: .top, spacing: 10) {
            Text(entry.timeDisplay)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.4))
                .frame(width: 82, alignment: .leading)

            logsLevelBadge(level)

            Text(entry.payload)
                .font(.system(size: 12))
                .foregroundStyle(logsMessageColor(level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear)
    }

    private func logsLevelBadge(_ level: String) -> some View {
        let (label, color): (String, Color) = {
            switch level {
            case "error": return ("ERROR", Color.red)
            case "warning", "warn": return ("WARN", Color.orange)
            case "info": return ("INFO", Color.blue)
            case "debug": return ("DEBUG", Color.gray)
            default: return (level.uppercased(), Color.black.opacity(0.5))
            }
        }()
        return Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func logsMessageColor(_ level: String) -> Color {
        switch level {
        case "error": return Color.red.opacity(0.9)
        case "warning", "warn": return Color.orange.opacity(0.9)
        case "debug": return Color.black.opacity(0.4)
        default: return Color.black.opacity(0.5)
        }
    }

    private func exportRecentServiceLogs() {
        guard !isExportingNodeLogs else { return }
        isExportingNodeLogs = true

        Task {
            defer { isExportingNodeLogs = false }
            do {
                let archiveURL = try await backend.exportRecentServiceLogsArchive(days: 7)
                defer { try? FileManager.default.removeItem(at: archiveURL) }

                let panel = NSSavePanel()
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                panel.allowedFileTypes = ["zip"]
                panel.nameFieldStringValue = archiveURL.lastPathComponent
                panel.title = "导出最近 7 天服务日志"
                panel.message = "包含 Mihomo 与 Node 日志，导出为 zip 压缩包"

                guard panel.runModal() == .OK, let targetURL = panel.url else { return }

                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.copyItem(at: archiveURL, to: targetURL)
                showImportResult(title: "导出成功", message: "日志已导出到：\(targetURL.path)")
            } catch {
                showImportResult(title: "导出失败", message: error.localizedDescription)
            }
        }
    }
}
