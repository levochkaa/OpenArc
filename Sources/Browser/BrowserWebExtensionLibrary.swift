// BrowserWebExtensionLibrary.swift

import Combine
import Foundation
import OSLog
import WebKit
import ZIPFoundation

let webExtensionLog = Logger(subsystem: "com.levochkaa.OpenArc", category: "WebExtensions")

// MARK: - BrowserWebExtensionRecord

/// One installed extension, as the library saves it.
struct BrowserWebExtensionRecord: Codable, Equatable, Identifiable {
    enum SiteAccess: Codable, Equatable {
        /// Every site the extension asks for.
        case requested
        /// Only these hosts and their subdomains.
        case sites([String])
    }

    /// The Chrome extension ID, the add-on's gecko ID, or Chromium's ID for
    /// extensions the Mac profile installed.
    let id: String
    let source: BrowserWebExtensionSource
    /// What the store knows the extension by: its ID, or the AMO slug.
    var storeIdentifier: String
    var name: String
    var version: String
    /// The folder under the library's `Installed` folder; absolute for
    /// Chromium's extensions.
    var directory: String
    /// The stable host of the extension's `webkit-extension://` pages, which
    /// keeps its storage across launches.
    let baseHost: String
    var isEnabled = true
    var allowsPrivateBrowsing = false
    var siteAccess = SiteAccess.requested
    /// Permissions the user granted, at install or when the extension asked.
    var grantedPermissions = [String]()
    /// Match patterns granted when the extension asked at run time.
    var grantedMatchPatterns = [String]()
    /// What the manifest asks for that WebKit does not run.
    var unsupportedFeatures = [String]()
    var installedAt = Date()
    var lastUpdateCheck: Date?

    /// Add-ons from AMO are written for Firefox; WebKit runs the standard
    /// parts of their API.
    var isPartiallyCompatible: Bool { source == .firefoxAddons }

    var sourceLabel: String {
        switch source {
        case .chromeWebStore: "Chrome Web Store"
        case .firefoxAddons: "Firefox"
        case .chromiumProfile: "Chromium"
        }
    }
}

// MARK: - BrowserWebExtensionPendingInstall

/// A downloaded, verified and unpacked extension waiting for the user's
/// answer to its permissions prompt.
@MainActor final class BrowserWebExtensionPendingInstall {
    let item: BrowserWebExtensionStoreItem
    let id: String
    let webExtension: WKWebExtension
    let manifest: BrowserWebExtensionManifest
    let stagingURL: URL
    /// The record it replaces, for an update.
    let existing: BrowserWebExtensionRecord?

    var name: String { webExtension.displayName ?? manifest.name ?? id }
    var version: String { webExtension.version ?? manifest.version ?? "" }

    /// The prompt's lines for what WebKit grants.
    var permissionLines: [String] {
        BrowserWebExtensionPermissionText.lines(
            permissions: Set(webExtension.requestedPermissions.map(\.rawValue)),
            matchPatterns: webExtension.allRequestedMatchPatterns.map(\.string).sorted(),
        )
    }

    /// The prompt's lines for what will not work here.
    var unsupportedFeatures: [String] { manifest.unsupportedFeatures }

    init(
        item: BrowserWebExtensionStoreItem, id: String, webExtension: WKWebExtension,
        manifest: BrowserWebExtensionManifest, stagingURL: URL, existing: BrowserWebExtensionRecord?,
    ) {
        self.item = item
        self.id = id
        self.webExtension = webExtension
        self.manifest = manifest
        self.stagingURL = stagingURL
        self.existing = existing
    }
}

// MARK: - BrowserWebExtensionLibraryError

enum BrowserWebExtensionLibraryError: Error, LocalizedError {
    case notAStorePage
    case download(Int)
    case untrustedDownload
    case noManifest
    case alreadyInstalled(String)
    case unloadable(String)

    var errorDescription: String? {
        switch self {
        case .notAStorePage: "This page is not an extension in a store."
        case .download(let status): "The extension could not be downloaded (HTTP \(status))."
        case .untrustedDownload: "The extension's download did not come from the store over HTTPS."
        case .noManifest: "The extension has no manifest."
        case .alreadyInstalled(let name): "\(name) is already installed."
        case .unloadable(let reason): "The extension cannot run here: \(reason)"
        }
    }
}

