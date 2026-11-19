// BrowserWebExtensionManifest.swift

import Foundation

// MARK: - BrowserWebExtensionManifest

/// What the install prompt and Settings read from an extension's manifest
/// before WebKit loads it.
struct BrowserWebExtensionManifest: Equatable {
    /// Permissions WebKit's extension engine implements.
    static let supportedPermissions: Set = [
        "activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest",
        "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging",
        "scripting", "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest",
    ]

    /// Manifest keys WebKit ignores, most of them Firefox's own.
    static let unsupportedKeyNames: [String: String] = [
        "sidebar_action": "Sidebar",
        "side_panel": "Side panel",
        "chrome_settings_overrides": "Search engine and home page settings",
        "chrome_url_overrides": "Replacement pages",
        "omnibox": "Address bar keyword",
        "protocol_handlers": "Protocol handlers",
        "theme": "Browser theme",
        "theme_experiment": "Browser theme",
        "user_scripts": "User scripts",
        "devtools_page": "Developer tools panel",
    ]

    /// Names for permissions WebKit lacks, for the prompt's unsupported list.
    static let unsupportedPermissionNames: [String: String] = [
        "contextualIdentities": "Containers",
        "proxy": "Proxy settings",
        "webRequestBlocking": "Blocking network requests",
        "webRequestFilterResponse": "Rewriting network responses",
        "dns": "DNS lookups",
        "find": "Find on page",
        "pkcs11": "Security devices",
        "privacy": "Privacy settings",
        "browserSettings": "Browser settings",
        "browsingData": "Clearing browsing data",
        "downloads": "Downloads",
        "downloads.open": "Opening downloads",
        "history": "Browsing history",
        "bookmarks": "Bookmarks",
        "notifications": "Notifications",
        "identity": "Sign-in through the browser",
        "idle": "Idle detection",
        "sessions": "Recently closed tabs",
        "topSites": "Top sites",
        "management": "Managing other extensions",
        "offscreen": "Offscreen documents",
        "webRequestAuthProvider": "Answering sign-in prompts",
        "sidePanel": "Side panel",
        "tabGroups": "Tab groups",
        "tabHide": "Hiding tabs",
        "theme": "Browser theme",
        "search": "Search engines",
        "geolocation": "Location",
        "clipboardRead": "Reading the clipboard",
        "background": "Running in the background",
        "debugger": "Debugger",
        "webAuthenticationProxy": "Passkey proxy",
        "declarativeContent": "Page-dependent actions",
        "contentSettings": "Site settings",
        "fontSettings": "Font settings",
        "gcm": "Push messages",
        "system.cpu": "System information",
        "system.display": "System information",
        "system.memory": "System information",
        "system.storage": "System information",
        "ttsEngine": "Speech engine",
        "tts": "Speech",
        "power": "Power management",
        "printerProvider": "Printers",
        "loginState": "Sign-in state",
        "userScripts": "User scripts",
        "menus.overrideContext": "Replacing the page menu",
        "captivePortal": "Captive portal detection",
        "geckoProfiler": "Profiler",
    ]

    /// The file the page-hosted background loads before an extension's
    /// service worker script.
    static let serviceWorkerShimName = "__openarc_service_worker.js"

    /// What a service worker script expects of its global scope, for when it
    /// runs in a background page: `importScripts` of files the manifest
    /// already loaded is a no-op, and others fail with a clear error.
    /// `notifications` and `idle`, which WebKit lacks and password managers
    /// subscribe to at startup, answer as if nothing ever happens.
    static let serviceWorkerShim = """
    (() => {
      const event = () => ({ addListener() {}, removeListener() {}, hasListener: () => false });
      const done = (value) => (...args) => {
        const callback = args.find((arg) => typeof arg === 'function');
        if (callback) { setTimeout(() => callback(value), 0); return undefined; }
        return Promise.resolve(value);
      };
      for (const api of [globalThis.chrome, globalThis.browser]) {
        if (!api) continue;
        if (!api.notifications) {
          api.notifications = {
            create: done(''), update: done(false), clear: done(false), getAll: done({}),
            getPermissionLevel: done('denied'),
            onClicked: event(), onClosed: event(), onButtonClicked: event(), onShowSettings: event(),
          };
        }
        if (!api.idle) {
          api.idle = { queryState: done('active'), setDetectionInterval() {}, onStateChanged: event() };
        }
      }
    })();
    self.importScripts = (...urls) => {
      const loaded = new Set([...document.scripts].map((script) => script.src));
      const base = document.currentScript ? document.currentScript.src : location.href;
      for (const url of urls) {
        if (!loaded.has(new URL(url, base).href)) {
          throw new Error(`importScripts(${url}) is not available in this browser`);
        }
      }
    };
    """

    let name: String?
    let version: String?
    let manifestVersion: Int
    /// `browser_specific_settings.gecko.id`, or the older `applications.gecko.id`.
    let geckoID: String?
    let permissions: [String]
    let optionalPermissions: [String]
    /// Host permissions and match patterns, from every place they can be.
    let matchPatterns: [String]

