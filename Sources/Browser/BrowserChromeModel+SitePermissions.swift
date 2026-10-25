import Foundation

// MARK: - Site permissions

/// Pages ask for the camera, microphone, location and other permissions
/// through the engine; the window shows one prompt at a time for the tabs on
/// screen. Camera and microphone answers are remembered per
/// profile, or by an incognito window until it closes; Chromium remembers
/// the others. The engine withdraws a page's requests when the page goes.
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
        if request.isMediaAccess,
           let remembered = BrowserSitePermissionDecision.remembered(
               for: request,
               profileID: profile.id,
               in: sitePermissionDecisions
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
        guard allowed, request.kinds.contains(.notifications) else {
            resolveSitePermissionInEngine(id, allowed: allowed)
            if request.isMediaAccess {
                // Also answers the origin's other waiting requests.
                sitePermissionDecisions = BrowserSitePermissionDecision.recording(
                    allowed,
                    for: request,
                    profileID: profile.id,
                    in: sitePermissionDecisions
                )
            }
            return
        }
        // Notifications also need the system's permission for TheBrowser. A
        // system refusal leaves the site unanswered: Chromium would keep a
        // Block after the user turns notifications on in System Settings.
        requestSystemNotificationAuthorization { [weak self] granted in
            DispatchQueue.main.async {
                self?.resolveSitePermissionInEngine(id, allowed: granted ? true : nil)
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

    /// Camera and microphone answers this window uses: the profile's, or an
    /// incognito window's own, which close with it. Setting them answers the
    /// waiting requests they now cover; the profile's do so in every window.
    var sitePermissionDecisions: [BrowserSitePermissionDecision] {
        get {
            windowMode.isIncognito ? incognitoSitePermissionDecisions : userPreferencesStore.sitePermissionDecisions
        }
        set {
            if windowMode.isIncognito {
                incognitoSitePermissionDecisions = newValue
                resolveSitePermissionRequests(coveredBy: newValue)
            } else {
                userPreferencesStore.sitePermissionDecisions = newValue
            }
        }
    }

    /// Camera and microphone answers this profile remembers, by origin.
    var rememberedSitePermissions: [BrowserSitePermissionDecision] {
        sitePermissionDecisions.filter { $0.profileID == profile.id }
    }

    func forgetSitePermissions(forOrigin origin: String) {
        sitePermissionDecisions.removeAll { $0.profileID == profile.id && $0.origin == origin }
    }

    /// Answers the waiting camera and microphone requests that `decisions`
    /// cover, for example another tab's request to the origin just allowed.
    func resolveSitePermissionRequests(coveredBy decisions: [BrowserSitePermissionDecision]) {
        let covered = sitePermissionRequests.compactMap { request -> (id: Int, allowed: Bool)? in
            guard request.isMediaAccess,
                  let allowed = BrowserSitePermissionDecision.remembered(
                      for: request,
                      profileID: profile.id,
                      in: decisions
                  )
            else { return nil }
            return (request.id, allowed)
        }
        guard !covered.isEmpty else { return }
        let ids = Set(covered.map(\.id))
        sitePermissionRequests.removeAll { ids.contains($0.id) }
        for answer in covered {
            resolveSitePermissionInEngine(answer.id, allowed: answer.allowed)
        }
    }
}
