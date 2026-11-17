// BrowserMiniPlayerTests.swift

import AppKit
import Testing

// MARK: - BrowserMiniPlayerTests

@Suite(.serialized)
@MainActor struct BrowserMiniPlayerTests {
    // MARK: Internal

    @Test func tabsOffScreenWithSoundGetMiniPlayersThatStayWhilePaused() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        let x = f.id("x")
        let y = f.id("y")
        let z = f.id("z")
        f.model.selectTab(id: x)
        play(f, x, audible: true)
        #expect(f.model.audibleTabIDs == [x])
        #expect(f.model.miniPlayerTabIDs.isEmpty, "The tab on screen has no player")

        f.model.selectTab(id: y)
        #expect(f.model.miniPlayerTabIDs == [x])
        let item = f.model.miniPlayerItems.first
        #expect(item?.title == "Song" && item?.isPlaying == true && item?.hasNextTrack == true)

        // Paused media keeps its player; media that never had sound gets none.
        play(f, x, audible: false, playing: false)
        #expect(f.model.miniPlayerTabIDs == [x] && f.model.audibleTabIDs.isEmpty)
        play(f, z, audible: false)
        #expect(f.model.miniPlayerTabIDs == [x])

        // Close hides it until the media plays again.
        f.model.dismissMiniPlayer(tabID: x)
        #expect(f.model.miniPlayerTabIDs.isEmpty)
        play(f, x, audible: true)
        #expect(f.model.miniPlayerTabIDs == [x])

