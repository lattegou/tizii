import Foundation

enum PathManager {
    nonisolated static let appName = "airtiz"

    nonisolated static var homeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated static var dataDir: URL {
        homeDir
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true)
    }

    nonisolated static var resourcesDir: URL {
        URL(fileURLWithPath: Bundle.main.resourcePath ?? "", isDirectory: true)
    }

    nonisolated static var resourcesFilesDir: URL {
        resourcesDir.appendingPathComponent("files", isDirectory: true)
    }

    nonisolated static var bundledCoreDir: URL {
        resourcesDir.appendingPathComponent("sidecar", isDirectory: true)
    }

    nonisolated static func bundledCorePath(core: String) -> URL {
        bundledCoreDir.appendingPathComponent(core, isDirectory: false)
    }

    nonisolated static var mihomoCoreDir: URL {
        dataDir.appendingPathComponent("sidecar", isDirectory: true)
    }

    nonisolated static func mihomoCorePath(core: String) -> URL {
        mihomoCoreDir.appendingPathComponent(core, isDirectory: false)
    }

    /// Sync core binary from app bundle to dataDir/sidecar if source differs.
    ///
    /// IMPORTANT: This performs file I/O (remove/copy) and MUST only be called from
    /// the single-entry sync point (`AppInitializer.syncSidecar`) before the core
    /// process is started. Calling it while mihomo is running can replace a
    /// privileged (root:admin + setuid) binary with an unprivileged copy, breaking
    /// TUN permissions. Runtime code paths should use `mihomoCorePath(core:)`
    /// instead, which is side-effect free.
    @discardableResult
    nonisolated static func syncRunnableCore(core: String) throws -> URL {
        let source = bundledCorePath(core: core)
        let target = mihomoCorePath(core: core)
        try ensureDirectory(mihomoCoreDir)

        guard FileManager.default.fileExists(atPath: source.path) else {
            swiftLog.warn("[Sidecar] bundled core 不存在, skip core=\(core) path=\(source.path)")
            return target
        }

        let needsCopy: Bool
        var reason = "target missing"
        var sourceSize = -1
        if !FileManager.default.fileExists(atPath: target.path) {
            needsCopy = true
            let sourceAttrs = try? FileManager.default.attributesOfItem(atPath: source.path)
            sourceSize = (sourceAttrs?[.size] as? Int) ?? -1
        } else {
            let sourceAttrs = try FileManager.default.attributesOfItem(atPath: source.path)
            let targetAttrs = try FileManager.default.attributesOfItem(atPath: target.path)
            sourceSize = (sourceAttrs[.size] as? Int) ?? -1
            let targetSize = (targetAttrs[.size] as? Int) ?? -2
            let sourceMtime = (sourceAttrs[.modificationDate] as? Date) ?? .distantPast
            let targetMtime = (targetAttrs[.modificationDate] as? Date) ?? .distantPast
            if sourceSize != targetSize {
                reason = "size mismatch(\(sourceSize) vs \(targetSize))"
                needsCopy = true
            } else if sourceMtime != targetMtime {
                reason = "mtime mismatch(\(sourceMtime) vs \(targetMtime))"
                needsCopy = true
            } else {
                needsCopy = false
            }
        }

        if needsCopy {
            swiftLog.info("[Sidecar] 同步 core=\(core) size=\(sourceSize) reason=\(reason) src=\(source.path) dst=\(target.path)")
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
            swiftLog.info("[Sidecar] 同步完成 core=\(core)")
        } else {
            swiftLog.info("[Sidecar] 跳过同步 core=\(core) (目标与源一致)")
        }

        return target
    }

    nonisolated static var appConfigPath: URL {
        dataDir.appendingPathComponent("config.yaml", isDirectory: false)
    }

    nonisolated static var controledMihomoConfigPath: URL {
        dataDir.appendingPathComponent("mihomo.yaml", isDirectory: false)
    }

    nonisolated static var profileConfigPath: URL {
        dataDir.appendingPathComponent("profile.yaml", isDirectory: false)
    }

    nonisolated static var overrideConfigPath: URL {
        dataDir.appendingPathComponent("override.yaml", isDirectory: false)
    }

    nonisolated static var profilesDir: URL {
        dataDir.appendingPathComponent("profiles", isDirectory: true)
    }

    nonisolated static func profilePath(id: String) -> URL {
        profilesDir.appendingPathComponent("\(id).yaml", isDirectory: false)
    }

    nonisolated static var overrideDir: URL {
        dataDir.appendingPathComponent("override", isDirectory: true)
    }

    nonisolated static var mihomoWorkDir: URL {
        dataDir.appendingPathComponent("work", isDirectory: true)
    }

    nonisolated static var mihomoTestDir: URL {
        dataDir.appendingPathComponent("test", isDirectory: true)
    }

    nonisolated static func mihomoProfileWorkDir(id: String?) -> URL {
        mihomoWorkDir.appendingPathComponent(id ?? "default", isDirectory: true)
    }

    nonisolated static func mihomoWorkConfigPath(id: String?) -> URL {
        if id == "work" {
            return mihomoWorkDir.appendingPathComponent("config.yaml", isDirectory: false)
        }
        return mihomoProfileWorkDir(id: id).appendingPathComponent("config.yaml", isDirectory: false)
    }

    nonisolated static var logDir: URL {
        dataDir.appendingPathComponent("logs", isDirectory: true)
    }

    nonisolated static var themesDir: URL {
        dataDir.appendingPathComponent("themes", isDirectory: true)
    }

    nonisolated static var rulesDir: URL {
        dataDir.appendingPathComponent("rules", isDirectory: true)
    }

    nonisolated static func rulePath(id: String) -> URL {
        rulesDir.appendingPathComponent("\(id).yaml", isDirectory: false)
    }

    nonisolated static func ensureDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    nonisolated static func ensureBaseDirectories() throws {
        try ensureDirectory(dataDir)
        try ensureDirectory(mihomoCoreDir)
        try ensureDirectory(profilesDir)
        try ensureDirectory(overrideDir)
        try ensureDirectory(mihomoWorkDir)
        try ensureDirectory(mihomoTestDir)
        try ensureDirectory(logDir)
        try ensureDirectory(themesDir)
        try ensureDirectory(rulesDir)
    }
}
