import Combine
import Observation
import Sparkle

@Observable
@MainActor
final class CheckForUpdatesViewModel {
    var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    let updater: SPUUpdater
    private var canCheckCancellable: AnyCancellable?

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updater = controller.updater

        self.canCheckCancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }

        self.canCheckForUpdates = updater.canCheckForUpdates
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
