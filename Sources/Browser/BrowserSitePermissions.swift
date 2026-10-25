// BrowserSitePermissions.swift

import AVFoundation
import CoreLocation
import Foundation
@preconcurrency import UserNotifications

// MARK: - BrowserSitePermissionKind

/// What a page asks for, as Chrome names it in its prompts.
enum BrowserSitePermissionKind: String, Codable, CaseIterable {
    case camera
    case microphone
    case location
    case notifications
    case clipboard
    case midi
    case windowManagement
    case localFonts
    case idleDetection
    case storageAccess
    case multipleDownloads
    case other

    // MARK: Internal

    /// Camera and microphone: Alloy-style CEF leaves them to the app, so
    /// OpenArc remembers the answer. Chromium remembers the others.
    var isMediaCapture: Bool {
        self == .camera || self == .microphone
    }

    var title: String {
        switch self {
        case .camera: BrowserStrings.sitePermissionCamera
        case .microphone: BrowserStrings.sitePermissionMicrophone
        case .location: BrowserStrings.sitePermissionLocation
        case .notifications: BrowserStrings.sitePermissionNotifications
        case .clipboard: BrowserStrings.sitePermissionClipboard
        case .midi: BrowserStrings.sitePermissionMIDI
        case .windowManagement: BrowserStrings.sitePermissionWindowManagement
        case .localFonts: BrowserStrings.sitePermissionLocalFonts
        case .idleDetection: BrowserStrings.sitePermissionIdleDetection
        case .storageAccess: BrowserStrings.sitePermissionStorageAccess
        case .multipleDownloads: BrowserStrings.sitePermissionMultipleDownloads
        case .other: BrowserStrings.sitePermissionOther
        }
    }

    var systemImageName: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .location: "location"
        case .notifications: "bell"
        case .clipboard: "doc.on.clipboard"
        case .midi: "pianokeys"
        case .windowManagement: "macwindow.on.rectangle"
        case .localFonts: "textformat"
        case .idleDetection: "moon.zzz"
        case .storageAccess: "externaldrive"
        case .multipleDownloads: "square.and.arrow.down.on.square"
        case .other: "hand.raised"
        }
    }
}

// MARK: - BrowserSitePermissionRequest

/// A page's pending request, identified by the engine's request number.
struct BrowserSitePermissionRequest: Identifiable, Equatable {
    static let peekTabIDPrefix = "peek:"

    let id: Int
    let tabID: String
    let origin: String
    let kinds: [BrowserSitePermissionKind]
    /// Camera or microphone through CEF's media access callback, which
    /// OpenArc answers from its remembered decisions.
    let isMediaAccess: Bool

    /// The Peek card or small window that asks, whose tab ID is
    /// "peek:<session>"; nil for a tab.
    var peekSessionID: Int? {
        tabID.hasPrefix(Self.peekTabIDPrefix) ? Int(tabID.dropFirst(Self.peekTabIDPrefix.count)) : nil
    }

