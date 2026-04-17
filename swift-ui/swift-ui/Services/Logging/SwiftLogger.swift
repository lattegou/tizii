import Foundation

final class SwiftLogger: @unchecked Sendable {
    static let shared = SwiftLogger()

    private let queue = DispatchQueue(label: "com.airtiz.swift-logger", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentDate: String = ""

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {}

    private var logDirPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/airtiz/logs"
    }

    private func ensureFileHandle() {
        let today = dateFormatter.string(from: Date())
        if today == currentDate, fileHandle != nil { return }

        fileHandle?.closeFile()
        fileHandle = nil
        currentDate = today

        let dir = logDirPath
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil
        )

        let filePath = "\(dir)/swift-\(today).log"
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: filePath)
        fileHandle?.seekToEndOfFile()
    }

    private func write(level: String, _ message: String) {
        queue.async { [self] in
            ensureFileHandle()
            let timestamp = timestampFormatter.string(from: Date())
            let line = "[\(timestamp)] [\(level)] \(message)\n"
            if let data = line.data(using: .utf8) {
                fileHandle?.write(data)
            }
        }
    }

    func info(_ message: String) { write(level: "INFO", message) }
    func warn(_ message: String) { write(level: "WARN", message) }
    func error(_ message: String) { write(level: "ERROR", message) }
    func ui(_ action: String) { write(level: "UI", action) }

    /// Synchronous write that blocks until the log line is flushed to disk.
    /// Use ONLY during app termination where async writes may be lost.
    func infoSync(_ message: String) {
        queue.sync { [self] in
            ensureFileHandle()
            let timestamp = timestampFormatter.string(from: Date())
            let line = "[\(timestamp)] [INFO] \(message)\n"
            if let data = line.data(using: .utf8) {
                fileHandle?.write(data)
                fileHandle?.synchronizeFile()
            }
        }
    }
}

let swiftLog = SwiftLogger.shared

// MARK: - UI Click Logged Helpers

/// 记录一次 UI 点击（或任意用户触发事件）后执行同步逻辑。
func logTap(_ action: String, _ block: () -> Void = {}) {
    swiftLog.ui(action)
    block()
}

/// 返回一个 async 闭包：先记录日志，再执行异步逻辑。
func logTapAsync(_ action: String, _ block: @escaping () async -> Void) -> () async -> Void {
    return {
        swiftLog.ui(action)
        await block()
    }
}
