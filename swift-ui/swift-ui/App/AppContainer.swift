import Foundation

@MainActor
final class AppContainer {
    let endpointHolder: ControllerEndpointHolder
    let configService: ConfigService
    let profileService: ProfileService
    let profileGenerator: ProfileGenerator
    let mihomoAPI: MihomoAPIClient
    let processManager: MihomoProcessManager
    let systemProxyService: SystemProxyService
    let permissionsService: PermissionsService
    let appInitializer: AppInitializer
    let ssidMonitor: SSIDMonitor
    let logService: LogService
    let authService: AuthService

    init() {
        let endpointHolder = ControllerEndpointHolder()
        let configService = ConfigService()
        let profileService = ProfileService(config: configService)
        let profileGenerator = ProfileGenerator(config: configService, profile: profileService)
        let systemProxyService = SystemProxyService(config: configService)
        let permissionsService = PermissionsService(config: configService, sysProxy: systemProxyService)
        let mihomoAPI = MihomoAPIClient(
            endpointHolder: endpointHolder,
            generator: profileGenerator,
            config: configService
        )
        let processManager = MihomoProcessManager(
            config: configService,
            generator: profileGenerator,
            endpointHolder: endpointHolder,
            api: mihomoAPI,
            permissions: permissionsService
        )
        let appInitializer = AppInitializer(
            config: configService,
            sysProxy: systemProxyService,
            permissions: permissionsService
        )
        let ssidMonitor = SSIDMonitor(config: configService, sysProxy: systemProxyService)
        let logService = LogService()
        let authService = AuthService()

        self.endpointHolder = endpointHolder
        self.configService = configService
        self.profileService = profileService
        self.profileGenerator = profileGenerator
        self.mihomoAPI = mihomoAPI
        self.processManager = processManager
        self.systemProxyService = systemProxyService
        self.permissionsService = permissionsService
        self.appInitializer = appInitializer
        self.ssidMonitor = ssidMonitor
        self.logService = logService
        self.authService = authService
    }

    func wireUpDependencies() async {
        let processManager = self.processManager
        let profileGenerator = self.profileGenerator

        await profileService.setCallbacks(
            restartCore: { try await processManager.restartCore() },
            reloadCurrentProfile: { try await profileGenerator.generate() }
        )

        await configService.setOnControledConfigPatched {
            try await profileGenerator.generate()
        }
    }
}
