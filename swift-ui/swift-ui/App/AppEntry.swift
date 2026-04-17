import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var appService: AppService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        swiftLog.info("应用启动 version=\(version) build=\(build)")

        AnalyticsService.initialize()
        AnalyticsService.trackFirstLaunchIfNeeded()
        AnalyticsService.track("app_started", with: ["version": version, "build": build])
    }

    func applicationWillTerminate(_ notification: Notification) {
        swiftLog.info("应用退出")
        appService?.terminateBackend()
    }
}

@main
struct swift_uiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var container = AppContainer()
    @State private var appService: AppService
    @State private var updaterViewModel = CheckForUpdatesViewModel()

    init() {
        let container = AppContainer()
        _container = State(initialValue: container)
        _appService = State(initialValue: AppService(container: container))
    }

    var body: some Scene {
        Window("AirTiz", id: "main") {
            ContentView(backend: appService, updaterViewModel: updaterViewModel, authService: container.authService)
                .preferredColorScheme(.light)
                .onAppear {
                    appDelegate.appService = appService
                    appService.startConnectionPolling()
                }
                .task {
                    await container.wireUpDependencies()
                    await container.authService.restoreSession()
                }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            TrayView(backend: appService)
                .onAppear { appDelegate.appService = appService }
        } label: {
            let proxyEnabled = appService.sysProxyEnabled || appService.tunEnabled
            let image = MenuBarRenderer.speedImage(
                up: AppService.formatSpeedCompact(appService.uploadSpeed),
                down: AppService.formatSpeedCompact(appService.downloadSpeed),
                proxyMode: appService.proxyMode,
                isProxyEnabled: proxyEnabled
            )
            Image(nsImage: image)
        }
        .menuBarExtraStyle(.window)
    }
}

enum MenuBarRenderer {
    static func speedImage(up: String, down: String, proxyMode: AppService.ProxyMode, isProxyEnabled: Bool = true) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]

        let upLine = "\(up) ↑" as NSString
        let downLine = "\(down) ↓" as NSString

        let upSize = upLine.size(withAttributes: attrs)
        let downSize = downLine.size(withAttributes: attrs)

        let dotRadius: CGFloat = 3
        let dotPadding: CGFloat = 2
        let lineSpacing: CGFloat = 1
        let textAreaWidth: CGFloat = 40
        let showsDot = isProxyEnabled && proxyMode != .direct
        let leadingInset: CGFloat = showsDot ? (dotRadius * 2 + dotPadding) : 0
        let width: CGFloat = leadingInset + textAreaWidth
        let height: CGFloat = 22

        let totalTextHeight = upSize.height + downSize.height + lineSpacing
        let yOffset = (height - totalTextHeight) / 2

        let dotColor: NSColor? = if showsDot {
            switch proxyMode {
            case .rule: .systemGreen
            case .global: .systemOrange
            case .direct: nil
            }
        } else {
            nil
        }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            if let dotColor {
                let dotX = dotRadius
                let dotY = height - dotRadius - 2
                let dotRect = NSRect(
                    x: dotX - dotRadius,
                    y: dotY - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
                dotColor.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            let textX = leadingInset
            upLine.draw(at: NSPoint(x: textX + (textAreaWidth - upSize.width), y: yOffset), withAttributes: attrs)
            downLine.draw(at: NSPoint(x: textX + (textAreaWidth - downSize.width), y: yOffset + upSize.height + lineSpacing), withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }
}
