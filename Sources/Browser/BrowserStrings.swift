import AppKit
import Foundation

// MARK: - BrowserKeyboardShortcut

struct BrowserKeyboardShortcut: Codable, Equatable, Hashable {
    // MARK: Lifecycle

    init(_ keyEquivalent: String, modifiers: NSEvent.ModifierFlags = [.command]) {
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.keyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
        let modifiersRawValue = try container.decode(NSEvent.ModifierFlags.RawValue.self, forKey: .modifiersRawValue)
        self.modifiers = NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    // MARK: Internal

    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags

    var keyCaps: [String] {
        var result = [String]()

        if modifiers.contains(.control) {
            result.append("\u{2303}")
        }

        if modifiers.contains(.option) {
            result.append("\u{2325}")
        }

        if modifiers.contains(.shift) {
            result.append("\u{21E7}")
        }

        if modifiers.contains(.command) {
            result.append("\u{2318}")
        }

        result.append(keyEquivalent.uppercased())
        return result
    }

    var displayText: String {
        keyCaps.joined()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyEquivalent, forKey: .keyEquivalent)
        try container.encode(modifiers.rawValue, forKey: .modifiersRawValue)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyEquivalent)
        hasher.combine(modifiers.rawValue)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case keyEquivalent
        case modifiersRawValue
    }
}

// MARK: - BrowserCommandDescriptor

struct BrowserCommandDescriptor {
    let menuTitle: String
    let helpTitle: String
    let shortcut: BrowserKeyboardShortcut
}

// MARK: - BrowserCommands

enum BrowserCommands {
    static let openSettings = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSettings,
        helpTitle: BrowserStrings.menuSettings,
        shortcut: BrowserKeyboardShortcut(",")
    )

    static let setAsDefaultBrowser = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSetAsDefaultBrowser,
        helpTitle: BrowserStrings.menuSetAsDefaultBrowser,
        shortcut: BrowserKeyboardShortcut("d")
    )

    static let newTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNewTab,
        helpTitle: BrowserStrings.sidebarNewTab,
        shortcut: BrowserKeyboardShortcut("t")
    )

    static let archiveTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.tabArchiveAction,
        helpTitle: BrowserStrings.tabArchiveTooltip,
        shortcut: BrowserKeyboardShortcut("w")
    )

    static let savePage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSavePageAs,
        helpTitle: BrowserStrings.menuSavePageAs,
        shortcut: BrowserKeyboardShortcut("s", modifiers: [.command, .shift])
    )

    static let printPage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuPrint,
        helpTitle: BrowserStrings.menuPrint,
        shortcut: BrowserKeyboardShortcut("p")
    )

    static let copyLink = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.tabCopyLinkAction,
        helpTitle: BrowserStrings.tabCopyLinkAction,
        shortcut: BrowserKeyboardShortcut("c", modifiers: [.command, .shift])
    )

    static let findInPage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFind,
        helpTitle: BrowserStrings.menuFind,
        shortcut: BrowserKeyboardShortcut("f")
    )

    static let findAndReplace = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFindAndReplace,
        helpTitle: BrowserStrings.menuFindAndReplace,
        shortcut: BrowserKeyboardShortcut("f", modifiers: [.command, .option])
    )

    static let findNext = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFindNext,
        helpTitle: BrowserStrings.menuFindNext,
        shortcut: BrowserKeyboardShortcut("g")
    )

    static let findPrevious = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFindPrevious,
        helpTitle: BrowserStrings.menuFindPrevious,
        shortcut: BrowserKeyboardShortcut("g", modifiers: [.command, .shift])
    )

    static let jumpToSelection = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuJumpToSelection,
        helpTitle: BrowserStrings.menuJumpToSelection,
        shortcut: BrowserKeyboardShortcut("j")
    )

    static let clearTemporaryTabs = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuClearTemporaryTabs,
        helpTitle: BrowserStrings.sidebarClearTemporaryTabsTooltip,
        shortcut: BrowserKeyboardShortcut("k", modifiers: [.command, .shift])
    )

    static let goBack = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.navigationBack,
        helpTitle: BrowserStrings.navigationBack,
        shortcut: BrowserKeyboardShortcut("[")
    )

    static let goForward = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.navigationForward,
        helpTitle: BrowserStrings.navigationForward,
        shortcut: BrowserKeyboardShortcut("]")
    )

    static let reload = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.navigationRefresh,
        helpTitle: BrowserStrings.navigationRefresh,
        shortcut: BrowserKeyboardShortcut("r")
    )

    static let forceReload = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuForceRefresh,
        helpTitle: BrowserStrings.menuForceRefresh,
        shortcut: BrowserKeyboardShortcut("r", modifiers: [.command, .shift])
    )

    static let toggleSidebar = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuToggleSidebar,
        helpTitle: BrowserStrings.sidebarHide,
        shortcut: BrowserKeyboardShortcut("s")
    )
}

