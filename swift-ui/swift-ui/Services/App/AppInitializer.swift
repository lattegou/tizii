import Foundation
import OrderedCollections
import Darwin

actor AppInitializer {
    private let config: ConfigService
    private let sysProxy: SystemProxyService
    private let permissions: PermissionsService
    private let fileManager = FileManager.default
    private let commandEnvironment = [
        "PATH": "/sbin:/usr/sbin:/usr/bin:/bin"
    ]

    private var basicInitialized = false
    private var runtimeInitialized = false

    init(config: ConfigService, sysProxy: SystemProxyService, permissions: PermissionsService) {
        self.config = config
        self.sysProxy = sysProxy
        self.permissions = permissions
    }

    func initBasic() async throws {
        if basicInitialized { return }
        swiftLog.info("[Init] initBasic 开始")

        try fixDataDirPermissions()
        try initDirs()
        try initConfigFiles()
        try await migration()
        try syncSidecar()
        try copyGeoDatabases()
        try await cleanup()

        basicInitialized = true
        swiftLog.info("[Init] initBasic 完成")
    }

    func initRuntime() async {
        if runtimeInitialized { return }
        swiftLog.info("[Init] initRuntime 开始")

        do {
            let appConfig = try await config.loadAppConfig(force: true)
            if let originDNS = appConfig["originDNS"]?.stringValue,
               !originDNS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                swiftLog.info("[Init] 检测到 originDNS 残留, 恢复 DNS...")
                try await permissions.recoverDNS()
            }

            let sysProxyEnable = appConfig["sysProxy"]?["enable"]?.boolValue ?? false
            swiftLog.info("[Init] sysProxy.enable=\(sysProxyEnable)")
            if sysProxyEnable {
                try await sysProxy.triggerSysProxy(true)
            }
        } catch {
            swiftLog.warn("[Init] initRuntime 部分失败: \(error.localizedDescription)")
        }

        runtimeInitialized = true
        swiftLog.info("[Init] initRuntime 完成")
    }

    func validateAfterCoreReady() async {
        do {
            try await permissions.validateTunPermissionsOnStartup()
        } catch {
            // Keep consistent with backend behavior: validation failure should not crash startup.
        }
    }

    func prepareForTermination() async {
        swiftLog.info("[Init] prepareForTermination: 恢复 DNS 和系统代理")
        try? await permissions.recoverDNS()
        try? await sysProxy.triggerSysProxy(false)
        swiftLog.info("[Init] prepareForTermination 完成")
    }

    // MARK: - Init steps

    private func fixDataDirPermissions() throws {
        let dataDirPath = PathManager.dataDir.path
        guard fileManager.fileExists(atPath: dataDirPath) else { return }
        guard let attrs = try? fileManager.attributesOfItem(atPath: dataDirPath),
              let ownerUID = (attrs[.ownerAccountID] as? NSNumber)?.intValue else {
            return
        }
        if ownerUID != 0 || getuid() == 0 { return }

        let username = NSUserName()
        guard !username.isEmpty else { return }

        _ = try? SystemSupport.runCommand(
            executable: "/usr/sbin/chown",
            arguments: ["-R", "\(username):staff", dataDirPath],
            environment: commandEnvironment,
            allowFailure: true
        )
        _ = try? SystemSupport.runCommand(
            executable: "/bin/chmod",
            arguments: ["-R", "u+rwX", dataDirPath],
            environment: commandEnvironment,
            allowFailure: true
        )
    }

    private func initDirs() throws {
        let dirs = [
            PathManager.dataDir,
            PathManager.themesDir,
            PathManager.profilesDir,
            PathManager.overrideDir,
            PathManager.rulesDir,
            PathManager.mihomoWorkDir,
            PathManager.mihomoCoreDir,
            PathManager.logDir,
            PathManager.mihomoTestDir
        ]
        for dir in dirs {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func initConfigFiles() throws {
        try ensureFileIfMissing(PathManager.appConfigPath, content: ConfigTemplates.defaultAppConfigYAML)
        try ensureFileIfMissing(PathManager.profileConfigPath, content: ConfigTemplates.defaultProfileConfigYAML)
        try ensureFileIfMissing(PathManager.overrideConfigPath, content: ConfigTemplates.defaultOverrideConfigYAML)
        try ensureFileIfMissing(PathManager.profilePath(id: "default"), content: ConfigTemplates.defaultProfileYAML)
        try ensureFileIfMissing(PathManager.controledMihomoConfigPath, content: ConfigTemplates.defaultControledMihomoConfigYAML)
    }

    private func ensureFileIfMissing(_ path: URL, content: String) throws {
        if fileManager.fileExists(atPath: path.path) { return }
        try Data(content.utf8).write(to: path, options: .atomic)
    }

    // Single-entry sync point: bundled cores -> dataDir/sidecar.
    // Runs before any core process is started, so replacing a previously
    // privileged (root:admin + setuid) target on app upgrade is safe and
    // simply forces the user to re-grant TUN permission for the new build.
    private func syncSidecar() throws {
        swiftLog.info("[Init] syncSidecar 开始 target=\(PathManager.mihomoCoreDir.path)")
        let cores = ["mihomo", "mihomo-alpha", "mihomo-smart"]
        for core in cores {
            let bundled = PathManager.bundledCorePath(core: core)
            guard fileManager.fileExists(atPath: bundled.path) else {
                swiftLog.info("[Init] syncSidecar 跳过 core=\(core) (bundled 不存在)")
                continue
            }
            try PathManager.syncRunnableCore(core: core)
        }
        swiftLog.info("[Init] syncSidecar 完成")
    }

    private func copyGeoDatabases() throws {
        let files = ["country.mmdb", "geoip.metadb", "geoip.dat", "geosite.dat", "ASN.mmdb"]
        let critical = Set(["country.mmdb", "geoip.dat", "geosite.dat"])

        for filename in files {
            let source = PathManager.resourcesFilesDir.appendingPathComponent(filename, isDirectory: false)
            if !fileManager.fileExists(atPath: source.path) { continue }

            let targets = [
                PathManager.mihomoWorkDir.appendingPathComponent(filename, isDirectory: false),
                PathManager.mihomoTestDir.appendingPathComponent(filename, isDirectory: false)
            ]

            for target in targets {
                let shouldCopy = shouldCopyFile(source: source, target: target)
                if !shouldCopy { continue }

                do {
                    if fileManager.fileExists(atPath: target.path) {
                        try fileManager.removeItem(at: target)
                    }
                    try fileManager.copyItem(at: source, to: target)
                } catch {
                    if critical.contains(filename) {
                        throw error
                    }
                }
            }
        }
    }

    private func shouldCopyFile(source: URL, target: URL) -> Bool {
        guard fileManager.fileExists(atPath: target.path) else { return true }
        guard let sourceAttrs = try? fileManager.attributesOfItem(atPath: source.path),
              let targetAttrs = try? fileManager.attributesOfItem(atPath: target.path),
              let sourceMtime = sourceAttrs[.modificationDate] as? Date,
              let targetMtime = targetAttrs[.modificationDate] as? Date else {
            return true
        }
        return sourceMtime > targetMtime
    }

    private func cleanup() async throws {
        let dataFiles = (try? fileManager.contentsOfDirectory(atPath: PathManager.dataDir.path)) ?? []
        let logFiles = (try? fileManager.contentsOfDirectory(atPath: PathManager.logDir.path)) ?? []

        for file in dataFiles where file.hasSuffix(".exe") || file.hasSuffix(".pkg") || file.hasSuffix(".7z") {
            let path = PathManager.dataDir.appendingPathComponent(file, isDirectory: false)
            try? fileManager.removeItem(at: path)
        }

        let appConfig = try await config.loadAppConfig(force: true)
        let maxDays = max(appConfig["maxLogDays"]?.intValue ?? 7, 1)
        let maxAge = TimeInterval(maxDays * 24 * 60 * 60)
        let now = Date()

        for file in logFiles {
            guard let logDate = extractDateFromFilename(file) else { continue }
            if now.timeIntervalSince(logDate) > maxAge {
                let path = PathManager.logDir.appendingPathComponent(file, isDirectory: false)
                try? fileManager.removeItem(at: path)
            }
        }
    }

    // MARK: - Migration

    private func migration() async throws {
        try await migrateAppTheme()
        try await migrateEnvType()
        try await migrateTraySettings()
        try await migrateRemovePassword()
        try await migrateMihomoConfig()
    }

    private func migrateAppTheme() async throws {
        let app = try await config.loadAppConfig(force: true)
        let theme = app["appTheme"]?.stringValue ?? "system"
        if !["system", "light", "dark"].contains(theme) {
            try await config.patchAppConfig(.dictionary(["appTheme": .string("system")]))
        }
    }

    private func migrateEnvType() async throws {
        let app = try await config.loadAppConfig(force: true)
        if let envType = app["envType"]?.stringValue {
            try await config.patchAppConfig(.dictionary(["envType": .array([.string(envType)])]))
        }
    }

    private func migrateTraySettings() async throws {
        let app = try await config.loadAppConfig(force: true)
        let showFloatingWindow = app["showFloatingWindow"]?.boolValue ?? false
        let disableTray = app["disableTray"]?.boolValue ?? false
        if !showFloatingWindow && disableTray {
            try await config.patchAppConfig(.dictionary(["disableTray": .bool(false)]))
        }
    }

    private func migrateRemovePassword() async throws {
        let app = try await config.loadAppConfig(force: true)
        guard case .dictionary(var appDict) = app else { return }
        guard appDict["encryptedPassword"] != nil else { return }

        appDict.removeValue(forKey: "encryptedPassword")
        try await config.replaceAppConfig(.dictionary(appDict))
    }

    private func migrateMihomoConfig() async throws {
        let current = try await config.loadControledMihomoConfig(force: true)
        guard case .dictionary(var dict) = current else { return }

        var changed = false

        if dict.index(forKey: "skip-auth-prefixes") == nil {
            dict["skip-auth-prefixes"] = .array([.string("127.0.0.1/32"), .string("::1/128")])
            changed = true
        } else if let prefixes = dict["skip-auth-prefixes"]?.arrayValue {
            let values = prefixes.compactMap(\.stringValue)
            if values.count >= 1, values[0] == "127.0.0.1/32", !values.contains("::1/128") {
                var migrated = ["127.0.0.1/32", "::1/128"]
                if values.count > 1 {
                    migrated.append(contentsOf: values.dropFirst())
                }
                dict["skip-auth-prefixes"] = .array(migrated.map(YAMLValue.string))
                changed = true
            }
        }

        if dict.index(forKey: "authentication") == nil {
            dict["authentication"] = .array([])
            changed = true
        }
        if dict.index(forKey: "bind-address") == nil {
            dict["bind-address"] = .string("*")
            changed = true
        }
        if dict.index(forKey: "lan-allowed-ips") == nil {
            dict["lan-allowed-ips"] = .array([.string("0.0.0.0/0"), .string("::/0")])
            changed = true
        }
        if dict.index(forKey: "lan-disallowed-ips") == nil {
            dict["lan-disallowed-ips"] = .array([])
            changed = true
        }

        let tun = dict["tun"]?.dictionaryValue ?? OrderedDictionary<String, YAMLValue>()
        let tunDevice = tun["device"]?.stringValue
        if tunDevice == nil || tunDevice == "Mihomo" {
            var migratedTun = tun
            migratedTun["device"] = .string("utun1500")
            dict["tun"] = .dictionary(migratedTun)
            changed = true
        }

        if dict["external-controller-unix"] != nil {
            dict.removeValue(forKey: "external-controller-unix")
            changed = true
        }
        if dict["external-controller-pipe"] != nil {
            dict.removeValue(forKey: "external-controller-pipe")
            changed = true
        }
        let extCtrl = dict["external-controller"]
        if extCtrl == nil || extCtrl == .null {
            dict["external-controller"] = .string("")
            changed = true
        }

        if changed {
            try await config.replaceControledMihomoConfig(.dictionary(dict))
        }
    }

    // MARK: - Utils

    private func extractDateFromFilename(_ name: String) -> Date? {
        let pattern = #"\d{4}-\d{2}-\d{2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: (name as NSString).length)
        guard let match = regex.firstMatch(in: name, options: [], range: range) else { return nil }
        let dateText = (name as NSString).substring(with: match.range)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: dateText)
    }
}
