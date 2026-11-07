// BrowserSpaceThemeTests.swift

import AppKit
import Testing

// MARK: - BrowserSpaceThemeTests

@Suite(.serialized)
@MainActor struct BrowserSpaceThemeTests {
    private static let orange = BrowserSpaceTheme.Color(1, 0.522, 0.344)

    @Test func themesSurviveTheStoreButNotEquality() throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SpaceThemes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("session.sqlite")
        let stored = try #require(BrowserSpaceTheme(key: Self.orange).stored)
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "s", title: "Work", systemImageName: "star", colorName: stored),
                .init(id: "t", title: "Home", systemImageName: "house"),
            ],
            tabs: [.init(id: "a", urlString: "https://a.example", spaceID: "s")],
        )
        do {
            let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
            store.saveSnapshot(snapshot)
        }
        let reopened = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(try #require(reopened.loadSnapshot()?.spaces).map(\.colorName) == [stored, nil])
        #expect(
            BrowserSpaceSessionSnapshot(id: "s", title: "Work", systemImageName: "star", colorName: stored)
                == BrowserSpaceSessionSnapshot(id: "s", title: "Work", systemImageName: "star"),
            "Themes are local, so sync checks ignore them",
        )
    }

    @Test func spaceProfilesSurviveTheStoreButNotEquality() throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SpaceProfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("session.sqlite")
        do {
            let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
            store.saveSnapshot(BrowserTabSessionSnapshot(
                spaces: [
                    .init(id: "s", title: "Work", systemImageName: "star", profileDirectory: "Profile 2"),
                    .init(id: "t", title: "Home", systemImageName: "house"),
                ],
                tabs: [.init(id: "a", urlString: "https://a.example", spaceID: "s")],
            ))
        }
        let reopened = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(try #require(reopened.loadSnapshot()?.spaces).map(\.profileDirectory) == ["Profile 2", nil])
        #expect(
            BrowserSpaceSessionSnapshot(id: "s", title: "Work", systemImageName: "star", profileDirectory: "Profile 2")
                == BrowserSpaceSessionSnapshot(id: "s", title: "Work", systemImageName: "star"),
            "Profiles are local, so sync checks ignore them",
        )
    }

    @Test func colorNamesFromOlderVersionsBecomeThemes() throws {
        let theme = try #require(BrowserSpaceTheme(stored: "teal"))
        #expect(theme.colors.count == 1)
        #expect(BrowserSpaceTheme(stored: "not a color") == nil)
    }

    @Test func storedThemesRoundTripWithStableBytes() throws {
        var theme = BrowserSpaceTheme(key: Self.orange, colorCount: 3, wheel: .analogous)
        theme.noise = 0.5
        theme.texture = .denim
        theme.mode = .dark
        let stored = try #require(theme.stored)
        #expect(BrowserSpaceTheme(stored: stored) == theme)
        #expect(theme.stored == stored, "Same theme, same bytes, or each save looks like a change")
    }

    @Test func aSpacesThemeShowsWhileItIsSelected() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        let theme = BrowserSpaceTheme(key: Self.orange)
        #expect(f.model.selectedSpaceTheme == nil, "Spaces start neutral")
        #expect(f.model.setTheme(theme, forSpaceID: "s"))
        #expect(!f.model.setTheme(theme, forSpaceID: "s"))
        #expect(!f.model.setTheme(theme, forSpaceID: "missing"))
        #expect(f.model.selectedSpaceTheme == theme)
        let saved = try #require(f.store.savedSnapshots.last?.spaces)
        #expect(saved.first { $0.id == "s" }?.colorName == theme.stored)
        f.model.selectSpace(id: "t")
        #expect(f.model.selectedSpaceTheme == nil)
        f.model.selectSpace(id: "s")
        #expect(f.model.setTheme(nil, forSpaceID: "s") && f.model.selectedSpaceTheme == nil)
    }

    @Test func aThemeWithoutColorsIsTheNeutralWindow() {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.setTheme(BrowserSpaceTheme(key: Self.orange), forSpaceID: "s")
        f.model.setTheme(BrowserSpaceTheme(), forSpaceID: "s")
        #expect(f.model.selectedSpaceTheme == nil)
    }

    @Test func editsDuringAGestureDoNotSaveUntilItEnds() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        let before = f.store.savedSnapshots.count
        var theme = BrowserSpaceTheme(key: Self.orange)
        #expect(f.model.setTheme(theme, forSpaceID: "s", persist: false))
        theme.intensity = 0.5
        #expect(f.model.setTheme(theme, forSpaceID: "s", persist: false))
        #expect(f.store.savedSnapshots.count == before)
        f.model.setTheme(theme, forSpaceID: "s")
        let saved = try #require(f.store.savedSnapshots.last?.spaces)
        #expect(saved.first { $0.id == "s" }?.colorName == theme.stored)
    }

    @Test func theSpaceMenuOpensTheEditor() throws {
        // NSMenu sends the action through NSApp, which a lone run of this suite
        // has not created yet.
        _ = NSApplication.shared
        let space = BrowserChromeModel.Space(
            id: "s", title: "Work", systemImageName: "star", isPinnedSectionCollapsed: false, selectedTabID: nil,
        )
        var opened = 0
        let menu = BrowserNativeMenus.space(
            space,
            canDelete: true,
            onRename: {},
            onChangeIcon: { _ in },
            onEditTheme: { opened += 1 },
            onDelete: {},
        )
        let index = try #require(menu.items.firstIndex { $0.title == BrowserStrings.spaceEditThemeAction })
        menu.performActionForItem(at: index)
        #expect(opened == 1)
    }

    @Test func aThemeOnlyChangeIsNotDroppedAsADuplicateWrite() {
        func write(_ color: String?) -> BrowserSessionWrite {
            BrowserSessionWrite(
                snapshot: .init(
                    spaces: [.init(id: "s", title: "Work", systemImageName: "star", colorName: color)],
                    tabs: [],
                ),
                origin: .local(syncMove: nil),
            )
        }
        var buffer = BrowserSessionWriteBuffer()
        let accepted = [buffer.append(write(nil)), buffer.append(write("teal"))]
        #expect(accepted == [true, true] && buffer.writes.count == 2)
    }

    @Test func arcSpacesBringTheirThemes() throws {
        let json = #"""
        {"sidebar": {"containers": [{}, {
          "spaces": ["S1", {"id": "S1", "title": "Work", "containerIDs": [], "customInfo": {"windowTheme": {"background":
            {"single": {"_0": {"style": {"color": {"_0": {"blendedGradient": {"_0": {
              "baseColors": [{"red": 1, "green": 0.5, "blue": 0.25, "alpha": 1}, {"red": 0.9, "green": 0.9, "blue": 0.25, "alpha": 1}],
              "overlayColors": [{"red": 0, "green": 0, "blue": 0, "alpha": 0}, {"red": 1, "green": 0.3, "blue": 0.6, "alpha": 1}],
              "modifiers": {"noiseFactor": 0.5, "intensityFactor": 0.25, "overlay": "denim"},
              "wheel": {"analogous": {}}}}}}}}}}}}},
            "S2", {"id": "S2", "title": "Home", "containerIDs": []}],
          "items": [],
          "topAppsContainerIDs": []
        }]}}
        """#
        let sidebar = try BrowserArcSidebar(data: Data(json.utf8))
        let theme = try #require(sidebar.spaces.first?.theme)
        #expect(theme.colors.count == 3)
        #expect(theme.wheel == .analogous && theme.texture == .denim)
        #expect(theme.noise == 0.5 && theme.intensity == 0.25)
        #expect(sidebar.spaces.last?.theme == nil)
    }

    // MARK: Color rules

    @Test func hueAndLightnessRoundTripThroughDisplayP3() {
        let (hue, saturation, lightness) = Self.orange.hsl
        #expect(abs(hue - 17.6) < 0.2)
        #expect(abs(saturation - 0.816) < 0.005)
        #expect(abs(lightness - 0.661) < 0.005)
        let rebuilt = BrowserSpaceTheme.Color(hue: hue, saturation: saturation, lightness: lightness)
        #expect(abs(rebuilt.red - Self.orange.red) < 0.002)
        #expect(abs(rebuilt.green - Self.orange.green) < 0.002)
        #expect(abs(rebuilt.blue - Self.orange.blue) < 0.002)
    }

    @Test func addedColorsFollowTheWheel() {
        var theme = BrowserSpaceTheme(key: Self.orange)
        theme.addColor()
        #expect(abs(theme.colors[1].hsl.hue - 197.6) < 0.5, "One more color: the far side of the wheel")
        theme.addColor()
        #expect(abs(theme.colors[1].hsl.hue - 167.6) < 0.5)
        #expect(abs(theme.colors[2].hsl.hue - 227.6) < 0.5)
        #expect(!theme.canAddColor)
        let analogous = BrowserSpaceTheme(key: Self.orange, colorCount: 3, wheel: .analogous)
        #expect(abs(analogous.colors[1].hsl.hue - 57.6) < 0.5)
        #expect(abs(analogous.colors[2].hsl.hue - 337.6) < 0.5)
    }

    @Test func removingEveryColorLeavesAnEmptyTheme() {
        var theme = BrowserSpaceTheme(key: Self.orange, colorCount: 3, wheel: .analogous)
        theme.removeColor()
        #expect(theme.colors.count == 2)
        theme.removeColor()
        #expect(theme.colors.count == 1)
        theme.removeColor()
        #expect(theme.colors.isEmpty && theme.palette == nil && !theme.canAddColor)
    }

    @Test func aPresetsKnobSitsAtItsUsualDistanceFromTheCenter() throws {
        let theme = BrowserSpaceTheme(key: Self.orange)
        let knob = try #require(theme.knobPositions.first)
        #expect(abs(hypot(knob.x - 170, knob.y - 170) - 84) < 1)
        #expect(abs(atan2(knob.y - 170, knob.x - 170) * 180 / .pi - 17.6) < 0.5)
    }

    @Test func movingTheKnobSetsHueFromAngleAndLightnessFromDistance() {
        var theme = BrowserSpaceTheme(key: Self.orange)
        let center = theme.lightnessAtCenter
        theme.moveKey(to: CGPoint(x: 170, y: 280))
        let (hue, saturation, lightness) = theme.colors[0].hsl
        #expect(abs(hue - 90) < 0.5)
        #expect(abs(saturation - 0.816) < 0.01)
        #expect(abs(lightness - (center + 110 * BrowserSpaceTheme.lightnessPerPoint)) < 0.005)
    }

    @Test func allKnobsMoveTogether() {
        var theme = BrowserSpaceTheme(key: Self.orange, colorCount: 3, wheel: .analogous)
        theme.moveKey(to: CGPoint(x: 280, y: 170))
        #expect(abs(theme.colors[0].hsl.hue) < 0.5 || abs(theme.colors[0].hsl.hue - 360) < 0.5)
        #expect(abs(theme.colors[1].hsl.hue - 40) < 0.5)
        #expect(abs(theme.colors[2].hsl.hue - 320) < 0.5)
    }

    @Test func contentIsDarkOnBrightColorsAndLightOnDarkOnes() throws {
        for (color, isLight) in [
            (BrowserSpaceTheme.Color(0.5, 0.5, 0.5), true),
            (BrowserSpaceTheme.Color(0.4, 0.4, 0.4), false),
            (BrowserSpaceTheme.Color(0.4, 0.404, 0.537), false),
            (BrowserSpaceTheme.Color(0.692, 0.427, 0.25), true),
            (BrowserSpaceTheme.Color(0, 0, 0), false),
        ] {
            #expect(try #require(BrowserSpaceTheme(key: color).palette).isLightContent == isLight)
        }
    }

    @Test func paletteMatchesTheKeyColor() throws {
        let palette = try #require(BrowserSpaceTheme(key: Self.orange).palette)
        #expect(abs(palette.tintedLight.hsl.lightness - 0.94) < 0.005)
        #expect(abs(palette.shadedDark.hsl.lightness - 0.33) < 0.005)
        #expect(abs(palette.title.red - 0.196) < 0.01, "Bright theme: dark title from the shaded color")
    }

    @Test func aFolderTakingADropIsMarkedByTheMostContrastingColorHalfCovered() throws {
        let bright = try #require(BrowserSpaceTheme(key: Self.orange).palette)
        #expect(bright.dropTargetBand == bright.shadedDark.nsColor(alpha: 0.5))
        let dark = try #require(BrowserSpaceTheme(key: BrowserSpaceTheme.Color(0.2, 0.15, 0.14)).palette)
        #expect(!dark.isLightContent)
        #expect(dark.dropTargetBand == dark.tintedLight.nsColor(alpha: 0.45))
    }

    // MARK: Rendering

    @Test func noColorsDrawsNothing() {
        #expect(BrowserSpaceThemeRenderer.pixels(for: BrowserSpaceTheme(), aspect: 1.6, isDark: true) == nil)
    }

    @Test func coverageFollowsIntensity() {
        var theme = BrowserSpaceTheme(key: Self.orange)
        #expect(abs(theme.coverage - 0.75) < 0.001)
        theme.intensity = 0
        #expect(abs(theme.coverage - 0.2) < 0.001)
    }

    @Test func aGradientRunsFromTheKeyColorToTheSecondColor() throws {
        let theme = BrowserSpaceTheme(key: Self.orange, colorCount: 2, wheel: .analogous)
        let (values, width, height) = try #require(
            BrowserSpaceThemeRenderer.pixels(for: theme, aspect: 1.6, isDark: true, width: 64),
        )
        #expect(width == 64 && height == 40)
        func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let i = (y * width + x) * 4
            return SIMD4(values[i], values[i + 1], values[i + 2], values[i + 3])
        }
        let start = pixel(0, 0)
        let end = pixel(63, 39)
        #expect(start.y < end.y, "Orange to yellow gains green along the axis")
        #expect(abs(start.w - (0.75 + 0.25 * 0.175)) < 0.01, "Colors over the black backing")
        #expect(pixel(63, 39) == pixel(63, 39))
    }

    @Test func aLightBackingIsWhiteAtHalfStrength() throws {
        let theme = BrowserSpaceTheme(key: BrowserSpaceTheme.Color(0, 0, 0))
        let dark = try #require(BrowserSpaceThemeRenderer.pixels(for: theme, aspect: 1, isDark: true, width: 16))
        let light = try #require(BrowserSpaceThemeRenderer.pixels(for: theme, aspect: 1, isDark: false, width: 16))
        #expect(dark.values[0] < 0.01)
        #expect(abs(light.values[0] - 0.25 * 0.5) < 0.01)
        #expect(abs(light.values[3] - (0.75 + 0.25 * 0.5)) < 0.01)
    }

    @Test func aThirdColorRisesFromTheBottom() throws {
        let theme = BrowserSpaceTheme(key: Self.orange, colorCount: 3, wheel: .analogous)
        let (values, width, height) = try #require(
            BrowserSpaceThemeRenderer.pixels(for: theme, aspect: 1, isDark: true, width: 32),
        )
        let top = values[0 * 4 + 3]
        let bottom = values[(height - 1) * width * 4 + 3]
        #expect(bottom > top, "The overlay adds coverage toward the bottom edge")
    }

    @Test func texturesAreStableAndDarkenByTheirOwnAmount() {
        for texture in BrowserSpaceTheme.Texture.allCases {
            let first = BrowserSpaceThemeTexture.darkness(texture)
            #expect(first == BrowserSpaceThemeTexture.darkness(texture), "Same pixels on each launch")
            #expect(first.count == 200 * 200)
            #expect(first.allSatisfy { $0 >= -0.01 && $0 <= 1 })
            #expect(BrowserSpaceThemeTexture.tile(texture).size == NSSize(width: 100, height: 100))
        }
        #expect(BrowserSpaceTheme.Texture.tweed.next == .grain)
    }

    // MARK: Editor

    @Test func presetsFillFivePagesOfNine() {
        #expect(BrowserSpaceThemePresets.pages.count == 5)
        #expect(BrowserSpaceThemePresets.pages.allSatisfy { $0.count == 9 })
        #expect(BrowserSpaceThemePresets.pages[1].allSatisfy { $0.colors.count == 3 })
    }

    @Test func theEditorEditsAndUndoes() throws {
        let editor = BrowserSpaceThemeEditorViewController(theme: BrowserSpaceTheme(key: Self.orange))
        var changes = [(BrowserSpaceTheme, Bool)]()
        editor.onChange = { changes.append(($0, $1)) }
        _ = editor.view
        let pad = try #require(editor.view.subviews.compactMap { $0 as? BrowserSpaceThemePadView }.first)
        pad.onBeginGesture()
        pad.onChange({ $0.addColor() }, true)
        #expect(editor.theme.colors.count == 2)
        #expect(changes.last?.1 == true)
        editor.undo()
        #expect(editor.theme.colors.count == 1)
        editor.undo()
        #expect(editor.theme.colors.count == 1, "Nothing more to undo")
    }
}

// MARK: - BrowserSpaceCreationTests

@Suite(.serialized)
@MainActor struct BrowserSpaceCreationTests {
    private static let orange = BrowserSpaceTheme.Color(1, 0.522, 0.344)

    @Test func nothingChangesUntilTheSpaceIsCreated() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        let spaces = f.model.spaces.count
        f.model.beginCreatingSpace()
        #expect(f.model.spaces.count == spaces)
        #expect(f.model.spaceCreationDraft != nil)
        #expect(!f.model.commitCreatingSpace(), "A Space needs a name")
        f.model.updateSpaceCreationDraft { $0.title = "  Work  " }
        f.model.updateSpaceCreationDraft { $0.icon = BrowserIconImage.name(emoji: "🌴") }
        let theme = BrowserSpaceTheme(key: Self.orange)
        f.model.updateSpaceCreationDraft { $0.theme = theme }
        #expect(f.model.selectedSpaceTheme == theme, "The draft's theme shows on the window")
        #expect(f.model.commitCreatingSpace())
        #expect(f.model.spaceCreationDraft == nil)
        #expect(f.model.spaces.count == spaces + 1)
        let created = try #require(f.model.spaces.last)
        #expect(created.title == "Work")
        #expect(created.systemImageName == "emoji:🌴")
        #expect(f.model.selectedSpaceID == created.id)
        #expect(f.model.selectedSpaceTheme == theme)
    }

    @Test func aSpaceOnAnotherProfileOpensItsPagesThere() throws {
        let f = SidebarDragFixture(pinned: [], temporary: ["x"])
        f.model.profileDirectories = BrowserSpaceProfileDirectories(
            windowProfile: "Default",
            profiles: { [] },
            cachePath: { "/profiles/\($0)" },
            createProfile: { nil },
        )
        let space = try #require(f.model.selectedSpaceID)
        #expect(f.model.profileDirectory(forSpaceID: space) == "Default")
        #expect(!f.model.setProfile("Default", forSpaceID: space), "Already there")
        let requests = f.driver.createdTabRequests.count
        let tab = try #require(f.model.tabs.first { $0.spaceID == space }?.id)
        let syncID = try #require(f.model.tabs.first { $0.id == tab }?.syncID)

        #expect(f.model.setProfile("Profile 2", forSpaceID: space))

        #expect(f.model.profileDirectory(forSpaceID: space) == "Profile 2")
        #expect(f.driver.createdTabRequests.count == requests + 1, "The page reopens in the new profile")
        #expect(f.driver.createdTabProfilePaths.last == "/profiles/Profile 2")
        let moved = try #require(f.model.tabs.first { $0.syncID == syncID })
        #expect(moved.id != tab, "The old page goes away")
        #expect(f.model.selectedTabID == moved.id)
        f.driver.flushPendingCreateEvents()

        f.model.createNewTab()
        #expect(f.driver.createdTabProfilePaths.last == "/profiles/Profile 2", "New tabs follow the Space")

        #expect(f.model.setProfile("Default", forSpaceID: space))
        #expect(f.model.spaceProfilesByID[space] == nil, "The window's own profile needs no entry")
        #expect(f.driver.createdTabProfilePaths.last == .some(nil))
    }

    @Test func aNewSpaceStartsOnTheChosenProfile() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.profileDirectories = BrowserSpaceProfileDirectories(
            windowProfile: "Default",
            profiles: { [] },
            cachePath: { "/profiles/\($0)" },
            createProfile: { nil },
        )
        f.model.beginCreatingSpace()
        f.model.updateSpaceCreationDraft { $0.title = "Work" }
        f.model.updateSpaceCreationDraft { $0.profileDirectory = "Profile 2" }
        #expect(f.model.commitCreatingSpace())
        let created = try #require(f.model.spaces.last)
        #expect(f.model.spaceProfilesByID[created.id] == "Profile 2")
        f.model.createNewTab()
        #expect(f.driver.createdTabProfilePaths.last == "/profiles/Profile 2")
    }

    @Test func aTabMovedToASpaceOnAnotherProfileReopensThere() {
        let f = SidebarDragFixture(pinned: [], temporary: ["x", "y"])
        f.model.profileDirectories = BrowserSpaceProfileDirectories(
            windowProfile: "Default",
            profiles: { [] },
            cachePath: { "/profiles/\($0)" },
            createProfile: { nil },
        )
        #expect(f.model.setProfile("Profile 2", forSpaceID: "t"))
        let requests = f.driver.createdTabRequests.count
        #expect(requests == 2, "Nothing is open in that Space yet")
        let moving = f.id("y")

        f.model.moveTab(withID: moving, toPlacement: .temporary, atSectionIndex: 0, targetSpaceID: "t")

        #expect(f.driver.createdTabRequests.count == requests + 1)
        #expect(f.driver.createdTabProfilePaths.last == "/profiles/Profile 2")
        #expect(f.driver.closedTabRequests.map(\.id) == [moving])
        #expect(f.model.tabs.first { $0.userTitleOverride == "y" }?.spaceID == "t")
    }

    @Test func cancellingLeavesEverythingAsItWas() {
        let f = SidebarDragFixture(temporary: ["x"])
        let spaces = f.model.spaces.count
        let selected = f.model.selectedSpaceID
        f.model.beginCreatingSpace()
        f.model.updateSpaceCreationDraft { $0.theme = BrowserSpaceTheme(key: Self.orange) }
        f.model.cancelCreatingSpace()
        #expect(f.model.spaces.count == spaces && f.model.selectedSpaceID == selected)
        #expect(f.model.selectedSpaceTheme == nil)
    }

    @Test func iconNamesDrawSymbolsAndEmoji() {
        #expect(BrowserIconImage.emoji(from: BrowserIconImage.name(emoji: "😀")) == "😀")
        #expect(BrowserIconImage.emoji(from: "star.fill") == nil)
        #expect(BrowserIconImage.isValid("star.fill") && BrowserIconImage.isValid("emoji:😀"))
        #expect(!BrowserIconImage.isValid("no.such.symbol.name"))
        let emoji = BrowserIconImage.image(named: "emoji:😀", pointSize: 16)
        #expect(emoji?.isTemplate == false && (emoji?.size.width ?? 0) > 0)
        #expect(BrowserIconImage.image(named: "star.fill", pointSize: 16) != nil)
    }

    @Test func everyCatalogIconExistsAndEmojiSearchFindsNames() {
        for name in BrowserSpaceIconCatalog.systemImageNames {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "Missing symbol \(name)")
        }
        #expect(BrowserSpaceIconCatalog.systemImageNames.count == 56)
        #expect(BrowserSpaceIconCatalog.emojiCategories.count == 8)
        #expect(BrowserSpaceIconCatalog.emojiCategories.allSatisfy { !$0.emoji.isEmpty })
        #expect(BrowserSpaceIconCatalog.searchName(ofEmoji: "🌴").contains("palm"))
    }

    @Test func aFolderMenuOffersThePickerAndRemovalOnlyWhenAnIconIsSet() {
        let menu = NSMenu()
        BrowserNativeMenus.addIconMenu("Change Icon", to: menu, selected: nil, noIconTitle: "Remove") { _ in }
        #expect(menu.items.map(\.title) == ["Change Icon…"])
        let withIcon = NSMenu()
        var removed = false
        BrowserNativeMenus.addIconMenu("Change Icon", to: withIcon, selected: "star.fill", noIconTitle: "Remove") {
            removed = $0 == nil
        }
        #expect(withIcon.items.map(\.title) == ["Change Icon…", "Remove"])
        withIcon.performActionForItem(at: 1)
        #expect(removed)
    }
}

// MARK: - BrowserLibraryTests

@Suite(.serialized)
@MainActor struct BrowserLibraryTests {
    @Test func theLibraryOpensOnItsLastSectionAndClosesAgain() {
        let f = SidebarDragFixture(temporary: ["x"])
        #expect(f.model.librarySection == nil)
        f.model.toggleLibrary()
        #expect(f.model.librarySection == .archive)
        f.model.librarySection = .spaces
        f.model.toggleLibrary()
        #expect(f.model.librarySection == nil)
        f.model.toggleLibrary()
        #expect(f.model.librarySection == .spaces, "It comes back where it was")
        f.model.closeLibrary()
        #expect(f.model.librarySection == nil)
    }

    @Test func theLibraryCommandIsAvailableAndBoundToCommandShiftL() {
        let f = SidebarDragFixture(temporary: ["x"])
        #expect(f.model.isCommandBarActionAvailable(.viewLibrary))
        #expect(BrowserCommands.viewLibrary.shortcut == BrowserKeyboardShortcut("l", modifiers: [.command, .shift]))
    }

    @Test func allSectionsHaveTitlesAndSymbols() {
        for section in BrowserLibrarySection.allCases {
            #expect(!section.title.isEmpty)
            #expect(NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil) != nil)
        }
    }

    @Test func swatchesHaveSpokenColorNames() {
        let single = BrowserSpaceThemePresets.pages[0].map(\.key.spokenName)
        #expect(Array(single[3...7]) == [
            BrowserStrings.colorRed, BrowserStrings.colorOrange, BrowserStrings.colorYellow,
            BrowserStrings.colorGreen, BrowserStrings.colorBlue,
        ])
        let grey = BrowserSpaceThemePresets.pages[4].map(\.key.spokenName)
        #expect(grey.first == BrowserStrings.colorWhite)
        #expect(grey.last == BrowserStrings.colorBlack)
        #expect(grey.contains(BrowserStrings.colorGray))
        let lightNames = Set([
            BrowserStrings.colorRed, BrowserStrings.colorOrange, BrowserStrings.colorYellow, BrowserStrings.colorGreen,
            BrowserStrings.colorTeal, BrowserStrings.colorBlue, BrowserStrings.colorPurple, BrowserStrings.colorPink,
        ].map(BrowserStrings.colorLight)).union([BrowserStrings.colorWhite])
        #expect(
            BrowserSpaceThemePresets.pages[2].allSatisfy { lightNames.contains($0.key.spokenName) },
            "Pastels are light",
        )
    }
}