// MARK: - BrowserSpaceShortcuts

enum BrowserSpaceShortcuts {
    static let maximumIndexedSpaces = 4

    static func shortcut(forSpaceIndex index: Int) -> BrowserKeyboardShortcut? {
        guard (0..<maximumIndexedSpaces).contains(index) else {
            return nil
        }

        return BrowserKeyboardShortcut("\(index + 1)", modifiers: [.control])
    }

    static func spaceIndex(forPhysicalKeyCode keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Int? {
        guard modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control] else {
            return nil
        }

        switch keyCode {
        case 18:
            return 0
        case 19:
            return 1
        case 20:
            return 2
        case 21:
            return 3
        default:
            return nil
        }
    }
}

// MARK: - BrowserLayoutIndependentShortcutCommand

enum BrowserLayoutIndependentShortcutCommand: Equatable {
    case undo
    case redo
    case cut
    case copy
    case paste
    case pasteAndMatchStyle
    case selectAll
    case quit
    case openSettings
    case setAsDefaultBrowser
    case newTab
    case archiveTab
    case savePage
    case printPage
    case copyLink
    case findInPage
    case findAndReplace
    case findNextInPage
    case findPreviousInPage
    case jumpToSelection
    case clearTemporaryTabs
    case goBack
    case goForward
    case reload
    case forceReload
    case toggleSidebar
}

// MARK: - BrowserKeyboardShortcutBridge

enum BrowserKeyboardShortcutBridge {
    // MARK: Internal

    static func commandForLayoutIndependentDispatch(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        shortcutResolver: BrowserShortcutResolving? = nil
    ) -> BrowserLayoutIndependentShortcutCommand? {
        let normalizedModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard normalizedModifiers.contains(.command) else {
            return nil
        }

        guard let usKeyEquivalent = usKeyEquivalent(for: keyCode) else {
            return nil
        }

        guard normalizedCharacters(from: charactersIgnoringModifiers) != usKeyEquivalent else {
            return nil
        }

        return shortcutMatches(shortcutResolver: shortcutResolver)
            .first {
                $0.keyEquivalent == usKeyEquivalent && $0.modifiers == normalizedModifiers
            }?.command
    }

    // MARK: Private

    private struct ShortcutMatch {
        // MARK: Lifecycle

        init(
            command: BrowserLayoutIndependentShortcutCommand,
            keyEquivalent: String,
            modifiers: NSEvent.ModifierFlags
        ) {
            self.command = command
            self.keyEquivalent = keyEquivalent.lowercased()
            self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        }

        init(
            command: BrowserLayoutIndependentShortcutCommand,
            shortcut: BrowserKeyboardShortcut
        ) {
            self.init(
                command: command,
                keyEquivalent: shortcut.keyEquivalent,
                modifiers: shortcut.modifiers
            )
        }

        // MARK: Internal

        let command: BrowserLayoutIndependentShortcutCommand
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags
    }

    private static func shortcutMatches(shortcutResolver: BrowserShortcutResolving?) -> [ShortcutMatch] {
        var matches = [
            ShortcutMatch(command: .undo, keyEquivalent: "z", modifiers: [.command]),
            ShortcutMatch(command: .redo, keyEquivalent: "z", modifiers: [.command, .shift]),
            ShortcutMatch(command: .cut, keyEquivalent: "x", modifiers: [.command]),
            ShortcutMatch(command: .copy, keyEquivalent: "c", modifiers: [.command]),
            ShortcutMatch(command: .paste, keyEquivalent: "v", modifiers: [.command]),
            ShortcutMatch(command: .pasteAndMatchStyle, keyEquivalent: "v", modifiers: [.command, .shift]),
            ShortcutMatch(command: .selectAll, keyEquivalent: "a", modifiers: [.command]),
            ShortcutMatch(command: .quit, keyEquivalent: "q", modifiers: [.command]),
        ]

        matches.append(
            contentsOf: BrowserCommandID.allCases.map { commandID in
                ShortcutMatch(
                    command: commandID.layoutIndependentCommand,
                    shortcut: shortcutResolver?.shortcut(for: commandID) ?? commandID.defaultDescriptor.shortcut
                )
            }
        )
        return matches
    }

