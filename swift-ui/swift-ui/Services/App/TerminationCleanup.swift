import Foundation
import Darwin

/// Purely synchronous termination cleanup.
///
/// During `applicationWillTerminate`, Swift Concurrency's cooperative thread
/// pool stops scheduling new tasks, so `Task.detached` blocks never execute.
/// This module uses only POSIX sockets, `Process`, and `FileManager` — none
/// of which depend on the Swift Concurrency runtime.
enum TerminationCleanup {

    private static let helperSocketPath = "/tmp/mihomo-party-helper.sock"
    private static let commandEnv = ["PATH": "/sbin:/usr/sbin:/usr/bin:/bin"]

    // MARK: - Entry Point

    static func perform() {
        swiftLog.infoSync("[Terminate] 开始同步清理")
        disableSystemProxy()
        recoverDNS()
        killMihomoProcess()
        swiftLog.infoSync("[Terminate] 同步清理完成")
    }

    // MARK: - System Proxy

    private static func disableSystemProxy() {
        if FileManager.default.fileExists(atPath: helperSocketPath) {
            if let resp = syncHelperHTTP(method: "GET", path: "/off"),
               (200..<300).contains(resp.statusCode) {
                swiftLog.infoSync("[Terminate] helper /off 成功: status=\(resp.statusCode)")
                return
            }
        }

        do {
            let service = try resolveDefaultNetworkService()
            for args in [
                ["-setwebproxystate", service, "off"],
                ["-setsecurewebproxystate", service, "off"],
                ["-setautoproxystate", service, "off"],
                ["-setsocksfirewallproxystate", service, "off"]
            ] {
                _ = try SystemSupport.runCommand(
                    executable: "/usr/sbin/networksetup",
                    arguments: args,
                    environment: commandEnv
                )
            }
            swiftLog.infoSync("[Terminate] networksetup 关闭代理完成")
        } catch {
            swiftLog.infoSync("[Terminate] 关闭代理失败: \(error.localizedDescription)")
        }
    }

    // MARK: - DNS Recovery

    private static func recoverDNS() {
        do {
            guard let data = FileManager.default.contents(atPath: PathManager.appConfigPath.path),
                  let content = String(data: data, encoding: .utf8) else { return }

            guard let originDNS = extractYAMLStringValue(key: "originDNS", from: content),
                  !originDNS.isEmpty else { return }

            let service = try resolveDefaultNetworkService()

            if FileManager.default.fileExists(atPath: helperSocketPath) {
                let escapedService = jsonEscape(service)
                let escapedDNS = jsonEscape(originDNS)
                let body = "{\"service\":\"\(escapedService)\",\"dns\":\"\(escapedDNS)\"}"
                if let resp = syncHelperHTTP(method: "POST", path: "/dns", body: body),
                   (200..<300).contains(resp.statusCode) {
                    swiftLog.infoSync("[Terminate] helper DNS 恢复成功")
                    return
                }
            }

            let dnsArgs: [String]
            if originDNS == "Empty" {
                dnsArgs = ["-setdnsservers", service, "Empty"]
            } else {
                dnsArgs = ["-setdnsservers", service] + originDNS.split(separator: " ").map(String.init)
            }
            _ = try SystemSupport.runCommand(
                executable: "/usr/sbin/networksetup",
                arguments: dnsArgs,
                environment: commandEnv
            )
            swiftLog.infoSync("[Terminate] networksetup DNS 恢复完成")
        } catch {
            swiftLog.infoSync("[Terminate] DNS 恢复失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Kill mihomo

    private static func killMihomoProcess() {
        let result = try? SystemSupport.runCommand(
            executable: "/usr/bin/pgrep",
            arguments: ["-f", "mihomo.*-ext-ctl"],
            environment: commandEnv,
            allowFailure: true
        )
        guard let stdout = result?.stdout else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for line in stdout.split(separator: "\n") {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)),
                  pid != myPID else { continue }
            kill(pid, SIGTERM)
        }
        swiftLog.infoSync("[Terminate] mihomo 进程已发送 SIGTERM")
    }

    // MARK: - Synchronous Unix-Socket HTTP (POSIX)

    private struct SimpleHTTPResponse {
        let statusCode: Int
        let body: String
    }

    private static func syncHelperHTTP(
        method: String,
        path: String,
        body: String? = nil
    ) -> SimpleHTTPResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            helperSocketPath.utf8CString.withUnsafeBufferPointer { src in
                let count = min(src.count, dst.count)
                dst.copyBytes(from: UnsafeRawBufferPointer(src).prefix(count))
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        var request = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let body {
            request += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        } else {
            request += "\r\n"
        }

        let requestBytes = Array(request.utf8)
        let sent = requestBytes.withUnsafeBufferPointer { buf in
            Darwin.send(fd, buf.baseAddress!, buf.count, 0)
        }
        guard sent == requestBytes.count else { return nil }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            responseData.append(contentsOf: buffer[..<n])
        }

        guard let text = String(data: responseData, encoding: .utf8) else { return nil }
        guard let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
        let headerPart = String(text[..<headerEnd.lowerBound])
        let bodyPart = String(text[headerEnd.upperBound...])

        let statusLine = headerPart.components(separatedBy: "\r\n").first ?? ""
        let tokens = statusLine.split(separator: " ", maxSplits: 2)
        guard tokens.count >= 2, let code = Int(tokens[1]) else { return nil }

        return SimpleHTTPResponse(statusCode: code, body: bodyPart)
    }

    // MARK: - Network Service Resolution

    private static func resolveDefaultNetworkService() throws -> String {
        let routeResult = try SystemSupport.runCommand(
            executable: "/sbin/route",
            arguments: ["-n", "get", "default"],
            environment: commandEnv
        )
        var device: String?
        for line in routeResult.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                let value = trimmed.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { device = value; break }
            }
        }
        guard let device else {
            throw SystemSupportError.commandFailed(executable: "route", code: 1, stderr: "no default interface")
        }

        let orderResult = try SystemSupport.runCommand(
            executable: "/usr/sbin/networksetup",
            arguments: ["-listnetworkserviceorder"],
            environment: commandEnv
        )
        let blocks = orderResult.stdout.components(separatedBy: "\n\n")
        guard let block = blocks.first(where: { $0.contains("Device: \(device)") }) else {
            throw SystemSupportError.commandFailed(executable: "networksetup", code: 1, stderr: "service not found for \(device)")
        }
        for line in block.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("("), let closing = trimmed.firstIndex(of: ")") else { continue }
            let name = trimmed[trimmed.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        throw SystemSupportError.commandFailed(executable: "networksetup", code: 1, stderr: "service name not parsed")
    }

    // MARK: - Helpers

    private static func extractYAMLStringValue(key: String, from yaml: String) -> String? {
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            var value = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if value == "null" || value == "~" || value.isEmpty { return nil }
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
