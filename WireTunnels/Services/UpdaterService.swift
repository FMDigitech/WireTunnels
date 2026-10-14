import Foundation
import Combine
import Sparkle

@MainActor
final class UpdaterService: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    private var subscriptions = Set<AnyCancellable>()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = value
                }
            }
            .store(in: &subscriptions)
        updaterController.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    self?.automaticallyChecksForUpdates = value
                }
            }
            .store(in: &subscriptions)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