    private static func normalizedCharacters(from characters: String?) -> String? {
        characters?.lowercased()
    }

    private static func usKeyEquivalent(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 0:
            "a"
        case 1:
            "s"
        case 2:
            "d"
        case 3:
            "f"
        case 5:
            "g"
        case 6:
            "z"
        case 7:
            "x"
        case 8:
            "c"
        case 9:
            "v"
        case 11:
            "b"
        case 12:
            "q"
        case 13:
            "w"
        case 15:
            "r"
        case 17:
            "t"
        case 35:
            "p"
        case 38:
            "j"
        case 40:
            "k"
        case 30:
            "]"
        case 33:
            "["
        case 43:
            ","
        default:
            nil
        }
    }
}

// MARK: - BrowserStrings

enum BrowserStrings {
    static let applicationName = NSLocalizedString(
        "browser.app.name",
        comment: "The localized application name."
    )

    static let newTabTitle = NSLocalizedString(
        "browser.tab.new",
        comment: "Fallback title for a new tab without page metadata."
    )

    static let sidebarNewTab = NSLocalizedString(
        "browser.sidebar.new_tab",
        comment: "Sidebar button title for creating a new tab."
    )

    static let spaceRenameAction = NSLocalizedString(
        "browser.space.rename_action",
        comment: "Context menu title for renaming a space."
    )

    static let spaceChangeIconAction = NSLocalizedString(
        "browser.space.change_icon_action",
        comment: "Context menu title for changing a space icon."
    )

    static let spaceNewAction = NSLocalizedString(
        "browser.space.new_action",
        comment: "Tooltip title for creating a new space."
    )

    static let sidebarHide = NSLocalizedString(
        "browser.sidebar.hide",
        comment: "Tooltip for hiding the sidebar."
    )

    static let navigationBack = NSLocalizedString(
        "browser.navigation.back",
        comment: "Title for back navigation actions."
    )

    static let navigationForward = NSLocalizedString(
        "browser.navigation.forward",
        comment: "Title for forward navigation actions."
    )

    static let navigationRefresh = NSLocalizedString(
        "browser.navigation.refresh",
        comment: "Title for refresh actions."
    )

    static let navigationStopLoading = NSLocalizedString(
        "browser.navigation.stop_loading",
        comment: "Title for stop loading actions."
    )

    static let loadingLaunchingBrowser = NSLocalizedString(
        "browser.loading.launching",
        comment: "Loading message shown while the browser initializes."
    )

    static let commandBarPlaceholder = NSLocalizedString(
        "browser.command_bar.placeholder",
        comment: "Placeholder shown in the command bar search field."
    )

    static let findBarPlaceholder = NSLocalizedString(
        "browser.find_bar.placeholder",
        comment: "Placeholder shown in the page find field."
    )

    static let findBarPreviousMatch = NSLocalizedString(
        "browser.find_bar.previous_match",
        comment: "Tooltip for moving to the previous in-page search match."
    )

    static let findBarNextMatch = NSLocalizedString(
        "browser.find_bar.next_match",
        comment: "Tooltip for moving to the next in-page search match."
    )

    static let findBarClose = NSLocalizedString(
        "browser.find_bar.close",
        comment: "Tooltip for closing the page find bar."
    )

    static let menuFile = NSLocalizedString(
        "browser.menu.file",
        comment: "File menu title."
    )

    static let menuEdit = NSLocalizedString(
        "browser.menu.edit",
        comment: "Edit menu title."
    )

    static let menuView = NSLocalizedString(
        "browser.menu.view",
        comment: "View menu title."
    )