    /// Manifest keys present that WebKit ignores.
    let unsupportedKeys: [String]

    /// Requested permissions, required or optional, that WebKit lacks.
    var unsupportedPermissions: [String] {
        var seen = Set<String>()
        return (permissions + optionalPermissions).filter {
            !Self.supportedPermissions.contains($0) && seen.insert($0).inserted
        }
    }

    /// What the prompt lists as not working, in plain words, without repeats.
    var unsupportedFeatures: [String] {
        var seen = Set<String>()
        let keys = unsupportedKeys.compactMap { Self.unsupportedKeyNames[$0] }
        let permissions = unsupportedPermissions.map { Self.unsupportedPermissionNames[$0] ?? $0 }
        return (keys + permissions).filter { seen.insert($0).inserted }
    }

    init(json: [String: Any]) {
        self.name = json["name"] as? String
        self.version = json["version"] as? String
        self.manifestVersion = (json["manifest_version"] as? NSNumber)?.intValue ?? 2
        self.geckoID = Self.geckoID(in: json)
        let permissions = (json["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        let optional = (json["optional_permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        let hosts = (json["host_permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        self.permissions = permissions.filter { !Self.isMatchPattern($0) }
        self.optionalPermissions = optional.filter { !Self.isMatchPattern($0) }
        var patterns = hosts + permissions.filter(Self.isMatchPattern)
        for script in json["content_scripts"] as? [[String: Any]] ?? [] {
            patterns += (script["matches"] as? [Any] ?? []).compactMap { $0 as? String }
        }
        var seen = Set<String>()
        self.matchPatterns = patterns.filter { seen.insert($0).inserted }
        self.unsupportedKeys = Self.unsupportedKeyNames.keys.filter { json[$0] != nil }.sorted()
    }

    init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: Self.strippingComments(data))
        guard let json = object as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }
        self.init(json: json)
    }

    /// iOS WebKit runs no service workers without the browser entitlement, so
    /// a service worker background runs as background page scripts instead.
    /// Returns the changed manifest, or nil when it has no service worker.
    /// Literal `importScripts("a.js", …)` calls load those files first. A
    /// worker that builds its `importScripts` paths, as webpack's chunk
    /// loader does, gets the numbered chunks next to it (`719.background.js`)
    /// loaded first, so its loader finds them already registered.
    static func runningServiceWorkerAsScripts(
        _ json: [String: Any], workerSource: String?, siblingFiles: [String] = [],
    ) -> [String: Any]? {
        guard var background = json["background"] as? [String: Any],
              let worker = background["service_worker"] as? String, !worker.isEmpty else { return nil }
        let workerPath = worker.hasPrefix("/") ? String(worker.dropFirst()) : worker
        let directory = (workerPath as NSString).deletingLastPathComponent
        var imports = [String]()
        if let workerSource {
            for call in literalImportScripts(in: workerSource) {
                let path = call.hasPrefix("/")
                    ? String(call.dropFirst())
                    : normalizedPath((directory as NSString).appendingPathComponent(call))
                if !imports.contains(path) { imports.append(path) }
            }
        }
        if let workerSource, workerSource.contains("importScripts("),
           literalImportScripts(in: workerSource).isEmpty
        {
            let workerName = (workerPath as NSString).lastPathComponent
            let chunks = siblingFiles.filter { $0 != workerName && isChunkFile($0) }.sorted {
                $0.compare($1, options: .numeric) == .orderedAscending
            }
            for chunk in chunks {
                let path = directory.isEmpty ? chunk : (directory as NSString).appendingPathComponent(chunk)
                if !imports.contains(path) { imports.append(path) }
            }
        }
        background.removeValue(forKey: "service_worker")
        background["scripts"] = [serviceWorkerShimName] + imports + [workerPath]
        var json = json
        json["background"] = background
        return json
    }

    /// A path inside the extension with `.` and `..` resolved.
    static func normalizedPath(_ path: String) -> String {
        var parts = [Substring]()
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    /// A webpack chunk: a number, then optional dotted parts, then `.js`.
    static func isChunkFile(_ name: String) -> Bool {
        guard name.hasSuffix(".js"), let first = name.split(separator: ".").first else { return false }
        return !first.isEmpty && first.allSatisfy(\.isNumber)
    }

    /// iOS WebKit refuses a background page that stays loaded, which a
    /// Manifest V2 page is unless it says `"persistent": false`; there it
    /// loads on events and unloads when idle. Returns the changed manifest,
    /// or nil when the background is not persistent.
    static func nonPersistentBackground(_ json: [String: Any]) -> [String: Any]? {
        guard var background = json["background"] as? [String: Any], background["service_worker"] == nil else {
            return nil
        }
        let version = (json["manifest_version"] as? NSNumber)?.intValue ?? 2
        let persistent = (background["persistent"] as? NSNumber)?.boolValue ?? (version < 3)
        guard persistent else { return nil }
        background["persistent"] = false
        var json = json
        json["background"] = background
        return json
    }

    /// The string arguments of `importScripts(...)` calls whose every argument
    /// is a string literal.
    static func literalImportScripts(in source: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"importScripts\(\s*((?:["'][^"']+["']\s*,?\s*)+)\)"#)
        else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        var paths = [String]()
        for match in expression.matches(in: source, range: range) {
            guard let arguments = Range(match.range(at: 1), in: source) else { continue }
            for part in source[arguments].split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"'"))
                if !trimmed.isEmpty { paths.append(trimmed) }
            }
        }
        return paths
    }

    static func geckoID(in json: [String: Any]) -> String? {
        for key in ["browser_specific_settings", "applications"] {
            if let gecko = (json[key] as? [String: Any])?["gecko"] as? [String: Any],
               let id = gecko["id"] as? String, !id.isEmpty
            {
                return id
            }
        }
        return nil
    }

    static func isMatchPattern(_ string: String) -> Bool {
        string == "<all_urls>" || string.contains("://")
    }

    /// Chrome accepts `//` comments in manifests; JSONSerialization does not.
    static func strippingComments(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("//") else { return data }
        var output = ""
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }
            let next = text.index(after: index)
            if character == "/", next < text.endIndex, text[next] == "/" {
                while index < text.endIndex, text[index] != "\n" {
                    index = text.index(after: index)
                }
                continue
            }
            if character == "/", next < text.endIndex, text[next] == "*" {
                index = text.index(after: next)
                while index < text.endIndex {
                    let after = text.index(after: index)
                    if text[index] == "*", after < text.endIndex, text[after] == "/" {
                        index = text.index(after: after)
                        break
                    }
                    index = after
                }
                continue
            }
            if character == "\"" { inString = true }
            output.append(character)
            index = next
        }
        return Data(output.utf8)
    }
}