        // Newest first, two at most; stopped media and closed tabs drop out.
        play(f, z, audible: true)
        #expect(f.model.miniPlayerTabIDs == [z, x])
        f.driver.onMediaStateChanged?(z, nil)
        #expect(f.model.miniPlayerTabIDs == [x])
        f.driver.emitClose(id: x)
        #expect(f.model.tabMediaStates[x] == nil)
    }

    @Test func closingThePictureInPictureWindowBringsTheMiniPlayerBack() {
        let f = SidebarDragFixture(pinned: [], temporary: ["x", "y"])
        let x = f.id("x")
        f.model.selectTab(id: x)
        var state = BrowserTabMediaState(
            isPlaying: true, audible: true, video: true, hasPreviousTrack: false, hasNextTrack: false, title: "",
        )
        f.model.handleMediaStateChange(tabID: x, state: state)
        f.model.selectTab(id: f.id("y"))
        state.inPictureInPicture = true
        f.model.handleMediaStateChange(tabID: x, state: state)
        #expect(f.model.isInPictureInPicture(tabID: x))
        #expect(f.model.miniPlayerTabIDs.isEmpty)
        state.inPictureInPicture = false
        state.isPlaying = false
        f.model.handleMediaStateChange(tabID: x, state: state)
        #expect(!f.model.isInPictureInPicture(tabID: x))
        #expect(f.model.miniPlayerTabIDs == [x], "Closing pauses the video and leaves the tab where it is")
    }

    @Test func backToTabInThePictureInPictureWindowShowsTheTab() {
        let f = SidebarDragFixture(pinned: [], temporary: ["x", "y"])
        let x = f.id("x")
        f.model.selectTab(id: x)
        var state = BrowserTabMediaState(
            isPlaying: true, audible: true, video: true, hasPreviousTrack: false, hasNextTrack: false, title: "",
        )
        f.model.handleMediaStateChange(tabID: x, state: state)
        f.model.selectTab(id: f.id("y"))
        state.inPictureInPicture = true
        f.model.handleMediaStateChange(tabID: x, state: state)
        state.inPictureInPicture = false
        f.model.handleMediaStateChange(tabID: x, state: state)
        #expect(f.model.selectedTabID == x, "It keeps playing, so the window asked for the tab")
    }

    @Test func aVideoPushedOutOfPictureInPictureByAnotherStaysBehind() {
        let f = SidebarDragFixture(pinned: [], temporary: ["x", "y", "z"])
        let x = f.id("x")
        let y = f.id("y")
        let z = f.id("z")
        let playing = BrowserTabMediaState(
            isPlaying: true, audible: true, video: true, hasPreviousTrack: false, hasNextTrack: false, title: "",
        )
        var inWindow = playing
        inWindow.inPictureInPicture = true
        f.model.selectTab(id: x)
        f.model.handleMediaStateChange(tabID: x, state: playing)
        f.model.handleMediaStateChange(tabID: y, state: playing)
        f.model.selectTab(id: y)
        f.model.handleMediaStateChange(tabID: x, state: inWindow)
        // Leaving the second video moves it into the one window, which x leaves still playing.
        f.model.selectTab(id: z)
        f.model.handleMediaStateChange(tabID: y, state: inWindow)
        f.model.handleMediaStateChange(tabID: x, state: playing)
        #expect(f.model.selectedTabID == z, "Not taken back to x, which would push y out in turn")
    }

    @Test func pictureInPictureCanBeOpenedByHand() {
        let f = SidebarDragFixture(pinned: [], temporary: ["x"])
        let x = f.id("x")
        f.model.selectTab(id: x)
        #expect(!f.model.togglePictureInPicture(), "Nothing to move without a video")
        f.model.handleMediaStateChange(tabID: x, state: BrowserTabMediaState(
            isPlaying: true, audible: false, video: true, hasPreviousTrack: false, hasNextTrack: false, title: "",
        ))
        #expect(f.model.togglePictureInPicture())
        #expect(f.driver.pictureInPictureToggleCount == 1)
    }

    @Test func aVideoInPictureInPictureHasNoMiniPlayer() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        let x = f.id("x")
        let y = f.id("y")
        f.model.selectTab(id: x)
        play(f, x, audible: true, video: true)
        f.model.selectTab(id: y)
        #expect(f.model.isInPictureInPicture(tabID: x))
        #expect(f.model.miniPlayerTabIDs.isEmpty)
    }

    @Test func controlsReachTheEngineAndBackToTabShowsTheTab() throws {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        let x = f.id("x")
        let y = f.id("y")
        f.model.selectTab(id: y)
        play(f, x, audible: true)
        let stack = BrowserMiniPlayerStackNSView(frame: NSRect(x: 0, y: 0, width: 212, height: 32))
        stack.onAction = { id, action in
            switch action {
            case .backToTab: f.model.selectTab(id: id)
            case .playPause: f.model.controlMedia(.pause, tabID: id)
            case .nextTrack: f.model.controlMedia(.nextTrack, tabID: id)
            default: break
            }
        }
        stack.update(items: f.model.miniPlayerItems)
        let player = try #require(stack.players.first)
        player.onAction(.playPause)
        player.onAction(.nextTrack)
        #expect(f.driver.mediaControls.map(\.action) == [.pause, .nextTrack])
        #expect(f.driver.mediaControls.allSatisfy { $0.tabID == x })
        player.onAction(.backToTab)
        #expect(f.model.selectedTabID == x)
    }

    @Test func playersLayOutTheirControlsAndGrowUpwardOnHover() throws {
        let stack = BrowserMiniPlayerStackNSView(frame: .zero)
        var heightChanges = 0
        stack.onHeightChange = { heightChanges += 1 }
        let items = ["a", "b"].map { id in
            BrowserMiniPlayerItem(
                tabID: id,
                title: "Title \(id)",
                faviconURL: nil,
                pageURLString: "https://\(id).example",
                isPlaying: id == "a",
                hasPreviousTrack: false,
                hasNextTrack: true,
                isMuted: false,
            )
        }
        stack.update(items: items)
        let collapsed: CGFloat = 32 * 2 + 6
        #expect(stack.reservedHeight == collapsed)
        stack.frame = NSRect(x: 0, y: 0, width: 212, height: stack.currentHeight)
        stack.layoutSubtreeIfNeeded()
        // Newest ("a") nearest the dock, at the bottom.
        #expect(stack.players.map { player in player.item?.tabID } == ["b", "a"])
        let newest = try #require(stack.players.last)
        #expect(newest.frame.maxY == stack.bounds.height)
        newest.layoutSubtreeIfNeeded()
        let tab = try #require(view("browser.mini-player.tab", in: newest))
        let play = try #require(view("browser.mini-player.play-pause", in: newest))
        let mute = try #require(view("browser.mini-player.mute", in: newest))
        #expect(tab.frame == NSRect(x: 10, y: 4, width: 24, height: 24))
        #expect(play.frame.minX == 94 && mute.frame.minX == 178)
        #expect((view("browser.mini-player.previous", in: newest) as? NSButton)?.isEnabled == false)
        #expect(play.accessibilityLabel() == BrowserStrings.miniPlayerPause)

        // Hover adds the title row above the controls; the list keeps its room.
        newest.setExpanded(true)
        #expect(heightChanges >= 2)
        #expect(newest.preferredHeight == 66)
        let expanded: CGFloat = 66 + 32 + 6
        #expect(stack.reservedHeight == collapsed)
        #expect(stack.currentHeight == expanded)
        stack.frame = NSRect(x: 0, y: 0, width: 212, height: stack.currentHeight)
        stack.layoutSubtreeIfNeeded()
        newest.layoutSubtreeIfNeeded()
        #expect(newest.frame.height == 66)
        #expect(try #require(view("browser.mini-player.close", in: newest)).isHidden == false)
        #expect(play.frame.minY == 38)
    }

    // MARK: Private

    private func play(
        _ f: SidebarDragFixture,
        _ id: String,
        audible: Bool,
        playing: Bool = true,
        video: Bool = false,
    ) {
        f.driver.onMediaStateChanged?(id, BrowserTabMediaState(
            isPlaying: playing,
            audible: audible,
            video: video,
            hasPreviousTrack: false,
            hasNextTrack: true,
            title: "Song",
        ))
    }

    private func view(_ identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = view(identifier, in: subview) {
                return match
            }
        }
        return nil
    }
}
