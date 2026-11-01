// BrowserUpdateController.swift

import Combine
import Foundation
import Network
import Sparkle

// MARK: - BrowserUpdateController

@MainActor final class BrowserUpdateController: NSObject, ObservableObject {
    // MARK: Internal

    @Published private(set) var toast: BrowserUpdateToast?

    // MARK: Private

    private let preferencesStore: BrowserUserPreferencesStore
    private let pathQueue = DispatchQueue(label: "com.levochkaa.OpenArc.update-network-path")
    private var updaterController: SPUStandardUpdaterController?
    private var pathMonitor: NWPathMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    private var hasAppliedAutomaticUpdatePolicy = false
    private var isWiFiAvailable = false
    private var isAutomaticUpdatePolicyActive = false
    private var immediateInstallHandler: (() -> Void)?

    var automaticUpdatesEnabled: Bool {
        get { preferencesStore.automaticUpdatesEnabled }
        set { preferencesStore.automaticUpdatesEnabled = newValue }
    }

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    /// Only the server can serve a second channel.
    private var updateChannel: BrowserUpdateChannel {
        BrowserHostedService.isEnabled ? preferencesStore.updateChannel : .stable
    }

    private var configuredFeedURL: URL? {
        guard
            let feedURLString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let feedURL = URL(string: feedURLString),
            ["http", "https"].contains(feedURL.scheme?.lowercased() ?? "")
        else {
            return nil
        }

        return feedURL
    }

    private var selectedFeedURLString: String? {
        guard let configuredFeedURL else {
            return nil
        }

        guard updateChannel == .beta else {
            return configuredFeedURL.absoluteString
        }

        var components = URLComponents(url: configuredFeedURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "channel" }
        queryItems.append(URLQueryItem(name: "channel", value: "beta"))
        components?.queryItems = queryItems
        return components?.url?.absoluteString
    }

    private var isSparkleConfigured: Bool {
        guard
            let selectedFeedURLString,
            let feedURL = URL(string: selectedFeedURLString),
            ["http", "https"].contains(feedURL.scheme?.lowercased() ?? ""),
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        return !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publicKey.contains("$(")
    }

    init(preferencesStore: BrowserUserPreferencesStore) {
        self.preferencesStore = preferencesStore
        super.init()
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil,
        )
    }

    deinit {
        pathMonitor?.cancel()
    }

    func start() {
        guard !hasStarted else {
            return
        }

        guard isSparkleConfigured else {
            NSLog("OpenArc updates disabled: missing Sparkle feed URL or public EdDSA key.")
            return
        }

        hasStarted = true
        startNetworkPathMonitor()
        observePreferences()
        applyAutomaticUpdatePolicy()

        do {
            try updaterController?.updater.start()
        } catch {
            NSLog("OpenArc updates disabled: \(error.localizedDescription)")
        }
    }

    func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    func installDownloadedUpdateNow() {
        guard let immediateInstallHandler else {
            updaterController?.checkForUpdates(nil)
            return
        }

        toast = nil
        immediateInstallHandler()
    }

    private func startNetworkPathMonitor() {
        guard pathMonitor == nil else {
            return
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleNetworkPathChange(path)
            }
        }
        monitor.start(queue: pathQueue)
        pathMonitor = monitor
    }

    private func observePreferences() {
        preferencesStore.$automaticUpdatesEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyAutomaticUpdatePolicy()
            }
            .store(in: &cancellables)

        preferencesStore.$updateChannel
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.handleUpdateChannelChange()
            }
            .store(in: &cancellables)
    }

    private func handleNetworkPathChange(_ path: NWPath) {
        let isWiFiAvailable = path.status == .satisfied && path.usesInterfaceType(.wifi)
        guard self.isWiFiAvailable != isWiFiAvailable else {
            return
        }

        self.isWiFiAvailable = isWiFiAvailable
        applyAutomaticUpdatePolicy()
    }

    private func applyAutomaticUpdatePolicy() {
        let shouldActivate = preferencesStore.automaticUpdatesEnabled && isWiFiAvailable
        guard !hasAppliedAutomaticUpdatePolicy || isAutomaticUpdatePolicyActive != shouldActivate else {
            return
        }

        hasAppliedAutomaticUpdatePolicy = true
        isAutomaticUpdatePolicyActive = shouldActivate
        guard let updater = updaterController?.updater else {
            return
        }

        updater.automaticallyChecksForUpdates = shouldActivate
        updater.automaticallyDownloadsUpdates = shouldActivate

        guard shouldActivate, hasStarted, updater.canCheckForUpdates else {
            return
        }

        updater.checkForUpdatesInBackground()
    }

    private func handleUpdateChannelChange() {
        toast = nil
        immediateInstallHandler = nil

        guard
            hasStarted,
            isAutomaticUpdatePolicyActive,
            updaterController?.updater.canCheckForUpdates == true
        else {
            return
        }

        updaterController?.updater.checkForUpdatesInBackground()
    }

    private func showDownloadedUpdateToast() {
        toast = BrowserUpdateToast(
            title: BrowserStrings.updateReadyTitle,
            actionTitle: BrowserStrings.updateRestartAction,
        )
    }
}

// MARK: SPUUpdaterDelegate

extension BrowserUpdateController: SPUUpdaterDelegate {
    func feedURLString(for _: SPUUpdater) -> String? {
        selectedFeedURLString
    }

    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        updateChannel == .beta ? ["beta"] : []
    }

    func updater(_: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck != .updates else {
            return
        }

        guard preferencesStore.automaticUpdatesEnabled, isWiFiAvailable else {
            throw NSError(
                domain: "com.levochkaa.OpenArc.updates",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Automatic updates are paused until Wi-Fi is available.",
                ],
            )
        }
    }

    func updater(_: SPUUpdater, didDownloadUpdate _: SUAppcastItem) {
        showDownloadedUpdateToast()
    }

    func updater(
        _: SPUUpdater,
        willInstallUpdateOnQuit _: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void,
    ) -> Bool {
        self.immediateInstallHandler = immediateInstallHandler
        showDownloadedUpdateToast()
        return true
    }
}