// MARK: - BrowserWebExtensionPermissionText

/// The install prompt's lines for permissions and sites, as plain sentences.
enum BrowserWebExtensionPermissionText {
    static func lines(permissions: Set<String>, matchPatterns: [String]) -> [String] {
        var lines = [String]()
        if let sites = sitesLine(matchPatterns) {
            lines.append(sites)
        }
        let ordered = [
            "declarativeNetRequest", "declarativeNetRequestWithHostAccess", "declarativeNetRequestFeedback",
            "webRequest", "tabs", "webNavigation", "cookies", "scripting", "activeTab", "clipboardWrite",
            "contextMenus", "menus", "alarms", "storage", "unlimitedStorage", "nativeMessaging",
        ]
        var seen = Set<String>()
        for permission in ordered where permissions.contains(permission) {
            guard let line = line(for: permission), seen.insert(line).inserted else { continue }
            lines.append(line)
        }
        return lines
    }

    static func line(for permission: String) -> String? {
        switch permission {
        case "activeTab": "Read and change the page you are on when you use the extension"
        case "alarms": "Run tasks on a schedule"
        case "clipboardWrite": "Copy text to the clipboard"
        case "contextMenus",
             "menus": "Add items to menus"
        case "cookies": "Read and change cookies of the sites it can access"
        case "declarativeNetRequest",
             "declarativeNetRequestWithHostAccess": "Block or change content on pages"
        case "declarativeNetRequestFeedback": "See which of its rules matched"
        case "nativeMessaging": "Talk to other apps"
        case "scripting": "Run scripts on the sites it can access"
        case "storage",
             "unlimitedStorage": "Store its data on this device"
        case "tabs": "See the addresses and titles of your tabs"
        case "webNavigation": "See the pages you open"
        case "webRequest": "See the network requests of the sites it can access"
        default: nil
        }
    }

    static func sitesLine(_ patterns: [String]) -> String? {
        guard !patterns.isEmpty else { return nil }
        if patterns.contains(where: matchesAllSites) {
            return "Read and change your data on all websites"
        }
        var seen = Set<String>()
        let hosts = patterns.compactMap(host(of:)).filter { seen.insert($0).inserted }
        guard !hosts.isEmpty else { return nil }
        switch hosts.count {
        case 1: return "Read and change your data on \(hosts[0])"
        case 2: return "Read and change your data on \(hosts[0]) and \(hosts[1])"
        case 3: return "Read and change your data on \(hosts[0]), \(hosts[1]) and \(hosts[2])"
        default:
            return "Read and change your data on \(hosts[0]), \(hosts[1]) and \(hosts.count - 2) other sites"
        }
    }

    static func matchesAllSites(_ pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        guard let host = host(of: pattern) else { return false }
        return host == "*"
    }

    /// The host of `scheme://host/path`, with `*.` left for the prompt to show
    /// as a whole domain.
    static func host(of pattern: String) -> String? {
        guard let range = pattern.range(of: "://") else { return nil }
        let rest = pattern[range.upperBound...]
        let host = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
        guard let host, !host.isEmpty else { return nil }
        return host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
    }
}
