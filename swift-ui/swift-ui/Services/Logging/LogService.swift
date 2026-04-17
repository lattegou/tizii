import Foundation

@MainActor
final class LogService {
    private let exporter = LogArchiveExporter()

    nonisolated func exportServiceLogs(days: Int = 7) async throws -> (filename: String, data: Data) {
        try await exporter.exportServiceLogs(days: days)
    }
}

private actor LogArchiveExporter {
    enum ExportError: LocalizedError {
        case logDirectoryNotFound
        case noRecentLogs(Int)
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .logDirectoryNotFound:
                return "未找到日志目录"
            case .noRecentLogs(let days):
                return "最近\(days)天未找到可导出的日志"
            case .zipFailed(let message):
                return "日志压缩失败: \(message)"
            }
        }
    }

    private let fileManager = FileManager.default

    func exportServiceLogs(days: Int = 7) async throws -> (filename: String, data: Data) {
        let resolvedDays = max(days, 1)
        let logDir = PathManager.logDir

        guard fileManager.fileExists(atPath: logDir.path) else {
            throw ExportError.logDirectoryNotFound
        }

        var files: [URL] = []
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())

        for offset in stride(from: resolvedDays - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let suffix = Self.dayFormatter.string(from: date)
            let candidates = [
                "core-\(suffix).log",
                "swift-\(suffix).log"
            ]
            for name in candidates {
                let url = logDir.appendingPathComponent(name, isDirectory: false)
                if fileManager.fileExists(atPath: url.path) {
                    files.append(url)
                }
            }
        }

        if files.isEmpty {
            throw ExportError.noRecentLogs(resolvedDays)
        }

        let dateStamp = Self.archiveFormatter.string(from: Date())
        let filename = "service-logs-last-\(resolvedDays)-days-\(dateStamp).zip"
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent(filename, isDirectory: false)
        try makeZip(archiveURL: archiveURL, files: files, currentDirectory: logDir)

        let data = try Data(contentsOf: archiveURL)
        return (filename, data)
    }

    private func makeZip(archiveURL: URL, files: [URL], currentDirectory: URL) throws {
        let fileNames = files.map(\.lastPathComponent)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = currentDirectory
        process.arguments = ["-q", archiveURL.path] + fileNames

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw ExportError.zipFailed(message)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let archiveFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
