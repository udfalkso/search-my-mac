import Foundation
import Sparkle

enum UpdateCheckFrequency: TimeInterval, CaseIterable, Identifiable {
    case daily = 86_400
    case weekly = 604_800
    case monthly = 2_629_800

    var id: TimeInterval { rawValue }

    var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    static func closest(to interval: TimeInterval) -> Self {
        allCases.min { abs($0.rawValue - interval) < abs($1.rawValue - interval) } ?? .daily
    }
}

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    private lazy var standardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var checkFrequency = UpdateCheckFrequency.daily
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isCheckingForUpdates = false

    override init() {
        super.init()
        _ = standardUpdaterController
        refresh()

        // Sparkle finishes starting on the next run-loop pass.
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    var installedVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
        guard let build, build != shortVersion else { return shortVersion }
        return "\(shortVersion) (\(build))"
    }

    func refresh() {
        let updater = standardUpdaterController.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        checkFrequency = .closest(to: updater.updateCheckInterval)
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        canCheckForUpdates = updater.canCheckForUpdates && !isCheckingForUpdates
    }

    func checkForUpdates() {
        guard standardUpdaterController.updater.canCheckForUpdates else {
            refresh()
            return
        }

        isCheckingForUpdates = true
        canCheckForUpdates = false
        standardUpdaterController.checkForUpdates(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        isCheckingForUpdates = false
        refresh()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        standardUpdaterController.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
        if !enabled {
            setAutomaticallyDownloadsUpdates(false)
        }
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        standardUpdaterController.updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloadsUpdates = standardUpdaterController.updater.automaticallyDownloadsUpdates
    }

    func setCheckFrequency(_ frequency: UpdateCheckFrequency) {
        standardUpdaterController.updater.updateCheckInterval = frequency.rawValue
        checkFrequency = frequency
    }
}