    static let menuFindTitle = NSLocalizedString(
        "browser.menu.find.title",
        comment: "Find submenu title."
    )

    static let menuSettings = NSLocalizedString(
        "browser.menu.settings",
        comment: "Settings menu item title."
    )

    static let menuSetAsDefaultBrowser = NSLocalizedString(
        "browser.menu.set_as_default_browser",
        comment: "Set as Default Browser menu item title."
    )

    static let aboutUnknownVersion = NSLocalizedString(
        "browser.about.unknown_version",
        comment: "Fallback version text when a bundle version is unavailable."
    )

    static let aboutCopyright = NSLocalizedString(
        "browser.about.copyright",
        comment: "Copyright text shown in the About window."
    )

    static let aboutMadePossiblePrefix = NSLocalizedString(
        "browser.about.made_possible.prefix",
        comment: "Opening text before the Chromium project link in the About window credits paragraph."
    )

    static let aboutChromiumProjectLinkTitle = NSLocalizedString(
        "browser.about.chromium_project_link",
        comment: "Linked Chromium project name in the About window credits paragraph."
    )

    static let aboutMadePossibleChromiumProjectSuffix = NSLocalizedString(
        "browser.about.made_possible.chromium_project_suffix",
        comment: "Text after the Chromium project link and before Chromium credits link in the About window."
    )

    static let aboutOpenSourceSoftwareLinkTitle = NSLocalizedString(
        "browser.about.open_source_software_link",
        comment: "Linked open source software phrase in the About window credits paragraph."
    )

    static let aboutMadePossibleOtherPrefix = NSLocalizedString(
        "browser.about.made_possible.other_prefix",
        comment: "Text between the Chromium credits link and TheBrowser credits link in the About window."
    )

    static let aboutMadePossibleSuffix = NSLocalizedString(
        "browser.about.made_possible.suffix",
        comment: "Closing punctuation for the About window credits paragraph."
    )

    static let menuUndo = NSLocalizedString(
        "browser.menu.undo",
        comment: "Undo menu item title."
    )

    static let menuRedo = NSLocalizedString(
        "browser.menu.redo",
        comment: "Redo menu item title."
    )

    static let menuCut = NSLocalizedString(
        "browser.menu.cut",
        comment: "Cut menu item title."
    )

    static let menuCopy = NSLocalizedString(
        "browser.menu.copy",
        comment: "Copy menu item title."
    )

    static let menuPaste = NSLocalizedString(
        "browser.menu.paste",
        comment: "Paste menu item title."
    )

    static let menuPasteAndMatchStyle = NSLocalizedString(
        "browser.menu.paste_and_match_style",
        comment: "Paste and Match Style menu item title."
    )

    static let menuSelectAll = NSLocalizedString(
        "browser.menu.select_all",
        comment: "Select All menu item title."
    )

    static let menuFind = NSLocalizedString(
        "browser.menu.find",
        comment: "Find menu item title."
    )

    static let menuFindAndReplace = NSLocalizedString(
        "browser.menu.find_and_replace",
        comment: "Find and Replace menu item title."
    )

    static let menuFindNext = NSLocalizedString(
        "browser.menu.find_next",
        comment: "Find Next menu item title."
    )

    static let menuFindPrevious = NSLocalizedString(
        "browser.menu.find_previous",
        comment: "Find Previous menu item title."
    )

    static let menuUseSelectionToFind = NSLocalizedString(
        "browser.menu.use_selection_to_find",
        comment: "Use Selection to Find menu item title."
    )

    static let menuJumpToSelection = NSLocalizedString(
        "browser.menu.jump_to_selection",
        comment: "Jump to Selection menu item title."
    )

    static let menuNewTab = NSLocalizedString(
        "browser.menu.new_tab",
        comment: "New Tab menu item title."
    )

    static let menuSavePageAs = NSLocalizedString(
        "browser.menu.save_page_as",
        comment: "Save Page As menu item title."
    )

    static let menuPrint = NSLocalizedString(
        "browser.menu.print",
        comment: "Print menu item title."
    )

    static let menuForceRefresh = NSLocalizedString(
        "browser.menu.force_refresh",
        comment: "Force Refresh menu item title."
    )

    static let menuToggleSidebar = NSLocalizedString(
        "browser.menu.toggle_sidebar",
        comment: "Toggle Sidebar menu item title."
    )