    /// The origin without its scheme, as prompts show it.
    var displayOrigin: String {
        guard let components = URLComponents(string: origin), let host = components.host else { return origin }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    /// The origin of a page address, for comparing it with a request's.
    static func origin(ofURLString urlString: String) -> String? {
        guard let components = URLComponents(string: urlString), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        let port = components.port.flatMap { $0 == defaultPort ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }
}

// MARK: - BrowserSitePermissionDecision

/// A remembered camera or microphone answer for one origin of one profile.
struct BrowserSitePermissionDecision: Codable, Equatable {
    let profileID: String
    let origin: String
    let kind: BrowserSitePermissionKind
    let allowed: Bool

    /// The remembered answer: false when a requested kind is blocked, true
    /// when every one is allowed, nil while one has no answer. CEF grants a
    /// camera and microphone request whole or not at all.
    static func remembered(
        for request: BrowserSitePermissionRequest,
        profileID: String,
        in decisions: [BrowserSitePermissionDecision],
    ) -> Bool? {
        guard let origin = BrowserSitePermissionRequest.origin(ofURLString: request.origin) else { return nil }
        var isComplete = true
        for kind in request.kinds {
            guard let decision = decisions.last(where: {
                $0.profileID == profileID && $0.origin == origin && $0.kind == kind
            }) else {
                isComplete = false
                continue
            }
            if !decision.allowed {
                return false
            }
        }
        return isComplete ? true : nil
    }

    /// `decisions` with the answer to every kind of the request replacing
    /// earlier answers for the same origin.
    static func recording(
        _ allowed: Bool,
        for request: BrowserSitePermissionRequest,
        profileID: String,
        in decisions: [BrowserSitePermissionDecision],
    ) -> [BrowserSitePermissionDecision] {
        guard let origin = BrowserSitePermissionRequest.origin(ofURLString: request.origin) else { return decisions }
        let kinds = Set(request.kinds.filter(\.isMediaCapture))
        return decisions.filter { !($0.profileID == profileID && $0.origin == origin && kinds.contains($0.kind)) }
            + request.kinds.filter(\.isMediaCapture).map {
                BrowserSitePermissionDecision(profileID: profileID, origin: origin, kind: $0, allowed: allowed)
            }
    }
}

// MARK: - BrowserNotificationAuthorization

/// macOS's own permission for OpenArc to show notifications, asked once
/// when the first site is allowed to.
enum BrowserNotificationAuthorization {
    static func request(completion: @escaping @Sendable (Bool) -> Void) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized,
                 .provisional:
                completion(true)
            case .denied:
                completion(false)
            case .notDetermined:
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                    completion(granted)
                } catch {
                    completion(false)
                }
            @unknown default:
                completion(false)
            }
        }
    }
}

// MARK: - BrowserMediaCaptureAuthorization

/// macOS's own permission for OpenArc to use the camera and microphone, asked
/// when a site is first allowed one. Chrome asks from its permission bubble,
/// which CEF does not run, so a page would otherwise race the system prompt.
enum BrowserMediaCaptureAuthorization {
    // MARK: Internal

    @MainActor static func request(
        _ kinds: [BrowserSitePermissionKind],
        completion: @escaping @MainActor (Bool) -> Void,
    ) {
        var mediaTypes = [AVMediaType]()
        if kinds.contains(.camera) {
            mediaTypes.append(.video)
        }
        if kinds.contains(.microphone) {
            mediaTypes.append(.audio)
        }
        request(mediaTypes[...], completion: completion)
    }

    // MARK: Private

    @MainActor private static func request(
        _ mediaTypes: ArraySlice<AVMediaType>,
        completion: @escaping @MainActor (Bool) -> Void,
    ) {
        guard let mediaType = mediaTypes.first else {
            completion(true)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            request(mediaTypes.dropFirst(), completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                Task { @MainActor in
                    if granted {
                        request(mediaTypes.dropFirst(), completion: completion)
                    } else {
                        completion(false)
                    }
                }
            }
        default:
            completion(false)
        }
    }
}

// MARK: - BrowserLocationAuthorization

/// macOS's own permission for OpenArc to use the location, asked when a site
/// is first allowed it. Chrome asks from its permission prompt,
/// which CEF does not run, so a page would otherwise never get a position.
enum BrowserLocationAuthorization {
    @MainActor static func request(completion: @escaping @MainActor (Bool) -> Void) {
        LocationAuthorizationRequester.shared.request(completion: completion)
    }
}

// MARK: - LocationAuthorizationRequester

/// Private, so the Objective-C header that imports no CoreLocation never
/// sees it.
@MainActor private final class LocationAuthorizationRequester: NSObject, CLLocationManagerDelegate {
    // MARK: Internal

    static let shared = LocationAuthorizationRequester()

    // MARK: Private

    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    private var waitingRequests = [@MainActor (Bool) -> Void]()

    /// Nil until the user answers macOS.
    private var granted: Bool? {
        switch manager.authorizationStatus {
        case .authorizedAlways,
             .authorizedWhenInUse: true
        case .notDetermined: nil
        default: false
        }
    }

    func request(completion: @escaping @MainActor (Bool) -> Void) {
        if let granted {
            completion(granted)
            return
        }
        waitingRequests.append(completion)
        if waitingRequests.count == 1 {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Also called once when the manager starts, with the current status.
    nonisolated func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        MainActor.assumeIsolated { answerWaitingRequests() }
    }

    private func answerWaitingRequests() {
        guard let granted, !waitingRequests.isEmpty else { return }
        let requests = waitingRequests
        waitingRequests = []
        for request in requests {
            request(granted)
        }
    }
}
