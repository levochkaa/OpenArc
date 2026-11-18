// BrowserTabMedia.swift

import Foundation

// MARK: - BrowserTabMediaState

/// What a tab's pages are playing, as their renderer reports it: CEF has no
/// audible signal. Present while media plays or can resume.
struct BrowserTabMediaState: Equatable {
    var isPlaying: Bool
    /// The playing media has sound: unmuted, with volume and an audio track.
    var audible: Bool
    var video: Bool
    /// The page's Media Session handles these tracks.
    var hasPreviousTrack: Bool
    var hasNextTrack: Bool
    /// The page has a video in the Picture in Picture window.
    var inPictureInPicture = false
    /// A call's microphone and camera controls, when its Media Session has them.
    var call: BrowserCallControls?
    /// The Media Session title, or empty.
    var title: String
}

// MARK: - BrowserCallControls

/// The microphone and camera of a call, as the page's Media Session offers them.
struct BrowserCallControls: Equatable {
    var canToggleMicrophone: Bool
    var canToggleCamera: Bool
    var isMicrophoneOn: Bool
    var isCameraOn: Bool
}

// MARK: - BrowserMiniPlayerItem

/// What a mini player shows for one tab.
struct BrowserMiniPlayerItem: Equatable {
    let tabID: String
    let title: String
    let faviconURL: URL?
    let pageURLString: String
    let isPlaying: Bool
    let hasPreviousTrack: Bool
    let hasNextTrack: Bool
    let isMuted: Bool
    var volume = 1.0
    /// A video, which the player can send back to Picture in Picture.
    var isVideo = false
    /// A tab that records the camera or microphone gets a call's player:
    /// microphone and camera instead of the tracks and play.
    var call: BrowserCallControls?
}

// MARK: - BrowserMediaAction

enum BrowserMediaAction: String {
    case play
    case pause
    case previousTrack = "previoustrack"
    case nextTrack = "nexttrack"
    case toggleMicrophone = "togglemicrophone"
    case toggleCamera = "togglecamera"
}

// MARK: - BrowserChromeModel + media

/// Tabs with sound show a speaker and, for those off screen, a mini
/// player above the Space dock with the previous and next track, play and
/// pause, and mute. It stays while the media is paused; its close button
/// hides it until the media plays again.
extension BrowserChromeModel {
    /// Tabs playing media with sound.
    var audibleTabIDs: Set<String> {
        Set(tabMediaStates.filter { _, state in state.isPlaying && state.audible }.map(\.key))
    }

    /// Mini players, newest first: tabs off screen whose media has played
    /// with sound and still plays or can resume. A video moved to Picture in
    /// Picture has the floating window instead. Calls, tabs recording the
    /// camera or microphone, come first.
    var miniPlayerTabIDs: [String] {
        let visible = Set(selectedTabID.map { splitPaneTabIDs(forTabID: $0) } ?? [])
        let calls = recordingTabIDs
            .filter { !visible.contains($0) && !dismissedMiniPlayerTabIDs.contains($0) }
            .sorted {
                let first = tabMediaStartOrder[$0] ?? 0
                let second = tabMediaStartOrder[$1] ?? 0
                return first != second ? first > second : $0 < $1
            }
        let media = tabMediaStates
            .filter { id, state in
                tabMediaStartOrder[id] != nil && !visible.contains(id) && !dismissedMiniPlayerTabIDs.contains(id)
                    && !(state.video && isInPictureInPicture(tabID: id))
                    && tabs.contains { $0.id == id } && !calls.contains(id)
            }
            .map(\.key)
            .sorted { (tabMediaStartOrder[$0] ?? 0) > (tabMediaStartOrder[$1] ?? 0) }
        return calls + media
    }

    /// The sidebar keeps to two mini players.
    static let maximumMiniPlayers = 2

    var miniPlayerItems: [BrowserMiniPlayerItem] {
        let calls = recordingTabIDs
        return miniPlayerTabIDs.prefix(Self.maximumMiniPlayers).compactMap { id in
            let state = tabMediaStates[id]
            let isCall = calls.contains(id)
            guard let tab = tabs.first(where: { $0.id == id }), state != nil || isCall else { return nil }
            return BrowserMiniPlayerItem(
                tabID: id,
                title: state.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? tab.displayTitle,
                faviconURL: tab.faviconURL,
                pageURLString: tab.urlString,
                isPlaying: state?.isPlaying ?? false,
                hasPreviousTrack: state?.hasPreviousTrack ?? false,
                hasNextTrack: state?.hasNextTrack ?? false,
                isMuted: isTabMuted(id: id),
                volume: tabMediaVolumes[id] ?? 1,
                isVideo: !isCall && state?.video == true,
                call: isCall
                    ? state?.call ?? BrowserCallControls(
                        canToggleMicrophone: false,
                        canToggleCamera: false,
                        isMicrophoneOn: true,
                        isCameraOn: true,
                    )
                    : nil,
            )
        }
    }

    func handleMediaStateChange(tabID: String, state: BrowserTabMediaState?) {
        if tabMediaStates[tabID]?.inPictureInPicture == true, state?.inPictureInPicture != true {
            // The window closed: the tab has a mini player again. Its close button pauses
            // the video, so one that keeps playing came back through "back to tab".
            pictureInPictureDidEnd(tabID: tabID, showsTab: state?.isPlaying == true)
        }
        guard let state else {
            tabMediaStates.removeValue(forKey: tabID)
            tabMediaStartOrder.removeValue(forKey: tabID)
            dismissedMiniPlayerTabIDs.remove(tabID)
            return
        }
        if state.isPlaying, tabMediaStates[tabID]?.isPlaying != true {
            dismissedMiniPlayerTabIDs.remove(tabID)
        }
        // Media gets a mini player once it has played with sound.
        if state.isPlaying, state.audible, tabMediaStartOrder[tabID] == nil {
            nextTabMediaStartOrder += 1
            tabMediaStartOrder[tabID] = nextTabMediaStartOrder
        }
        tabMediaStates[tabID] = state
    }

    /// The recording dot follows the page's capture streams.
    func handleCaptureChange(tabID: String, capturing: Bool) {
        if capturing {
            if !capturingTabIDs.contains(tabID) {
                dismissedMiniPlayerTabIDs.remove(tabID)
            }
            capturingTabIDs.insert(tabID)
        } else {
            capturingTabIDs.remove(tabID)
        }
    }

    /// Tabs that still exist and capture.
    var recordingTabIDs: Set<String> {
        capturingTabIDs.filter { id in tabs.contains { $0.id == id } }
    }

    func controlMedia(_ action: BrowserMediaAction, tabID: String) {
        guard tabMediaStates[tabID] != nil || action == .play else { return }
        if action == .toggleMicrophone || action == .toggleCamera,
           tabMediaStates[tabID]?.call
            .map({ action == .toggleMicrophone ? $0.canToggleMicrophone : $0.canToggleCamera })
            != true
        {
            return
        }
        controlMediaInEngine(action, tabID: tabID)
    }

    /// The mini player's close button: hidden until the tab plays anew.
    func setMediaVolume(_ volume: Double, tabID: String) {
        tabMediaVolumes[tabID] = volume
        setMediaVolumeInEngine(volume, tabID: tabID)
    }

    func dismissMiniPlayer(tabID: String) {
        guard tabMediaStates[tabID] != nil || recordingTabIDs.contains(tabID) else { return }
        dismissedMiniPlayerTabIDs.insert(tabID)
    }
}