    static let menuClearTemporaryTabs = NSLocalizedString(
        "browser.menu.clear_temporary_tabs",
        comment: "Clear Temporary Tabs menu item title."
    )

    static let quitShortcutTitle = NSLocalizedString(
        "browser.menu.quit_shortcut_title",
        comment: "Conflict title for the system quit shortcut."
    )

    static let sidebarClearTemporaryTabs = NSLocalizedString(
        "browser.sidebar.clear_temporary_tabs",
        comment: "Button title for clearing temporary tabs."
    )

    static let sidebarClearTemporaryTabsTooltip = NSLocalizedString(
        "browser.sidebar.clear_temporary_tabs_tooltip",
        comment: "Tooltip shown for clearing temporary tabs."
    )

    static let tabArchiveAction = NSLocalizedString(
        "browser.tab.archive_action",
        comment: "Context menu title for archiving a tab."
    )

    static let tabArchiveTabsBelowAction = NSLocalizedString(
        "browser.tab.archive_tabs_below_action",
        comment: "Context menu title for archiving tabs below the current tab."
    )

    static let tabArchiveTooltip = NSLocalizedString(
        "browser.tab.archive_tooltip",
        comment: "Tooltip shown for archiving a tab."
    )

    static let tabCopyLinkAction = NSLocalizedString(
        "browser.tab.copy_link_action",
        comment: "Menu item title for copying a tab link."
    )

    static let tabCopyURLAction = NSLocalizedString(
        "browser.tab.copy_url_action",
        comment: "Tooltip title for copying the current page URL."
    )

    static let siteControlCenterAction = NSLocalizedString(
        "browser.site_control_center.action",
        comment: "Tooltip title for opening the current site's controls."
    )

    static let extensionsSectionTitle = NSLocalizedString(
        "browser.extensions.section.title",
        comment: "Section title for extensions in the site control center popover."
    )

    static let extensionsManageAction = NSLocalizedString(
        "browser.extensions.manage",
        comment: "Button title for opening the extensions management page."
    )

    static let extensionsAddAction = NSLocalizedString(
        "browser.extensions.add",
        comment: "Accessibility title for adding an extension."
    )

    static let tabRenameAction = NSLocalizedString(
        "browser.tab.rename_action",
        comment: "Context menu title for renaming a tab."
    )

    static let tabShareAction = NSLocalizedString(
        "browser.tab.share_action",
        comment: "Context menu title for sharing a tab."
    )

    static let tabRenameTooltipCaption = NSLocalizedString(
        "browser.tab.rename_tooltip_caption",
        comment: "Caption shown under the tab title tooltip."
    )

    static let settingsTemporaryTabsTitle = NSLocalizedString(
        "browser.settings.temporary_tabs.title",
        comment: "Title for the temporary tab settings section."
    )

    static let settingsGeneralTab = NSLocalizedString(
        "browser.settings.general",
        comment: "Title for the general settings tab."
    )

    static let settingsWindowTitle = NSLocalizedString(
        "browser.settings.window_title",
        comment: "Title for the settings window."
    )

    static let settingsAccountsTab = NSLocalizedString(
        "browser.settings.accounts",
        comment: "Title for the accounts settings tab."
    )

    static let settingsAccountsCurrentAccounts = NSLocalizedString(
        "browser.settings.accounts.current_accounts",
        comment: "Title for the current accounts section."
    )

    static let settingsAccountsEmpty = NSLocalizedString(
        "browser.settings.accounts.empty",
        comment: "Empty state text for accounts."
    )

    static let settingsAutomaticUpdates = NSLocalizedString(
        "browser.settings.general.automatic_updates",
        comment: "Automatic updates setting title."
    )

    static let settingsAutomaticUpdatesDetail = NSLocalizedString(
        "browser.settings.general.automatic_updates.detail",
        comment: "Automatic updates row detail."
    )

    static let settingsWarnBeforeQuitting = NSLocalizedString(
        "browser.settings.general.warn_before_quitting",
        comment: "Warn before quitting setting title."
    )

    static let settingsProfilesTab = NSLocalizedString(
        "browser.settings.profiles",
        comment: "Title for the profiles settings tab."
    )

