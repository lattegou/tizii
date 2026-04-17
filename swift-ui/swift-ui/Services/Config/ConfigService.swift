import Foundation
import OrderedCollections

actor ConfigService {
    private var appConfigCache: YAMLValue?
    private var controledMihomoConfigCache: YAMLValue?
    private var onControledConfigPatched: (@Sendable () async throws -> Void)?

    func loadAppConfig(force: Bool = false) async throws -> YAMLValue {
        if !force, let cached = appConfigCache {
            return cached
        }

        try PathManager.ensureBaseDirectories()

        let defaultConfig = try YAMLValue(yamlString: ConfigTemplates.defaultAppConfigYAML)
        let loaded = try loadOrInitialize(
            path: PathManager.appConfigPath,
            fallback: defaultConfig
        )
        let merged = deepMerge(defaultConfig, loaded)
        if merged != loaded {
            try writeYAML(merged, to: PathManager.appConfigPath)
        }
        appConfigCache = merged
        return merged
    }

    func patchAppConfig(_ patch: YAMLValue) async throws {
        var current = try await loadAppConfig()
        current = deepMerge(current, patch)
        try writeYAML(current, to: PathManager.appConfigPath)
        appConfigCache = current
    }

    func replaceAppConfig(_ config: YAMLValue) throws {
        try writeYAML(config, to: PathManager.appConfigPath)
        appConfigCache = config
    }

    func loadControledMihomoConfig(force: Bool = false) async throws -> YAMLValue {
        if !force, let cached = controledMihomoConfigCache {
            return cached
        }

        try PathManager.ensureBaseDirectories()

        let defaultConfig = try YAMLValue(yamlString: ConfigTemplates.defaultControledMihomoConfigYAML)
        let loaded = try loadOrInitialize(
            path: PathManager.controledMihomoConfigPath,
            fallback: defaultConfig
        )
        var merged = deepMerge(defaultConfig, loaded)
        merged = validatePortFields(merged, defaults: defaultConfig)
        if merged != loaded {
            try writeYAML(merged, to: PathManager.controledMihomoConfigPath)
        }
        controledMihomoConfigCache = merged
        return merged
    }

    func patchControledMihomoConfig(_ patch: YAMLValue) async throws {
        swiftLog.info("[Config] patchControledMihomoConfig patch=\(patch)")
        var current = try await loadControledMihomoConfig()
        let appConfig = try await loadAppConfig()
        let controlDns = appConfig["controlDns"]?.boolValue ?? true
        let controlSniff = appConfig["controlSniff"]?.boolValue ?? true

        let sanitizedPatch = stripInvalidPortFields(patch)

        if let hostsPatch = sanitizedPatch["hosts"], case .dictionary(var dict) = current {
            dict["hosts"] = hostsPatch
            current = .dictionary(dict)
        }
        if let policyPatch = sanitizedPatch["dns"]?["nameserver-policy"], case .dictionary(var dict) = current {
            var dns = dict["dns"]?.dictionaryValue ?? OrderedDictionary<String, YAMLValue>()
            dns["nameserver-policy"] = policyPatch
            dict["dns"] = .dictionary(dns)
            current = .dictionary(dict)
        }

        current = deepMerge(current, sanitizedPatch)

        if controlDns || controlSniff {
            let defaultConfig = try YAMLValue(yamlString: ConfigTemplates.defaultControledMihomoConfigYAML)

            if controlDns, let defaultDns = defaultConfig["dns"], case .dictionary(var dict) = current {
                let currentDns = dict["dns"] ?? .dictionary([:])
                dict["dns"] = deepMerge(defaultDns, currentDns)
                current = .dictionary(dict)
            }

            if controlSniff, case .dictionary(var dict) = current, dict["sniffer"] == nil,
               let defaultSniffer = defaultConfig["sniffer"] {
                dict["sniffer"] = defaultSniffer
                current = .dictionary(dict)
            }
        }

        try writeYAML(current, to: PathManager.controledMihomoConfigPath)
        controledMihomoConfigCache = current
        swiftLog.info("[Config] patchControledMihomoConfig 已写入, 触发 onControledConfigPatched")

        try await onControledConfigPatched?()
    }

    func replaceControledMihomoConfig(_ config: YAMLValue) async throws {
        swiftLog.info("[Config] replaceControledMihomoConfig")
        try writeYAML(config, to: PathManager.controledMihomoConfigPath)
        controledMihomoConfigCache = config
        try await onControledConfigPatched?()
    }

    func setOnControledConfigPatched(_ handler: (@Sendable () async throws -> Void)?) {
        onControledConfigPatched = handler
    }

    // MARK: - Port Validation

    nonisolated static let portFields = ["mixed-port", "socks-port", "port", "redir-port", "tproxy-port"]

    private nonisolated func stripInvalidPortFields(_ patch: YAMLValue) -> YAMLValue {
        guard case .dictionary(var dict) = patch else { return patch }
        for field in ConfigService.portFields {
            guard dict[field] != nil else { continue }
            if case .int = dict[field] { continue }
            dict.removeValue(forKey: field)
        }
        return .dictionary(dict)
    }

    private nonisolated func validatePortFields(_ config: YAMLValue, defaults: YAMLValue) -> YAMLValue {
        guard case .dictionary(var dict) = config,
              case .dictionary(let defaultDict) = defaults else { return config }
        for field in ConfigService.portFields {
            guard dict[field] != nil else { continue }
            if case .int = dict[field] { continue }
            dict[field] = defaultDict[field]
        }
        return .dictionary(dict)
    }

    // MARK: - Deep Merge

    nonisolated func deepMerge(_ target: YAMLValue, _ other: YAMLValue) -> YAMLValue {
        guard case .dictionary(var targetDict) = target,
              case .dictionary(let otherDict) = other else {
            return other
        }

        for (rawKey, value) in otherDict {
            if case .dictionary = value {
                if rawKey.hasSuffix("!") {
                    let key = trimWrap(String(rawKey.dropLast()))
                    targetDict[key] = value
                    continue
                }

                let key = trimWrap(rawKey)
                let existing = targetDict[key] ?? .dictionary([:])
                targetDict[key] = deepMerge(existing, value)
                continue
            }

            if case .array(let arrayValue) = value {
                if rawKey.hasPrefix("+") {
                    let key = trimWrap(String(rawKey.dropFirst()))
                    let current = targetDict[key]?.arrayValue ?? []
                    targetDict[key] = .array(arrayValue + current)
                    continue
                }

                if rawKey.hasSuffix("+") {
                    let key = trimWrap(String(rawKey.dropLast()))
                    let current = targetDict[key]?.arrayValue ?? []
                    targetDict[key] = .array(current + arrayValue)
                    continue
                }

                let key = trimWrap(rawKey)
                targetDict[key] = value
                continue
            }

            targetDict[rawKey] = value
        }

        return .dictionary(targetDict)
    }

    private nonisolated func trimWrap(_ key: String) -> String {
        if key.hasPrefix("<"), key.hasSuffix(">"), key.count >= 2 {
            return String(key.dropFirst().dropLast())
        }
        return key
    }

    private func loadOrInitialize(path: URL, fallback: YAMLValue) throws -> YAMLValue {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            try writeYAML(fallback, to: path)
            return fallback
        }

        let data = try Data(contentsOf: path)
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try writeYAML(fallback, to: path)
            return fallback
        }
        return try YAMLValue(yamlString: text)
    }

    private func writeYAML(_ value: YAMLValue, to path: URL) throws {
        let yaml = try value.toYAMLString()
        let data = Data(yaml.utf8)
        try data.write(to: path, options: .atomic)
    }
}
