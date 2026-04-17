import Foundation
import Network

enum SystemSupportError: LocalizedError {
    case commandFailed(executable: String, code: Int32, stderr: String)
    case invalidUTF8
    case onlineCheckTimeout

    var errorDescription: String? {
        switch self {
        case .commandFailed(let executable, let code, let stderr):
            if stderr.isEmpty {
                return "command failed: \(executable) (exit \(code))"
            }
            return "command failed: \(executable) (exit \(code)): \(stderr)"
        case .invalidUTF8:
            return "invalid utf8 output"
        case .onlineCheckTimeout:
            return "online check timeout"
        }
    }
}

struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum SystemSupport {
    nonisolated static func runCommand(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        allowFailure: Bool = false
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard let stdout = String(data: stdoutData, encoding: .utf8),
              let stderr = String(data: stderrData, encoding: .utf8) else {
            throw SystemSupportError.invalidUTF8
        }

        let result = CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        if !allowFailure, result.exitCode != 0 {
            throw SystemSupportError.commandFailed(
                executable: executable,
                code: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    nonisolated static func shellEscapeSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func isOnline(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let monitor = NWPathMonitor()
                    let queue = DispatchQueue(label: "airtiz.net.monitor")
                    monitor.pathUpdateHandler = { path in
                        continuation.resume(returning: path.status == .satisfied)
                        monitor.cancel()
                    }
                    monitor.start(queue: queue)
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