    static let settingsProfilesIntro = NSLocalizedString(
        "browser.settings.profiles.intro",
        comment: "Intro copy for profiles."
    )

    static let settingsDefaultProfile = NSLocalizedString(
        "browser.settings.profiles.default_profile",
        comment: "Default profile title."
    )

    static let settingsDefaultProfileDetail = NSLocalizedString(
        "browser.settings.profiles.default_profile.detail",
        comment: "Default profile detail."
    )

    static let settingsSearchEngine = NSLocalizedString(
        "browser.settings.profiles.search_engine",
        comment: "Search engine setting title."
    )

    static let settingsSearchEngineGoogle = NSLocalizedString(
        "browser.settings.search_engine.google",
        comment: "Google search engine picker title."
    )

    static let settingsSearchEngineMicrosoftBing = NSLocalizedString(
        "browser.settings.search_engine.microsoft_bing",
        comment: "Microsoft Bing search engine picker title."
    )

    static let settingsSearchEngineYahoo = NSLocalizedString(
        "browser.settings.search_engine.yahoo",
        comment: "Yahoo search engine picker title."
    )

    static let settingsSearchEngineDuckDuckGo = NSLocalizedString(
        "browser.settings.search_engine.duckduckgo",
        comment: "DuckDuckGo search engine picker title."
    )

    static let settingsSearchEngineYandex = NSLocalizedString(
        "browser.settings.search_engine.yandex",
        comment: "Yandex search engine picker title."
    )

    static let settingsSearchEnginePerplexity = NSLocalizedString(
        "browser.settings.search_engine.perplexity",
        comment: "Perplexity search engine picker title."
    )

    static let settingsManageSearch = NSLocalizedString(
        "browser.settings.profiles.manage_search",
        comment: "Manage search button title."
    )

    static let settingsSearchSuggestions = NSLocalizedString(
        "browser.settings.profiles.search_suggestions",
        comment: "Search engine suggestions toggle title."
    )

    static let settingsPrivacyAndSecurity = NSLocalizedString(
        "browser.settings.profiles.privacy_and_security",
        comment: "Privacy and security settings link title."
    )

    static let settingsPasswords = NSLocalizedString(
        "browser.settings.profiles.passwords",
        comment: "Passwords settings link title."
    )

    static let settingsCreditCards = NSLocalizedString(
        "browser.settings.profiles.credit_cards",
        comment: "Credit cards settings link title."
    )

    static let settingsNotifications = NSLocalizedString(
        "browser.settings.profiles.notifications",
        comment: "Notifications settings link title."
    )

    static let settingsClearBrowsingData = NSLocalizedString(
        "browser.settings.profiles.clear_browsing_data",
        comment: "Clear browsing data settings link title."
    )

    static let settingsShortcutsTab = NSLocalizedString(
        "browser.settings.shortcuts",
        comment: "Title for the shortcuts settings tab."
    )

    static let settingsShortcutsSearchPlaceholder = NSLocalizedString(
        "browser.settings.shortcuts.search_placeholder",
        comment: "Placeholder for the shortcut search field."
    )

    static let settingsShortcutRecord = NSLocalizedString(
        "browser.settings.shortcuts.record",
        comment: "Button title for recording a shortcut."
    )

    static let settingsShortcutReset = NSLocalizedString(
        "browser.settings.shortcuts.reset",
        comment: "Button title for resetting one shortcut."
    )

    static let settingsShortcutResetAll = NSLocalizedString(
        "browser.settings.shortcuts.reset_all",
        comment: "Button title for resetting all shortcuts."
    )

    static let settingsShortcutPressShortcut = NSLocalizedString(
        "browser.settings.shortcuts.press_shortcut",
        comment: "Prompt shown while recording a shortcut."
    )

    static let settingsExtensionShortcuts = NSLocalizedString(
        "browser.settings.shortcuts.extension_shortcuts",
        comment: "Button title for opening extension shortcut settings."
    )

    static let settingsContentTab = NSLocalizedString(
        "browser.settings.content",
        comment: "Title for the content settings tab."
    )

    static let settingsHapticFeedback = NSLocalizedString(
        "browser.settings.content.haptic_feedback",
        comment: "Haptic feedback toggle title."
    )

