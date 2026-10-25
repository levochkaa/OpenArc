import Foundation

// MARK: - BrowserSiteSettingKind

/// A per-site setting the site control center lists in its Settings
/// section. Camera and microphone are OpenArc's remembered answers;
/// the others are Chromium's content settings for the page.
enum BrowserSiteSettingKind: String, CaseIterable, Sendable {
    case camera
    case microphone
    case location
    case notifications
    case clipboard
    case popups
    case sound
    case automaticDownloads
    case midi
    case windowManagement
    case localFonts
    case idleDetection
    case autoPictureInPicture

    // MARK: Internal

    /// Kinds whose value OpenArc stores itself.
    var isRememberedByOpenArc: Bool {
        self == .camera || self == .microphone
    }

    var permissionKind: BrowserSitePermissionKind? {
        switch self {
        case .camera: .camera
        case .microphone: .microphone
        default: nil
        }
    }

    var title: String {
        switch self {
        case .camera: BrowserStrings.siteSettingCamera
        case .microphone: BrowserStrings.siteSettingMicrophone
        case .location: BrowserStrings.siteSettingLocation
        case .notifications: BrowserStrings.siteSettingNotifications
        case .clipboard: BrowserStrings.siteSettingClipboard
        case .popups: BrowserStrings.siteSettingPopups
        case .sound: BrowserStrings.siteSettingSound
        case .automaticDownloads: BrowserStrings.siteSettingAutomaticDownloads
        case .midi: BrowserStrings.siteSettingMIDI
        case .windowManagement: BrowserStrings.siteSettingWindowManagement
        case .localFonts: BrowserStrings.siteSettingLocalFonts
        case .idleDetection: BrowserStrings.siteSettingIdleDetection
        case .autoPictureInPicture: BrowserStrings.siteSettingAutoPictureInPicture
        }
    }

    var systemImageName: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .location: "location"
        case .notifications: "bell"
        case .clipboard: "doc.on.clipboard"
        case .popups: "macwindow.badge.plus"
        case .sound: "speaker.wave.2"
        case .automaticDownloads: "arrow.down.circle"
        case .midi: "pianokeys"
        case .windowManagement: "macwindow.on.rectangle"
        case .localFonts: "textformat"
        case .idleDetection: "moon.zzz"
        case .autoPictureInPicture: "pip"
        }
    }

    /// The values the setting's menu offers; Chromium has no Ask for pop-ups
    /// and sound.
    var choices: [BrowserSiteSettingValue] {
        switch self {
        case .popups, .sound: [.allow, .block]
        default: [.allow, .block, .ask]
        }
    }
}

// MARK: - BrowserSiteSettingValue

enum BrowserSiteSettingValue: String, Sendable {
    case allow
    case block
    case ask
    /// The profile's default, which removes the site's own value.
    case `default`

    // MARK: Internal

    var title: String {
        switch self {
        case .allow: BrowserStrings.sitePermissionAllowedState
        case .block: BrowserStrings.sitePermissionBlockedState
        case .ask, .default: BrowserStrings.siteSettingAskState
        }
    }

    var menuTitle: String {
        switch self {
        case .allow: BrowserStrings.sitePermissionAllow
        case .block: BrowserStrings.sitePermissionBlock
        case .ask, .default: BrowserStrings.siteSettingAskAction
        }
    }
}

// MARK: - BrowserSiteSettingRow

struct BrowserSiteSettingRow: Equatable, Sendable {
    let kind: BrowserSiteSettingKind
    let value: BrowserSiteSettingValue
}

// MARK: - BrowserChromeModel + site settings

extension BrowserChromeModel {
    /// The site's own settings, in kind order: remembered camera and
    /// microphone answers, then Chromium's values that differ from the
    /// profile default. Empty for pages without a web origin.
    func siteSettingRows(forURLString urlString: String) -> [BrowserSiteSettingRow] {
        guard let origin = BrowserSitePermissionRequest.origin(ofURLString: urlString),
              origin.hasPrefix("http") else { return [] }
        let remembered = rememberedSitePermissions.filter { $0.origin == origin }
        let chromium = siteSettingsInEngine(forURLString: urlString)
        return BrowserSiteSettingKind.allCases.compactMap { kind in
            if let permission = kind.permissionKind {
                return remembered.last { $0.kind == permission }.map {
                    BrowserSiteSettingRow(kind: kind, value: $0.allowed ? .allow : .block)
                }
            }
            return chromium[kind].map { BrowserSiteSettingRow(kind: kind, value: $0) }
        }
    }

    /// Changes one of the site's settings. Ask or the default forgets a
    /// remembered camera or microphone answer.
    func setSiteSetting(
        _ kind: BrowserSiteSettingKind,
        value: BrowserSiteSettingValue,
        forURLString urlString: String
    ) {
        guard let origin = BrowserSitePermissionRequest.origin(ofURLString: urlString) else { return }
        guard let permission = kind.permissionKind else {
            setSiteSettingInEngine(kind, value: value, forURLString: urlString)
            objectWillChange.send()
            return
        }
        var decisions = sitePermissionDecisions.filter {
            !($0.profileID == profile.id && $0.origin == origin && $0.kind == permission)
        }
        if value == .allow || value == .block {
            decisions.append(BrowserSitePermissionDecision(
                profileID: profile.id,
                origin: origin,
                kind: permission,
                allowed: value == .allow
            ))
        }
        sitePermissionDecisions = decisions
    }

    /// Chromium's page for every setting of the site.
    func openAllSiteSettings(forURLString urlString: String) {
        guard let origin = BrowserSitePermissionRequest.origin(ofURLString: urlString),
              var components = URLComponents(string: "openarc://settings/content/siteDetails")
        else { return }
        components.queryItems = [URLQueryItem(name: "site", value: origin)]
        if let url = components.url {
            openURLInNewTab(url)
        }
    }
}