// MARK: - BrowserWebExtensionLibrary

/// Installed extensions, their files and the WebKit controller that runs them.
///
/// Files live under `rootURL`: `Installed/<folder>` per extension,
/// `Staging/` while an install waits for its prompt, and `extensions.json`
/// with the records.
@MainActor final class BrowserWebExtensionLibrary {
    // MARK: Internal

    let rootURL: URL
    let controller: WKWebExtensionController
    let changes = PassthroughSubject<Void, Never>()
    var schedule = BrowserWebExtensionUpdateSchedule.standard
    /// Adapts backgrounds to iOS WebKit: service workers run as background
    /// page scripts (it has none without the browser entitlement), and
    /// persistent background pages become non-persistent.
    var adaptsBackgroundsForIOS = false
    var now: () -> Date = Date.init

    private(set) var records = [BrowserWebExtensionRecord]()
    /// Why an extension failed to load, by ID.
    private(set) var loadErrors = [String: String]()

    private var contexts = [String: WKWebExtensionContext]()
    private let session: URLSession
    private var isUpdating = false
    private var errorsObservation: (any NSObjectProtocol)?
    private var loggedErrorCounts = [ObjectIdentifier: Int]()

    var registryURL: URL { rootURL.appendingPathComponent("extensions.json") }
    var installedURL: URL { rootURL.appendingPathComponent("Installed", isDirectory: true) }
    var stagingURL: URL { rootURL.appendingPathComponent("Staging", isDirectory: true) }

    /// Loaded contexts of enabled extensions, in the records' order.
    var loadedContexts: [(record: BrowserWebExtensionRecord, context: WKWebExtensionContext)] {
        records.compactMap { record in contexts[record.id].map { (record, $0) } }
    }