    static let settingsRestoreWindows = NSLocalizedString(
        "browser.settings.content.restore_windows",
        comment: "Restore windows setting title."
    )

    static let settingsPictureInPicture = NSLocalizedString(
        "browser.settings.content.picture_in_picture",
        comment: "Picture in Picture setting title."
    )

    static let settingsMoreSettings = NSLocalizedString(
        "browser.settings.content.more_settings",
        comment: "More settings button title."
    )

    static let settingsTranslateSitePrompts = NSLocalizedString(
        "browser.settings.content.translate_site_prompts",
        comment: "Translate site prompts button title."
    )

    static let settingsQuitWarningTitle = NSLocalizedString(
        "browser.settings.quit_warning.title",
        comment: "Quit warning alert title."
    )

    static let settingsQuitWarningMessage = NSLocalizedString(
        "browser.settings.quit_warning.message",
        comment: "Quit warning alert message."
    )

    static let settingsQuitWarningQuit = NSLocalizedString(
        "browser.settings.quit_warning.quit",
        comment: "Quit button title in quit warning alert."
    )

    static let settingsQuitWarningCancel = NSLocalizedString(
        "browser.settings.quit_warning.cancel",
        comment: "Cancel button title in quit warning alert."
    )

    static let settingsTemporaryTabsDescription = NSLocalizedString(
        "browser.settings.temporary_tabs.description",
        comment: "Description for the temporary tab settings section."
    )

    static let settingsTemporaryTabsLifetimeLabel = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime_label",
        comment: "Label for the temporary tab archival lifetime picker."
    )

    static let settingsLifetimeTwelveHours = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.12h",
        comment: "Option title for archiving temporary tabs after 12 hours."
    )

    static let settingsLifetimeTwentyFourHours = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.24h",
        comment: "Option title for archiving temporary tabs after 24 hours."
    )

    static let settingsLifetimeSevenDays = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.7d",
        comment: "Option title for archiving temporary tabs after 7 days."
    )

    static let settingsLifetimeThirtyDays = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.30d",
        comment: "Option title for archiving temporary tabs after 30 days."
    )

    static let notificationPermissionTitle = NSLocalizedString(
        "browser.permissions.notifications.title",
        comment: "Notification permission prompt title."
    )

    static let notificationPermissionAllow = NSLocalizedString(
        "browser.permissions.allow",
        comment: "Allow button title for notification permissions."
    )

    static let notificationPermissionDontAllow = NSLocalizedString(
        "browser.permissions.dont_allow",
        comment: "Don't Allow button title for notification permissions."
    )

    static func defaultSpaceTitle(index: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.space.default_title",
                comment: "Default title for a newly created browser space. The argument is the 1-based space number."
            ),
            index
        )
    }

    static func settingsShortcutConflict(_ commandTitle: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.settings.shortcuts.conflict",
                comment: "Shortcut conflict message with conflicting command title."
            ),
            commandTitle
        )
    }

    static func quitMenuItem(appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.quit",
                comment: "Quit menu item title with the app name placeholder."
            ),
            appName
        )
    }

    static func aboutMenuItem(appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.about",
                comment: "About menu item title with the app name placeholder."
            ),
            appName
        )
    }

    static func aboutWindowTitle(appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.about.window_title",
                comment: "About window title with the app name placeholder."
            ),
            appName
        )
    }

    static func aboutApplicationVersion(marketingVersion: String, buildVersion: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.about.application_version",
                comment: "Application version text with marketing version and build number placeholders."
            ),
            marketingVersion,
            buildVersion
        )
    }

    static func aboutChromiumVersion(_ chromiumVersion: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.about.chromium_version",
                comment: "Chromium version text with the Chromium version placeholder."
            ),
            chromiumVersion
        )
    }

    static func notificationPermissionMessage(origin: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.permissions.notifications.message",
                comment: "Notification permission prompt body with the site origin placeholder."
            ),
            origin
        )
    }

    static func title(for lifetime: BrowserTemporaryTabLifetime) -> String {
        switch lifetime {
        case .twelveHours:
            settingsLifetimeTwelveHours
        case .twentyFourHours:
            settingsLifetimeTwentyFourHours
        case .sevenDays:
            settingsLifetimeSevenDays
        case .thirtyDays:
            settingsLifetimeThirtyDays
        }
    }
}
