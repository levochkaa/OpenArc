import BrowserMobileTestHost
import Foundation
import Testing
import UIKit

extension BrowserMobileUITests {
    @Test func downloadsBindBeforeRuntimeCreationAndBelongToOneProfileAcrossWindows() async throws {
        try await withDownloadCompositionDirectory { directory in
            let registry = BrowserMobileProfileRegistry(directory: directory)
            let document = try await registry.document()
            let downloads = try #require(document.downloads)
            #expect(downloads.error == nil && !downloads.isLoading)
            let firstEngine = DownloadCompositionEngine(), secondEngine = DownloadCompositionEngine()
            let preferencesName = "DownloadsComposition.\(UUID())"
            let preferences = try #require(UserDefaults(suiteName: preferencesName))
            defer { preferences.removePersistentDomain(forName: preferencesName) }
            let first = BrowserMobileWorkspace(
                engine: firstEngine, sceneID: "first", profileLoader: { try await registry.document() },
                preferences: preferences
            )
            let second = BrowserMobileWorkspace(
                engine: secondEngine, sceneID: "second", profileLoader: { try await registry.document() },
                preferences: preferences
            )
            await first.restore()
            await second.restore()
            #expect(first.isReady && second.isReady)
            #expect(first.downloads === downloads && second.downloads === downloads)
            #expect(firstEngine.downloads === downloads && secondEngine.downloads === downloads)
            #expect(firstEngine.createdWithDownloads == [true] && secondEngine.createdWithDownloads == [true])
            let snapshot = document.snapshot
            var observations = 0
            second.onChange = { observations += 1 }
            await downloads.load()
            #expect(observations > 0 && document.snapshot == snapshot)
            #expect(await first.shutdown())
            #expect(second.downloads === downloads && secondEngine.downloads === downloads)
            #expect(document.snapshot == snapshot)
            let other = try await BrowserMobileProfileRegistry(directory: directory.appendingPathComponent("Other"))
                .document()
            #expect(other.downloads !== downloads)
            #expect(await second.shutdown())
            let finalObservations = observations
            await downloads.load()
            #expect(observations == finalObservations)
        }
    }

    @Test func unavailableDownloadStorageDoesNotPreventOpeningTheBrowserProfile() async throws {
        try await withDownloadCompositionDirectory { directory in
            let profile = directory.appendingPathComponent("MobileProfile", isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let blockedDirectory = profile.appendingPathComponent("Downloads")
            let original = Data("existing file is not a downloads directory".utf8)
            try original.write(to: blockedDirectory)
            let document = try await BrowserMobileProfileRegistry(directory: directory).document()
            let downloads = try #require(document.downloads)
            #expect(downloads.error != nil && downloads.entries.isEmpty)
            #expect(document.snapshot.tabs.count == 1 && document.persistenceFailure == nil)
            #expect(try Data(contentsOf: blockedDirectory) == original)
        }
    }

    @Test func downloadsToolbarAndShortcutPresentForTheirPageWithoutChangingTabs() async throws {
        try await withDownloadCompositionDirectory { directory in
            let registry = BrowserMobileProfileRegistry(directory: directory)
            let engine = DownloadCompositionEngine()
            let workspace = BrowserMobileWorkspace(
                engine: engine, sceneID: UUID().uuidString, profileLoader: { try await registry.document() }
            )
            await workspace.restore()
            let page = BrowserMobilePageViewController(workspace: workspace, contentView: engine.hostView)
            workspace.onChange = { [weak page] in page?.render() }
            let window = try UIWindow(windowScene: #require(BrowserMobileTestScene.windowScene))
            window.rootViewController = page
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            page.loadViewIfNeeded()
            let snapshot = try #require(workspace.profileDocument).snapshot
            let tabs = workspace.tabs
            let creations = engine.createdWithDownloads
            let button = try #require(downloadCompositionView("browser.downloads", in: page.view) as? UIButton)
            #expect(button.isEnabled)
            for width in [320.0, 390.0, 768.0] {
                window.frame.size = CGSize(width: width, height: 844)
                page.view.frame = window.bounds
                page.view.setNeedsLayout()
                page.view.layoutIfNeeded()
                let rect = button.convert(button.bounds, to: page.view)
                #expect(rect.width >= 44 && rect.height >= 44)
                #expect(page.view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: -0.5, dy: -0.5).contains(rect))
                #expect(page.addressField.bounds.width >= 120)
            }
            button.sendActions(for: .touchUpInside)
            try #require(await downloadCompositionEventually { page.presentedViewController is UINavigationController })
            let presented = try #require(page.presentedViewController as? UINavigationController)
            #expect(presented.topViewController is BrowserMobileDownloadsViewController)
            #expect(presented.modalPresentationStyle == .formSheet)
            page.showDownloads()
            #expect(page.presentedViewController === presented)
            page.dismiss(animated: false)
            try #require(await downloadCompositionEventually { page.presentedViewController == nil })
            let command = try #require(page.keyCommands?.first { $0.input == "l" && $0.modifierFlags == [
                .command,
                .alternate,
            ] })
            let action = try #require(command.action)
            #expect(UIApplication.shared.sendAction(action, to: page, from: command, for: nil))
            try #require(await downloadCompositionEventually { page.presentedViewController is UINavigationController })
            page.dismiss(animated: false)
            try #require(await downloadCompositionEventually { page.presentedViewController == nil })
            window.isHidden = true
            page.showDownloads()
            #expect(page.presentedViewController == nil)
            #expect(workspace.tabs == tabs && engine.createdWithDownloads == creations)
            #expect(workspace.profileDocument?.snapshot == snapshot)
            #expect(await workspace.shutdown())
        }
    }
}

@MainActor private func withDownloadCompositionDirectory(_ body: @MainActor (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadsComposition-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    // Release the document/store in the completed async scope before deleting
    // its SQLite database, including the window-owned presentation callbacks.
    try await body(directory)
}

// MARK: - DownloadCompositionEngine

@MainActor private final class DownloadCompositionEngine: BrowserMobileEngine {
    let hostView = UIView()
    var onEvent: ((BrowserMobileEngineEvent) -> Void)?
    var onPopupCreated: ((String, URL?) -> Void)?
    private(set) var downloads: BrowserMobileDownloads?
    private(set) var createdWithDownloads = [Bool]()

    func setDownloads(_ downloads: BrowserMobileDownloads?) { self.downloads = downloads }
    func createTab(id: String, url: URL) {
        createdWithDownloads.append(downloads != nil)
        onEvent?(.state(id: id, .init(url: url)))
    }

    func selectTab(id _: String?) {}
    func navigate(id: String, url: URL) { onEvent?(.state(id: id, .init(url: url))) }
    func goBack(id _: String) {}
    func goForward(id _: String) {}
    func reload(id _: String) {}
    func stop(id _: String) {}
    func closeTab(id: String) { onEvent?(.closed(id: id)) }
    func setJavaScriptDialogPresentationActive(_: Bool) {}
    func resolveJavaScriptDialog(id _: UUID, response _: BrowserMobileJavaScriptDialogResponse) {}
    func shutdown() { downloads = nil }
}

@MainActor private func downloadCompositionView(_ id: String, in view: UIView) -> UIView? {
    if view.accessibilityIdentifier == id {
        return view
    }
    return view.subviews.lazy.compactMap { downloadCompositionView(id, in: $0) }.first
}

@MainActor private func downloadCompositionEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