    /// `applicationName` goes into the user agent of the extensions' own
    /// pages, which some extensions read to pick their browser's code paths.
    init(
        rootURL: URL, controllerIdentifier: UUID?, applicationName: String? = nil, session: URLSession = .shared,
    ) {
        self.rootURL = rootURL
        self.session = session
        let configuration: WKWebExtensionController.Configuration = controllerIdentifier.map {
            .init(identifier: $0)
        } ?? .nonPersistent()
        if let applicationName {
            let webViewConfiguration = configuration.webViewConfiguration ?? WKWebViewConfiguration()
            webViewConfiguration.applicationNameForUserAgent = applicationName
            configuration.webViewConfiguration = webViewConfiguration
        }
        self.controller = WKWebExtensionController(configuration: configuration)
        self.records = Self.readRecords(at: rootURL.appendingPathComponent("extensions.json"))
        try? FileManager.default.removeItem(at: stagingURL)
        self.errorsObservation = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification, object: nil, queue: .main,
        ) { [weak self] notification in
            let context = notification.object as? WKWebExtensionContext
            MainActor.assumeIsolated {
                guard let self, let context else { return }
                let name = context.webExtension.displayName ?? ""
                let key = ObjectIdentifier(context)
                let logged = self.loggedErrorCounts[key] ?? 0
                self.loggedErrorCounts[key] = context.errors.count
                for error in context.errors.dropFirst(logged) {
                    let nsError = error as NSError
                    webExtensionLog.error(
                        "\(name, privacy: .public) error \(nsError.code): \(nsError.localizedDescription, privacy: .public) \(String(describing: nsError.userInfo), privacy: .public)",
                    )
                }
            }
        }
    }

    /// A stable controller identifier saved in `defaults`, so extension
    /// storage survives launches.
    static func controllerIdentifier(key: String, defaults: UserDefaults = .standard) -> UUID {
        if let string = defaults.string(forKey: key), let id = UUID(uuidString: string) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }

    // MARK: Private

    private static func readRecords(at url: URL) -> [BrowserWebExtensionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BrowserWebExtensionRecord].self, from: data)) ?? []
    }

    func record(id: String) -> BrowserWebExtensionRecord? { records.first { $0.id == id } }

    func context(id: String) -> WKWebExtensionContext? { contexts[id] }

    func record(for context: WKWebExtensionContext) -> BrowserWebExtensionRecord? {
        guard let id = contexts.first(where: { $0.value === context })?.key else { return nil }
        return record(id: id)
    }

    func directoryURL(for record: BrowserWebExtensionRecord) -> URL {
        record.directory.hasPrefix("/")
            ? URL(fileURLWithPath: record.directory, isDirectory: true)
            : installedURL.appendingPathComponent(record.directory, isDirectory: true)
    }

    /// Loads every enabled extension; one that fails stays off with its error.
    func loadAll() async {
        for record in records where record.isEnabled && contexts[record.id] == nil {
            await load(record)
        }
        changes.send()
    }

    // MARK: Installing

    /// Downloads, verifies, unpacks and parses the store page's extension.
    func prepareInstall(_ item: BrowserWebExtensionStoreItem) async throws -> BrowserWebExtensionPendingInstall {
        let (archive, id) = try await download(item)
        if let existing = records.first(where: { $0.id == id }) ?? records.first(where: {
            $0.source == item.source && $0.storeIdentifier == item.identifier
        }) {
            throw BrowserWebExtensionLibraryError.alreadyInstalled(existing.name)
        }
        return try await stage(archive: archive, item: item, id: id, existing: nil)
    }

    /// Saves the install the user approved and runs it.
    @discardableResult func commit(_ pending: BrowserWebExtensionPendingInstall) async throws
        -> BrowserWebExtensionRecord
    {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installedURL, withIntermediateDirectories: true)
        var record = pending.existing ?? BrowserWebExtensionRecord(
            id: pending.id,
            source: pending.item.source,
            storeIdentifier: pending.item.identifier,
            name: pending.name,
            version: pending.version,
            directory: UUID().uuidString,
            baseHost: UUID().uuidString.lowercased(),
            grantedPermissions: pending.webExtension.requestedPermissions.map(\.rawValue).sorted(),
        )
        record.name = pending.name
        record.version = pending.version
        record.unsupportedFeatures = pending.unsupportedFeatures
        record.lastUpdateCheck = now()
        let destination = directoryURL(for: record)
        if pending.existing != nil {
            unload(id: record.id)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: pending.stagingURL, to: destination)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        save()
        if record.isEnabled {
            await load(record)
        }
        changes.send()
        return record
    }

    func discard(_ pending: BrowserWebExtensionPendingInstall) {
        try? FileManager.default.removeItem(at: pending.stagingURL)
    }

    // MARK: Managing

    func setEnabled(id: String, _ enabled: Bool) async {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].isEnabled != enabled else {
            return
        }
        records[index].isEnabled = enabled
        save()
        if enabled {
            await load(records[index])
        } else {
            unload(id: id)
        }
        changes.send()
    }

    func setAllowsPrivateBrowsing(id: String, _ allowed: Bool) {
        update(id: id) { $0.allowsPrivateBrowsing = allowed }
        contexts[id]?.hasAccessToPrivateData = allowed
    }

    func setSiteAccess(id: String, _ access: BrowserWebExtensionRecord.SiteAccess) {
        update(id: id) { $0.siteAccess = access }
        if let record = record(id: id), let context = contexts[id] {
            applyPermissions(record, to: context)
        }
    }

    /// Keeps a permission the extension asked for at run time.
    func grant(id: String, permissions: [String] = [], matchPatterns: [String] = []) {
        update(id: id) { record in
            record.grantedPermissions = Array(Set(record.grantedPermissions + permissions)).sorted()
            record.grantedMatchPatterns = Array(Set(record.grantedMatchPatterns + matchPatterns)).sorted()
        }
    }

    func remove(id: String) {
        guard let record = record(id: id) else { return }
        unload(id: id)
        records.removeAll { $0.id == id }
        loadErrors[id] = nil
        save()
        if record.source != .chromiumProfile {
            try? FileManager.default.removeItem(at: directoryURL(for: record))
        }
        // Its storage goes with it.
        controller.fetchDataRecords(ofTypes: WKWebExtensionController.allExtensionDataTypes) { [weak self] all in
            let mine = all.filter { $0.uniqueIdentifier == record.id }
            guard let self, !mine.isEmpty else { return }
            controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: mine) {}
        }
        changes.send()
    }

    // MARK: Chromium's extensions

    /// Brings the Chromium profile's extensions in: new ones load, removed
    /// ones unload, and each follows Chromium's enabled state.
    func syncExternal(
        _ entries: [(
            id: String, name: String, version: String, directory: URL, isEnabled: Bool, allowsPrivateBrowsing: Bool,
        )],
    ) async {
        let ids = Set(entries.map(\.id))
        for record in records where record.source == .chromiumProfile && !ids.contains(record.id) {
            unload(id: record.id)
            records.removeAll { $0.id == record.id }
        }
        for entry in entries {
            if let index = records.firstIndex(where: { $0.id == entry.id }) {
                let changedFiles = records[index].directory != entry.directory.path
                    || records[index].version != entry.version
                records[index].name = entry.name
                records[index].version = entry.version
                records[index].directory = entry.directory.path
                records[index].isEnabled = entry.isEnabled
                records[index].allowsPrivateBrowsing = entry.allowsPrivateBrowsing
                contexts[entry.id]?.hasAccessToPrivateData = entry.allowsPrivateBrowsing
                if changedFiles || !entry.isEnabled { unload(id: entry.id) }
            } else {
                var record = BrowserWebExtensionRecord(
                    id: entry.id, source: .chromiumProfile, storeIdentifier: entry.id, name: entry.name,
                    version: entry.version, directory: entry.directory.path, baseHost: entry.id,
                )
                record.isEnabled = entry.isEnabled
                record.allowsPrivateBrowsing = entry.allowsPrivateBrowsing
                // Chromium granted these at install.
                if let manifest = try? BrowserWebExtensionManifest(
                    data: Data(contentsOf: entry.directory.appendingPathComponent("manifest.json")),
                ) {
                    record.grantedPermissions = manifest.permissions
                    record.unsupportedFeatures = manifest.unsupportedFeatures
                }
                records.append(record)
            }
        }
        save()
        for record in records
            where record.source == .chromiumProfile && record.isEnabled && contexts[record.id] == nil
        {
            await load(record)
        }
        changes.send()
    }

    // MARK: Updating

    /// Checks the stores for newer versions when a check is due, or always
    /// with `force`. Returns the IDs that updated.
    @discardableResult func checkForUpdates(force: Bool = false) async -> [String] {
        guard !isUpdating else { return [] }
        isUpdating = true
        defer { isUpdating = false }
        let due = records.filter {
            $0.source != .chromiumProfile && (force || schedule.isDue(lastCheck: $0.lastUpdateCheck, now: now()))
        }
        guard !due.isEmpty else { return [] }
        var updated = [String]()
        var available = [(BrowserWebExtensionRecord, BrowserWebExtensionStoreItem)]()
        let chrome = due.filter { $0.source == .chromeWebStore }
        if !chrome.isEmpty, let url = BrowserWebExtensionStoreItem.chromeUpdateCheckURL(
            versions: chrome.map { ($0.storeIdentifier, $0.version) },
        ), let (data, response) = try? await session.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200
        {
            for update in BrowserChromeUpdateResponse.updates(from: data) {
                guard let record = chrome.first(where: { $0.id == update.id }),
                      BrowserWebExtensionVersion.isNewer(update.version, than: record.version) else { continue }
                available.append((record, .init(source: .chromeWebStore, identifier: record.storeIdentifier)))
            }
        }
        for record in due where record.source == .firefoxAddons {
            guard let url = BrowserWebExtensionStoreItem.amoAddonURL(record.storeIdentifier),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let addon = try? BrowserAMOAddon.decode(data),
                  BrowserWebExtensionVersion.isNewer(addon.currentVersion.version, than: record.version)
            else { continue }
            available.append((record, .init(source: .firefoxAddons, identifier: record.storeIdentifier)))
        }
        for (record, item) in available {
            do {
                let (archive, id) = try await download(item)
                let pending = try await stage(archive: archive, item: item, id: id, existing: record)
                guard pending.id == record.id else {
                    discard(pending)
                    continue
                }
                try await commit(pending)
                updated.append(record.id)
                webExtensionLog.info("Updated \(record.name, privacy: .public) to \(pending.version, privacy: .public)")
            } catch {
                webExtensionLog.error(
                    "Update of \(record.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)",
                )
            }
        }
        let checked = now()
        for record in due {
            update(id: record.id) { $0.lastUpdateCheck = checked }
        }
        changes.send()
        return updated
    }

    /// Fetches and checks the package. Returns the ZIP archive and the ID it
    /// belongs to.
    private func download(_ item: BrowserWebExtensionStoreItem) async throws -> (Data, String) {
        switch item.source {
        case .chromeWebStore:
            guard let url = item.metadataURL else { throw BrowserWebExtensionLibraryError.notAStorePage }
            let data = try await fetch(url, source: .chromeWebStore)
            let identifier = item.identifier
            let package = try await Task.detached(priority: .userInitiated) {
                try BrowserCRXPackage.verify(data, expectedID: identifier)
            }.value
            return (package.archive, package.extensionID)
        case .firefoxAddons:
            guard let url = item.metadataURL else { throw BrowserWebExtensionLibraryError.notAStorePage }
            let addon = try await BrowserAMOAddon.decode(fetch(url, source: .firefoxAddons))
            guard BrowserWebExtensionStoreItem.isTrustedDownload(addon.currentVersion.file.url, source: .firefoxAddons)
            else { throw BrowserWebExtensionLibraryError.untrustedDownload }
            let data = try await fetch(addon.currentVersion.file.url, source: .firefoxAddons)
            let hash = addon.currentVersion.file.hash
            try await Task.detached(priority: .userInitiated) { try BrowserXPIChecksum.verify(data, hash: hash) }.value
            return (data, addon.guid)
        case .chromiumProfile:
            throw BrowserWebExtensionLibraryError.notAStorePage
        }
    }

    private func fetch(_ url: URL, source: BrowserWebExtensionSource) async throws -> Data {
        guard BrowserWebExtensionStoreItem.isTrustedDownload(url, source: source) else {
            throw BrowserWebExtensionLibraryError.untrustedDownload
        }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BrowserWebExtensionLibraryError.download(status) }
        // Redirects must stay on the store's HTTPS hosts.
        guard BrowserWebExtensionStoreItem.isTrustedDownload(response.url, source: source) else {
            throw BrowserWebExtensionLibraryError.untrustedDownload
        }
        return data
    }

    /// Unpacks the archive into a staging folder and parses it with WebKit.
    private func stage(
        archive: Data, item: BrowserWebExtensionStoreItem, id: String, existing: BrowserWebExtensionRecord?,
    ) async throws -> BrowserWebExtensionPendingInstall {
        let staging = stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager()
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let zipURL = staging.appendingPathExtension("zip")
            try archive.write(to: zipURL)
            defer { try? fileManager.removeItem(at: zipURL) }
            try fileManager.unzipItem(at: zipURL, to: staging)
        }.value
        do {
            let manifestURL = staging.appendingPathComponent("manifest.json")
            guard let manifestData = try? Data(contentsOf: manifestURL) else {
                throw BrowserWebExtensionLibraryError.noManifest
            }
            try adaptBackground(in: staging)
            let manifest = try BrowserWebExtensionManifest(data: manifestData)
            let webExtension = try await WKWebExtension(resourceBaseURL: staging)
            // An add-on's own ID wins over AMO's record of it.
            let resolvedID = item.source == .firefoxAddons ? manifest.geckoID ?? id : id
            return BrowserWebExtensionPendingInstall(
                item: item, id: resolvedID, webExtension: webExtension, manifest: manifest, stagingURL: staging,
                existing: existing,
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if error is BrowserWebExtensionLibraryError { throw error }
            throw BrowserWebExtensionLibraryError.unloadable(error.localizedDescription)
        }
    }

    private func load(_ record: BrowserWebExtensionRecord) async {
        do {
            if record.source != .chromiumProfile {
                try adaptBackground(in: directoryURL(for: record))
            }
            let webExtension = try await WKWebExtension(resourceBaseURL: directoryURL(for: record))
            // The record may have changed while WebKit read the files.
            guard let current = self.record(id: record.id), current.isEnabled,
                  contexts[record.id] == nil else { return }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = record.id
            if let baseURL = URL(string: "webkit-extension://\(record.baseHost)/") {
                context.baseURL = baseURL
            }
            context.hasAccessToPrivateData = current.allowsPrivateBrowsing
            context.inspectionName = current.name
            #if DEBUG
                context.isInspectable = true
            #endif
            applyPermissions(current, to: context)
            try controller.load(context)
            contexts[record.id] = context
            loadErrors[record.id] = nil
            for error in webExtension.errors {
                webExtensionLog.notice(
                    "\(current.name, privacy: .public): \(error.localizedDescription, privacy: .public)",
                )
            }
        } catch {
            loadErrors[record.id] = error.localizedDescription
            webExtensionLog.error(
                "\(record.name, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)",
            )
        }
    }

    /// Rewrites a background iOS WebKit cannot run: see `adaptsBackgroundsForIOS`.
    /// Files from Chromium's profile stay as they are.
    private func adaptBackground(in directory: URL) throws {
        guard adaptsBackgroundsForIOS else { return }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let shimURL = directory.appendingPathComponent(BrowserWebExtensionManifest.serviceWorkerShimName)
        guard let json = try JSONSerialization.jsonObject(with: BrowserWebExtensionManifest.strippingComments(data))
            as? [String: Any] else { return }
        if let adapted = BrowserWebExtensionManifest.nonPersistentBackground(json) {
            try JSONSerialization.data(
                withJSONObject: adapted,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
            )
            .write(to: manifestURL, options: .atomic)
            return
        }
        let background = json["background"] as? [String: Any]
        // An earlier install's shim follows this version of the app.
        if (background?["scripts"] as? [String])?.first == BrowserWebExtensionManifest.serviceWorkerShimName {
            try Data(BrowserWebExtensionManifest.serviceWorkerShim.utf8).write(to: shimURL)
            return
        }
        guard let worker = background?["service_worker"] as? String else { return }
        let workerPath = worker.hasPrefix("/") ? String(worker.dropFirst()) : worker
        let source = try? String(contentsOf: directory.appendingPathComponent(workerPath), encoding: .utf8)
        let workerDirectory = directory.appendingPathComponent(workerPath).deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: workerDirectory.path)) ?? []
        guard let adapted = BrowserWebExtensionManifest.runningServiceWorkerAsScripts(
            json, workerSource: source, siblingFiles: siblings,
        ) else { return }
        try Data(BrowserWebExtensionManifest.serviceWorkerShim.utf8).write(to: shimURL)
        try JSONSerialization.data(
            withJSONObject: adapted,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
        )
        .write(to: manifestURL, options: .atomic)
    }

    private func unload(id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        try? controller.unload(context)
    }

    private func applyPermissions(_ record: BrowserWebExtensionRecord, to context: WKWebExtensionContext) {
        let distantFuture = Date.distantFuture
        var permissions = [WKWebExtension.Permission: Date]()
        for name in record.grantedPermissions {
            permissions[WKWebExtension.Permission(rawValue: name)] = distantFuture
        }
        context.grantedPermissions = permissions
        var patterns = [WKWebExtension.MatchPattern: Date]()
        switch record.siteAccess {
        case .requested:
            for pattern in context.webExtension.allRequestedMatchPatterns {
                patterns[pattern] = distantFuture
            }
        case .sites(let hosts):
            for host in hosts {
                for string in ["*://\(host)/*", "*://*.\(host)/*"] {
                    if let pattern = try? WKWebExtension.MatchPattern(string: string) {
                        patterns[pattern] = distantFuture
                    }
                }
            }
        }
        for string in record.grantedMatchPatterns {
            if let pattern = try? WKWebExtension.MatchPattern(string: string) {
                patterns[pattern] = distantFuture
            }
        }
        context.grantedPermissionMatchPatterns = patterns
    }

    private func update(id: String, _ change: (inout BrowserWebExtensionRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        save()
        changes.send()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try encoder.encode(records).write(to: registryURL, options: .atomic)
        } catch {
            webExtensionLog.error("Saving extensions failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
