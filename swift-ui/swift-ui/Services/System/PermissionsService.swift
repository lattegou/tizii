import Foundation
import OrderedCollections

actor PermissionsService {
    enum PermissionsError: LocalizedError {
        case invalidCoreName(String)
        case invalidCorePath

        var errorDescription: String? {
            switch self {
            case .invalidCoreName(let core):
                return "invalid core name: \(core)"
            case .invalidCorePath:
                return "invalid core path"
            }
        }
    }

    private let config: ConfigService
    private let sysProxy: SystemProxyService
    private let commandEnvironment = [
        "PATH": "/sbin:/usr/sbin:/usr/bin:/bin"
    ]
    private let allowedCores: Set<String> = ["mihomo", "mihomo-alpha", "mihomo-smart"]

    private var setPublicDNSRetryTask: Task<Void, Never>?
    private var recoverDNSRetryTask: Task<Void, Never>?

    init(config: ConfigService, sysProxy: SystemProxyService) {
        self.config = config
        self.sysProxy = sysProxy
    }

    deinit {
        setPublicDNSRetryTask?.cancel()
        recoverDNSRetryTask?.cancel()
    }

    func checkMihomoCorePermissions() async throws -> Bool {
        let appConfig = try await config.loadAppConfig()
        let core = appConfig["core"]?.stringValue ?? "mihomo"
        let corePath = try validatedCorePath(core: core)

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: corePath.path) else {
            return false
        }
        let ownerUID = (attrs[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let hasSuid = (mode & 0o4000) != 0
        return ownerUID == 0 && hasSuid
    }

    func requestTunPermissions() async throws {
        let hasPermissions = try await checkMihomoCorePermissions()
        if !hasPermissions {
            try await grantTunPermissions()
        }
    }

    func grantTunPermissions() async throws {
        let appConfig = try await config.loadAppConfig()
        let core = appConfig["core"]?.stringValue ?? "mihomo"
        let corePath = try validatedCorePath(core: core)
        let escapedPath = SystemSupport.shellEscapeSingleQuoted(corePath.path)
        let shell = "/usr/sbin/chown root:admin \(escapedPath) && /bin/chmod +sx \(escapedPath)"
        let script = "do shell script \"\(shell)\" with administrator privileges"
        _ = try SystemSupport.runCommand(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            environment: commandEnvironment
        )
    }

    func validateTunPermissionsOnStartup() async throws {
        let controlled = try await config.loadControledMihomoConfig()
        let tunEnabled = controlled["tun"]?["enable"]?.boolValue ?? false
        guard tunEnabled else { return }

        let hasPermissions = try await checkMihomoCorePermissions()
        guard !hasPermissions else { return }
        try await config.patchControledMihomoConfig(
            .dictionary([
                "tun": .dictionary(["enable": .bool(false)])
            ])
        )
        Task { @MainActor in
            swiftLog.warn("TUN disabled on startup due to missing permissions")
        }
    }

    // MARK: - DNS

    func setPublicDNS() async throws {
        let online = await SystemSupport.isOnline()
        guard online else {
            setPublicDNSRetryTask?.cancel()
            setPublicDNSRetryTask = Task {
                try? await Task.sleep(for: .seconds(5))
                try? await self.setPublicDNS()
            }
            return
        }

        setPublicDNSRetryTask?.cancel()
        setPublicDNSRetryTask = nil

        let appConfig = try await config.loadAppConfig(force: true)
        let originDNS = appConfig["originDNS"]?.stringValue
        if originDNS == nil || originDNS?.isEmpty == true {
            let original = try await getOriginDNS()
            try await config.patchAppConfig(
                .dictionary(["originDNS": .string(original)])
            )
            try await setDNS(originalDNSOrTarget: "223.5.5.5")
        }
    }

    func recoverDNS() async throws {
        let online = await SystemSupport.isOnline()
        guard online else {
            recoverDNSRetryTask?.cancel()
            recoverDNSRetryTask = Task {
                try? await Task.sleep(for: .seconds(5))
                try? await self.recoverDNS()
            }
            return
        }

        recoverDNSRetryTask?.cancel()
        recoverDNSRetryTask = nil

        let appConfig = try await config.loadAppConfig(force: true)
        guard let originDNS = appConfig["originDNS"]?.stringValue,
              !originDNS.isEmpty else {
            return
        }

        try await setDNS(originalDNSOrTarget: originDNS)
        try await config.patchAppConfig(
            .dictionary(["originDNS": .null])
        )
    }

    private func getOriginDNS() async throws -> String {
        let service = try await sysProxy.getDefaultService()
        let result = try SystemSupport.runCommand(
            executable: "/usr/sbin/networksetup",
            arguments: ["-getdnsservers", service],
            environment: commandEnvironment
        )
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if stdout.hasPrefix("There aren't any DNS Servers set on") {
            return "Empty"
        }
        return stdout.replacingOccurrences(of: "\n", with: " ")
    }

    private func setDNS(originalDNSOrTarget dns: String) async throws {
        let service = try await sysProxy.getDefaultService()
        do {
            try await sysProxy.setDNSViaHelper(service: service, dns: dns)
        } catch {
            let escapedService = service.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedDNS = dns.replacingOccurrences(of: "\"", with: "\\\"")
            let shell = "PATH=/sbin:/usr/sbin:/usr/bin:/bin networksetup -setdnsservers \"\(escapedService)\" \(escapedDNS)"
            let script = "do shell script \"\(shell)\" with administrator privileges"
            _ = try SystemSupport.runCommand(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script],
                environment: commandEnvironment
            )
        }
    }

    // MARK: - Validation

    private func validatedCorePath(core: String) throws -> URL {
        guard allowedCores.contains(core) else {
            throw PermissionsError.invalidCoreName(core)
        }
        let path = PathManager.mihomoCorePath(core: core)
        let normalized = path.standardizedFileURL.path
        let expected = PathManager.mihomoCoreDir.standardizedFileURL.path
        guard normalized.hasPrefix(expected + "/") else {
            throw PermissionsError.invalidCorePath
        }
        return path
    }
}
