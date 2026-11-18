// BrowserChromeModel+Boosts.swift

import Foundation

// MARK: - BrowserBoostZapSession

/// Zapping in one tab's page: each clicked element joins the host's Boost.
struct BrowserBoostZapSession: Equatable {
    static let pollInterval: TimeInterval = 0.25
    /// Polls the page may miss in a row, such as while it is busy, before zapping ends.
    static let missedPollLimit = 8

    let id = UUID()
    let tabID: String
    let host: String
    var missedPolls = 0
}

// MARK: - BrowserChromeModel + Boosts

extension BrowserChromeModel {
    /// The host whose Boost the current page edits; nil for pages that are not websites.
    var currentBoostHost: String? {
        currentTab.flatMap { userPreferencesStore.boosts.editableHost(forURLString: $0.urlString) }
    }

    /// Incognito windows neither run nor edit Boosts.
    var canEditBoost: Bool {
        !isIncognito && currentBoostHost != nil
    }

    /// The current page's site, or a domain above it, has a Boost.
    var currentSiteHasBoost: Bool {
        currentTab.flatMap { userPreferencesStore.boosts.matchingBoost(forURLString: $0.urlString) } != nil
    }

    /// A Boost is adding something to the current page.
    var currentSiteHasActiveBoost: Bool {
        currentTab.flatMap { userPreferencesStore.boosts.applicableBoost(forURLString: $0.urlString) } != nil
    }

    /// The host's Boost, or an empty one that is not saved yet.
    func boost(forHost host: String) -> BrowserBoost {
        userPreferencesStore.boosts.boost(forHost: host) ?? BrowserBoost(host: host)
    }

    func updateBoost(host: String, _ change: (inout BrowserBoost) -> Void) {
        userPreferencesStore.boosts.updateBoost(host: host, change)
    }

    func removeBoost(host: String) {
        if boostZapSession?.host == host {
            stopZapping()
        }
        userPreferencesStore.boosts.removeBoost(host: host)
    }

    /// Boost This Site: opens the editor for the current page's site.
    @discardableResult func editCurrentSiteBoost() -> Bool {
        guard let host = currentBoostHost, let onEditBoost else { return false }
        onEditBoost(host)
        return true
    }

    /// Open pages take the new boosts: a changed stylesheet is replaced in
    /// place, changed JavaScript reloads the page.
    func applyBoostChange(from old: [BrowserBoost], to new: [BrowserBoost]) {
        guard !isIncognito else { return }
        for tab in tabs {
            switch BrowserBoostRefresh.refresh(forURLString: tab.urlString, from: old, to: new) {
            case .none:
                break
            case .restyle(let script):
                evaluateJavaScript(script, inTabWithID: tab.id) { _ in }
            case .reload:
                evaluateJavaScript("location.reload(); undefined", inTabWithID: tab.id) { _ in }
            }
        }
    }

    // MARK: Zapping

    /// Lets the user click elements of the current page to hide them for the host.
    func startZapping(host: String) {
        guard let tabID = selectedTabID else { return }
        stopZapping()
        let session = BrowserBoostZapSession(tabID: tabID, host: host)
        boostZapSession = session
        evaluateJavaScript(BrowserBoostScript.zapStartScript, inTabWithID: tabID) { [weak self] answer in
            guard let self, boostZapSession?.id == session.id else { return }
            guard answer == "started" || answer == "active" else {
                boostZapSession = nil
                return
            }
            scheduleZapPoll(session.id)
        }
    }

    /// Ends zapping, keeping what was clicked so far.
    func stopZapping() {
        guard let session = boostZapSession else { return }
        boostZapSession = nil
        evaluateJavaScript(BrowserBoostScript.zapStopScript, inTabWithID: session.tabID) { [weak self] answer in
            self?.recordZapped(BrowserBoostScript.zapPoll(fromJSON: answer)?.picked ?? [], host: session.host)
        }
    }

    /// A poll's answer: the elements clicked since the last one, and whether
    /// zapping ended in the page, by Escape or by leaving it.
    func handleZapPoll(_ answer: String?, sessionID: UUID) {
        guard var session = boostZapSession, session.id == sessionID else { return }
        guard let poll = BrowserBoostScript.zapPoll(fromJSON: answer) else {
            session.missedPolls += 1
            if session.missedPolls >= BrowserBoostZapSession.missedPollLimit {
                boostZapSession = nil
            } else {
                boostZapSession = session
                scheduleZapPoll(sessionID)
            }
            return
        }
        recordZapped(poll.picked, host: session.host)
        guard boostZapSession?.id == sessionID else { return }
        if poll.done {
            boostZapSession = nil
            return
        }
        if session.missedPolls > 0 {
            session.missedPolls = 0
            boostZapSession = session
        }
        scheduleZapPoll(sessionID)
    }

    private func scheduleZapPoll(_ sessionID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + BrowserBoostZapSession.pollInterval) { [weak self] in
            self?.pollZap(sessionID)
        }
    }

    private func pollZap(_ sessionID: UUID) {
        guard let session = boostZapSession, session.id == sessionID else { return }
        // Zapping belongs to the page it started in.
        guard selectedTabID == session.tabID else {
            stopZapping()
            return
        }
        evaluateJavaScript(BrowserBoostScript.zapPollScript, inTabWithID: session.tabID) { [weak self] answer in
            self?.handleZapPoll(answer, sessionID: sessionID)
        }
    }

    /// Zapped elements stay hidden, so their Boost turns on.
    private func recordZapped(_ selectors: [String], host: String) {
        guard !selectors.isEmpty else { return }
        updateBoost(host: host) { boost in
            boost.zappedSelectors += selectors
            boost.isEnabled = true
        }
    }
}
