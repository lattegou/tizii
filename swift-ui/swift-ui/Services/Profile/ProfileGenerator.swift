import Foundation
import OrderedCollections

actor ProfileGenerator {
    private let config: ConfigService
    private let profile: ProfileService

    private(set) var runtimeConfig: YAMLValue = .dictionary([:])

    init(config: ConfigService, profile: ProfileService) {
        self.config = config
        self.profile = profile
    }

    @discardableResult
    func generate() async throws -> URL {
        swiftLog.info("[ProfileGen] generate() 开始")
        let profileConfig = try await profile.getProfileConfig(force: true)
        let currentId = profileConfig.current
        let appConfig = try await config.loadAppConfig()
        var controlled = try await config.loadControledMihomoConfig()
        let currentProfile = try await profile.getProfileYAML(id: currentId)

        let controlDns = appConfig["controlDns"]?.boolValue ?? true
        let controlSniff = appConfig["controlSniff"]?.boolValue ?? true
        let useNameserverPolicy = appConfig["useNameserverPolicy"]?.boolValue ?? false
        let diffWorkDir = appConfig["diffWorkDir"]?.boolValue ?? false

        swiftLog.info("[ProfileGen] profileId=\(currentId ?? "nil") controlDns=\(controlDns) controlSniff=\(controlSniff) diffWorkDir=\(diffWorkDir)")

        controlled = normalizeControlledConfig(
            controlled,
            controlDns: controlDns,
            controlSniff: controlSniff,
            useNameserverPolicy: useNameserverPolicy
        )

        var merged = config.deepMerge(currentProfile, controlled)
        merged = try await applyRulePatchIfNeeded(to: merged, profileId: currentId)
        merged = normalizeLogLevel(in: merged)

        let mode = merged["mode"]?.stringValue ?? "?"
        let mixedPort = merged["mixed-port"]?.intValue ?? 0
        let tunEnabled = merged["tun"]?["enable"]?.boolValue ?? false
        let proxyGroupCount = merged["proxy-groups"]?.arrayValue?.count ?? 0
        let rulesCount = merged["rules"]?.arrayValue?.count ?? 0
        swiftLog.info("[ProfileGen] 合并结果: mode=\(mode) mixed-port=\(mixedPort) tun=\(tunEnabled) proxy-groups=\(proxyGroupCount) rules=\(rulesCount)")

        runtimeConfig = merged

        if diffWorkDir {
            try prepareProfileWorkDir(currentId: currentId)
        }
        let target = diffWorkDir ? PathManager.mihomoWorkConfigPath(id: currentId) : PathManager.mihomoWorkConfigPath(id: "work")
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let yaml = try merged.toYAMLString()
        try Data(yaml.utf8).write(to: target, options: .atomic)
        swiftLog.info("[ProfileGen] 配置已写入 \(target.lastPathComponent) (\(yaml.utf8.count) bytes)")
        return target
    }

    // MARK: - Rules

    private func applyRulePatchIfNeeded(to profile: YAMLValue, profileId: String?) async throws -> YAMLValue {
        let id = profileId ?? "default"
        let path = PathManager.rulePath(id: id)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return profile
        }

        let text = try String(contentsOf: path, encoding: .utf8)
        let parsed = try YAMLValue(yamlString: text)
        guard let rulePatch = parsed.dictionaryValue else {
            return profile
        }

        var root = profile.dictionaryValue ?? [:]
        var rules = (root["rules"]?.arrayValue ?? []).compactMap { $0.stringValue }

        if let prepend = rulePatch["prepend"]?.arrayValue?.compactMap(\.stringValue), !prepend.isEmpty {
            let result = processRulesWithOffset(prepend, currentRules: rules, isAppend: false)
            rules = result.normalRules + result.insertRules
        }
        if let append = rulePatch["append"]?.arrayValue?.compactMap(\.stringValue), !append.isEmpty {
            let result = processRulesWithOffset(append, currentRules: rules, isAppend: true)
            rules = result.insertRules + result.normalRules
        }
        if let deletes = rulePatch["delete"]?.arrayValue?.compactMap(\.stringValue), !deletes.isEmpty {
            let deleteSet = Set(deletes)
            rules.removeAll(where: { deleteSet.contains($0) })
        }

        root["rules"] = .array(rules.map(YAMLValue.string))
        return .dictionary(root)
    }

    private func processRulesWithOffset(
        _ ruleStrings: [String],
        currentRules: [String],
        isAppend: Bool
    ) -> (normalRules: [String], insertRules: [String]) {
        var normalRules: [String] = []
        var rules = currentRules

        for rule in ruleStrings {
            let parts = rule.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let firstPartIsNumber = parts.count >= 3 && Int(parts[0].trimmingCharacters(in: .whitespaces)) != nil

            if firstPartIsNumber, let offset = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                let insertedRule = parts.dropFirst().joined(separator: ",")
                if isAppend {
                    let insertPosition = max(0, rules.count - min(offset, rules.count))
                    rules.insert(insertedRule, at: insertPosition)
                } else {
                    let insertPosition = min(offset, rules.count)
                    rules.insert(insertedRule, at: insertPosition)
                }
            } else {
                normalRules.append(rule)
            }
        }

        return (normalRules, rules)
    }

    // MARK: - Controlled Config

    private func normalizeControlledConfig(
        _ controlled: YAMLValue,
        controlDns: Bool,
        controlSniff: Bool,
        useNameserverPolicy: Bool
    ) -> YAMLValue {
        guard var dict = controlled.dictionaryValue else {
            return controlled
        }

        if !controlDns {
            dict["dns"] = nil
            dict["hosts"] = nil
        } else if !useNameserverPolicy, var dns = dict["dns"]?.dictionaryValue {
            dns["nameserver-policy"] = nil
            dict["dns"] = .dictionary(dns)
        }

        if !controlSniff {
            dict["sniffer"] = nil
        }

        return .dictionary(dict)
    }

    private func normalizeLogLevel(in profile: YAMLValue) -> YAMLValue {
        guard var dict = profile.dictionaryValue else {
            return profile
        }
        let logLevel = dict["log-level"]?.stringValue
        if logLevel != "info", logLevel != "debug" {
            dict["log-level"] = .string("info")
        }
        return .dictionary(dict)
    }

    // MARK: - Work Dir

    private func prepareProfileWorkDir(currentId: String?) throws {
        let targetDir = PathManager.mihomoProfileWorkDir(id: currentId)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let sourceDir = PathManager.mihomoWorkDir
        let files = ["country.mmdb", "geoip.metadb", "geoip.dat", "geosite.dat", "ASN.mmdb"]
        for file in files {
            let source = sourceDir.appendingPathComponent(file, isDirectory: false)
            let target = targetDir.appendingPathComponent(file, isDirectory: false)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if try shouldCopyFile(source: source, target: target) {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
    }

    private func shouldCopyFile(source: URL, target: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: target.path) else { return true }
        let sourceAttr = try FileManager.default.attributesOfItem(atPath: source.path)
        let targetAttr = try FileManager.default.attributesOfItem(atPath: target.path)
        guard
            let sourceDate = sourceAttr[.modificationDate] as? Date,
            let targetDate = targetAttr[.modificationDate] as? Date
        else { return true }
        return sourceDate > targetDate
    }
}
