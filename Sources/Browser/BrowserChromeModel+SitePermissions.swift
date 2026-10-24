import Foundation

// MARK: - Site permissions

/// Pages ask for the camera, microphone, location and other permissions
/// through the engine; the window shows one prompt at a time for the tabs on
/// screen. Camera and microphone answers are remembered per
/// profile, outside incognito windows; Chromium remembers the others.
extension BrowserChromeModel {
    /// The oldest request of the selected tab or a pane shown beside it.
    var visibleSitePermissionRequest: BrowserSitePermissionRequest? {
        guard let selectedTabID else { return nil }
        let visible = Set(splitPaneTabIDs(forTabID: selectedTabID))
        return sitePermissionRequests.first { visible.contains($0.tabID) }
    }

    func handleSitePermissionRequest(_ request: BrowserSitePermissionRequest) {
        guard !request.kinds.isEmpty else {
            resolveSitePermissionInEngine(request.id, allowed: nil)
            return
        }
        if request.isMediaAccess, !windowMode.isIncognito,
           let remembered = BrowserSitePermissionDecision.remembered(
               for: request,
               profileID: profile.id,
               in: userPreferencesStore.sitePermissionDecisions
           )
        {
            resolveSitePermissionInEngine(request.id, allowed: remembered)
            return
        }
        sitePermissionRequests.append(request)
    }

    /// Allow or Block in the prompt.
    func answerSitePermissionRequest(id: Int, allowed: Bool) {
        guard let index = sitePermissionRequests.firstIndex(where: { $0.id == id }) else { return }
        let request = sitePermissionRequests.remove(at: index)
        if request.isMediaAccess, !windowMode.isIncognito {
            userPreferencesStore.sitePermissionDecisions = BrowserSitePermissionDecision.recording(
                allowed,
                for: request,
                profileID: profile.id,
                in: userPreferencesStore.sitePermissionDecisions
            )
        }
        guard allowed, request.kinds.contains(.notifications) else {
            resolveSitePermissionInEngine(id, allowed: allowed)
            return
        }
        // Notifications also need the system's permission for TheBrowser.
        requestSystemNotificationAuthorization { [weak self] granted in
            DispatchQueue.main.async {
                self?.resolveSitePermissionInEngine(id, allowed: granted)
            }
        }
    }

    /// The prompt's close button or Escape: no answer, nothing remembered.
    func dismissSitePermissionRequest(id: Int) {
        guard let index = sitePermissionRequests.firstIndex(where: { $0.id == id }) else { return }
        sitePermissionRequests.remove(at: index)
        resolveSitePermissionInEngine(id, allowed: nil)
    }

    /// The engine withdrew the request.
    func handleSitePermissionRequestDismissed(id: Int) {
        sitePermissionRequests.removeAll { $0.id == id }
    }

    /// A page that leaves the origin it asked for withdraws its camera and
    /// microphone requests; Chromium withdraws its own prompts.
    func withdrawSitePermissionRequests(forTabID tabID: String, urlString: String) {
        let origin = BrowserSitePermissionRequest.origin(ofURLString: urlString)
        let stale = sitePermissionRequests.filter {
            $0.tabID == tabID && $0.isMediaAccess
                && BrowserSitePermissionRequest.origin(ofURLString: $0.origin) != origin
        }
        for request in stale {
            dismissSitePermissionRequest(id: request.id)
        }
    }

    /// Camera and microphone answers this profile remembers, by origin.
    var rememberedSitePermissions: [BrowserSitePermissionDecision] {
        userPreferencesStore.sitePermissionDecisions.filter { $0.profileID == profile.id }
    }

    func forgetSitePermissions(forOrigin origin: String) {
        userPreferencesStore.sitePermissionDecisions.removeAll { $0.profileID == profile.id && $0.origin == origin }
    }
}
