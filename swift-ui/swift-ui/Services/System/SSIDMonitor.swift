import Foundation
import CoreWLAN
import OrderedCollections

actor SSIDMonitor {
    typealias ModeSwitchHandler = @Sendable @MainActor (String) async -> Void

    private let config: ConfigService
    private let sysProxy: SystemProxyService
    private let interval: Duration
    private let commandEnvironment = [
        "PATH": "/sbin:/usr/sbin:/usr/bin:/bin"
    ]

    private var monitorTask: Task<Void, Never>?
    private var lastSSID: String?
    private var modeSwitchHandler: ModeSwitchHandler?

    init(config: ConfigService, sysProxy: SystemProxyService, interval: Duration = .seconds(30)) {
        self.config = config
        self.sysProxy = sysProxy
        self.interval = interval
    }

    deinit {
        monitorTask?.cancel()
    }

    func setModeSwitchHandler(_ handler: ModeSwitchHandler?) {
        modeSwitchHandler = handler
    }

    func start() {
        monitorTask?.cancel()
        monitorTask = Task {
            await checkSSID()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                await checkSSID()
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func checkSSID() async {
        do {
            let appConfig = try await config.loadAppConfig(force: true)
            let pauseSSID = stringArray(from: appConfig["pauseSSID"])
            if pauseSSID.isEmpty { return }

            let currentSSID = await currentSSIDValue()
            if currentSSID == lastSSID { return }
            lastSSID = currentSSID

            let targetMode = (currentSSID != nil && pauseSSID.contains(currentSSID!)) ? "direct" : "rule"
            try await config.patchControledMihomoConfig(
                .dictionary(OrderedDictionary(uniqueKeysWithValues: [
                    ("mode", .string(targetMode))
                ]))
            )
            if let modeSwitchHandler {
                await modeSwitchHandler(targetMode)
            }
        } catch {
            // Keep parity with backend: SSID check should be best-effort and never crash.
        }
    }

    private func currentSSIDValue() async -> String? {
        if let ssid = CWWiFiClient.shared().interface()?.ssid(),
           !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ssid
        }

        if let ssid = ssidByAirport() {
            return ssid
        }
        return await ssidByNetworkSetup()
    }

    private func ssidByAirport() -> String? {
        let airportPath = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
        guard FileManager.default.isExecutableFile(atPath: airportPath) else { return nil }
        let result = try? SystemSupport.runCommand(
            executable: airportPath,
            arguments: ["-I"],
            environment: commandEnvironment,
            allowFailure: true
        )
        guard let output = result?.stdout, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WARNING") {
            return nil
        }
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SSID:"),
               let value = line.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func ssidByNetworkSetup() async -> String? {
        guard let service = try? await sysProxy.getDefaultService() else { return nil }
        let result = try? SystemSupport.runCommand(
            executable: "/usr/sbin/networksetup",
            arguments: ["-listpreferredwirelessnetworks", service],
            environment: commandEnvironment,
            allowFailure: true
        )
        guard let output = result?.stdout else { return nil }
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, lines[0].hasPrefix("Preferred networks on") else { return nil }
        return lines[1]
    }

    private func stringArray(from value: YAMLValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}
