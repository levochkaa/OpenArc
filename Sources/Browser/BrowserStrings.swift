import Foundation

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

    static let spaceDeleteAction = NSLocalizedString(
        "browser.space.delete_action",
        comment: "Context menu title for deleting a space."
    )

    static let pinnedTabFolderDefaultTitle = NSLocalizedString(
        "browser.pinned_tab_folder.default_title",
        comment: "Default title for a pinned tab folder."
    )

    static let pinnedTabFolderNewAction = NSLocalizedString(
        "browser.pinned_tab_folder.new_action",
        comment: "Context menu title for creating a pinned tab folder from a pinned tab or selected pinned tabs."
    )

    static let pinnedTabFolderRenameAction = NSLocalizedString(
        "browser.pinned_tab_folder.rename_action",
        comment: "Context menu title for renaming a pinned tab folder."
    )

    static let pinnedTabFolderChangeIconAction = NSLocalizedString(
        "browser.pinned_tab_folder.change_icon_action",
        comment: "Context menu title for changing a pinned tab folder icon."
    )

    static let pinnedTabFolderNoIconAction = NSLocalizedString(
        "browser.pinned_tab_folder.no_icon_action",
        comment: "Menu title for removing a pinned tab folder icon."
    )

    static let pinnedTabBackToPinnedURL = NSLocalizedString(
        "browser.pinned_tab.back_to_pinned_url",
        comment: "Secondary sidebar label shown while hovering the pinned-tab favicon reset button."
    )

    static let pinnedTabReplaceURLWithCurrentAction = NSLocalizedString(
        "browser.pinned_tab.replace_url_with_current_action",
        comment: "Context menu title for replacing a pinned tab URL with the current page URL."
    )

    static let pinnedTabEditURLAction = NSLocalizedString(
        "browser.pinned_tab.edit_url_action",
        comment: "Context menu title for editing a pinned tab URL."
    )

    static let pinnedTabEditURLPromptTitle = NSLocalizedString(
        "browser.pinned_tab.edit_url_prompt.title",
        comment: "Prompt title for editing a pinned tab URL."
    )

    static let sidebarHide = NSLocalizedString(
        "browser.sidebar.hide",
        comment: "Tooltip for hiding the sidebar."
    )

    static let sidebarShow = NSLocalizedString(
        "browser.sidebar.show",
        comment: "Tooltip for showing the sidebar."
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

    static let bookmarksAddCurrentPage = NSLocalizedString(
        "browser.bookmarks.add_current_page",
        comment: "Tooltip for adding the selected page to bookmarks."
    )

    static let bookmarksRemoveCurrentPage = NSLocalizedString(
        "browser.bookmarks.remove_current_page",
        comment: "Tooltip for removing the selected page from bookmarks."
    )

    static let bookmarksRenameAction = NSLocalizedString(
        "browser.bookmarks.rename_action",
        comment: "Context menu title for renaming a bookmark."
    )

    static let bookmarksEditAddressAction = NSLocalizedString(
        "browser.bookmarks.edit_address_action",
        comment: "Context menu title for editing a bookmark address."
    )

    static let bookmarksMoveToAction = NSLocalizedString(
        "browser.bookmarks.move_to_action",
        comment: "Context menu title for moving a bookmark."
    )

    static let bookmarksBarDestination = NSLocalizedString(
        "browser.bookmarks.bar_destination",
        comment: "Bookmark move destination title for the bookmarks bar root."
    )

    static let bookmarksNewFolderAction = NSLocalizedString(
        "browser.bookmarks.new_folder_action",
        comment: "Context menu title for creating a bookmark folder."
    )

    static let bookmarksDeleteAction = NSLocalizedString(
        "browser.bookmarks.delete_action",
        comment: "Context menu title for deleting a bookmark."
    )

    static let bookmarksManageAction = NSLocalizedString(
        "browser.bookmarks.manage_action",
        comment: "Context menu title for opening bookmark management."
    )

    static let bookmarksRenamePromptTitle = NSLocalizedString(
        "browser.bookmarks.rename_prompt.title",
        comment: "Prompt title for renaming a bookmark."
    )

    static let bookmarksEditAddressPromptTitle = NSLocalizedString(
        "browser.bookmarks.edit_address_prompt.title",
        comment: "Prompt title for editing a bookmark URL."
    )

    static let bookmarksNewFolderPromptTitle = NSLocalizedString(
        "browser.bookmarks.new_folder_prompt.title",
        comment: "Prompt title for creating a bookmark folder."
    )

    static let bookmarksImport = NSLocalizedString(
        "browser.bookmarks.import",
        comment: "Menu title for importing bookmarks."
    )

    static let bookmarksImportArc = NSLocalizedString(
        "browser.bookmarks.import.arc",
        comment: "Menu item title for importing bookmarks from Arc."
    )

    static let bookmarksImportDia = NSLocalizedString(
        "browser.bookmarks.import.dia",
        comment: "Menu item title for importing bookmarks from Dia."
    )

    static let bookmarksImportChrome = NSLocalizedString(
        "browser.bookmarks.import.chrome",
        comment: "Menu item title for importing bookmarks from Chrome."
    )

    static let bookmarksImportSafari = NSLocalizedString(
        "browser.bookmarks.import.safari",
        comment: "Menu item title for importing bookmarks from Safari."
    )

    static let bookmarksImportedFromArc = NSLocalizedString(
        "browser.bookmarks.imported_from.arc",
        comment: "Folder title for bookmarks imported from Arc."
    )

    static let bookmarksImportedFromDia = NSLocalizedString(
        "browser.bookmarks.imported_from.dia",
        comment: "Folder title for bookmarks imported from Dia."
    )

    static let bookmarksImportedFromChrome = NSLocalizedString(
        "browser.bookmarks.imported_from.chrome",
        comment: "Folder title for bookmarks imported from Chrome."
    )

    static let bookmarksImportedFromSafari = NSLocalizedString(
        "browser.bookmarks.imported_from.safari",
        comment: "Folder title for bookmarks imported from Safari."
    )

    static let bookmarksUntitledFolder = NSLocalizedString(
        "browser.bookmarks.untitled_folder",
        comment: "Fallback title for an untitled bookmarks folder."
    )

    static let bookmarksHideBarAction = NSLocalizedString(
        "browser.bookmarks.hide_bar_action",
        comment: "Context menu title for hiding the bookmarks bar."
    )

    static let downloadsTitle = NSLocalizedString(
        "browser.downloads.title",
        comment: "Title and tooltip for the downloads manager."
    )

    static let downloadsEmpty = NSLocalizedString(
        "browser.downloads.empty",
        comment: "Message shown when there are no downloads."
    )

    static let downloadsClearFinished = NSLocalizedString(
        "browser.downloads.clear_finished",
        comment: "Button title for clearing finished downloads."
    )

    static let downloadsOpen = NSLocalizedString(
        "browser.downloads.open",
        comment: "Button title for opening a downloaded file."
    )

    static let downloadsReveal = NSLocalizedString(
        "browser.downloads.reveal",
        comment: "Button title for revealing a downloaded file in Finder."
    )

    static let downloadsDefaultFileName = NSLocalizedString(
        "browser.downloads.default_file_name",
        comment: "Fallback file name for downloads without a suggested name."
    )

    static let downloadsStatusInProgress = NSLocalizedString(
        "browser.downloads.status.in_progress",
        comment: "Status text for a download that is still running."
    )

    static let downloadsStatusCompleted = NSLocalizedString(
        "browser.downloads.status.completed",
        comment: "Status text for a completed download."
    )

    static let downloadsStatusCanceled = NSLocalizedString(
        "browser.downloads.status.canceled",
        comment: "Status text for a canceled download."
    )

    static let downloadsStatusInterrupted = NSLocalizedString(
        "browser.downloads.status.interrupted",
        comment: "Status text for an interrupted download."
    )

    static let downloadsCompletedDetail = NSLocalizedString(
        "browser.downloads.detail.completed",
        comment: "Detail text for a completed download."
    )

    static let downloadsCanceledDetail = NSLocalizedString(
        "browser.downloads.detail.canceled",
        comment: "Detail text for a canceled download."
    )

    static let downloadsInterruptedDetail = NSLocalizedString(
        "browser.downloads.detail.interrupted",
        comment: "Detail text for an interrupted download."
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

    static let menuCheckForUpdates = NSLocalizedString(
        "browser.menu.check_for_updates",
        comment: "Check for Updates menu item title."
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

    static let menuNewIncognitoWindow = NSLocalizedString(
        "browser.menu.new_incognito_window",
        comment: "New Incognito Window menu item title."
    )

    static let incognitoBannerTitle = NSLocalizedString(
        "browser.incognito.banner.title",
        comment: "Banner title shown above web content in incognito windows."
    )

    static let incognitoTabsTitle = NSLocalizedString(
        "browser.incognito.tabs.title",
        comment: "Sidebar label shown above the new tab button in incognito windows."
    )

    static let menuHistory = NSLocalizedString(
        "browser.menu.history",
        comment: "History menu item title."
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

    static let menuClearCacheAndRefresh = NSLocalizedString(
        "browser.menu.clear_cache_and_refresh",
        comment: "Clear Cache and Refresh menu item title."
    )

    static let menuClearCookiesAndRefresh = NSLocalizedString(
        "browser.menu.clear_cookies_and_refresh",
        comment: "Clear Cookies and Refresh menu item title."
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

    static let tabCloseAction = NSLocalizedString(
        "browser.tab.close_action",
        comment: "Context menu title for closing a tab."
    )

    static let appTabRemoveFavoriteAction = NSLocalizedString(
        "browser.app_tab.remove_favorite_action",
        comment: "Context menu title for removing an app tab from favorites."
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

    static let siteCaptureFullPageAction = NSLocalizedString(
        "browser.site.capture_full_page",
        comment: "Context menu item for capturing the full current page to the pasteboard."
    )

    static let siteShowAsToolbarAction = NSLocalizedString(
        "browser.site.show_as_toolbar",
        comment: "Context menu item for showing the URL row as a toolbar."
    )

    static let siteShowInSidebarAction = NSLocalizedString(
        "browser.site.show_in_sidebar",
        comment: "Context menu item for moving the URL toolbar back into the sidebar."
    )

    static let siteShowFullURLAction = NSLocalizedString(
        "browser.site.show_full_url",
        comment: "Context menu item for showing the full URL in the URL toolbar."
    )

    static let siteHideFullURLAction = NSLocalizedString(
        "browser.site.hide_full_url",
        comment: "Context menu item for hiding the full URL in the URL toolbar."
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

    static let extensionsCloseSidePanel = NSLocalizedString(
        "browser.extensions.close_side_panel",
        comment: "Tooltip title for closing an extension side panel."
    )

    static let extensionsSiteAccessMenu = NSLocalizedString(
        "browser.extensions.site_access.menu",
        comment: "Context menu title for extension site access controls."
    )

    static let extensionsSiteAccessOnClick = NSLocalizedString(
        "browser.extensions.site_access.on_click",
        comment: "Context menu item for extension access when clicked."
    )

    static let extensionsSiteAccessCurrentSite = NSLocalizedString(
        "browser.extensions.site_access.current_site",
        comment: "Context menu item for extension access on the current site; receives the host name."
    )

    static let extensionsSiteAccessAllSites = NSLocalizedString(
        "browser.extensions.site_access.all_sites",
        comment: "Context menu item for extension access on all sites."
    )

    static let extensionsSiteAccessLearnMore = NSLocalizedString(
        "browser.extensions.site_access.learn_more",
        comment: "Context menu item for learning about extension site access."
    )

    static let extensionsRemoveFromTheBrowser = NSLocalizedString(
        "browser.extensions.remove_from_thebrowser",
        comment: "Context menu item for removing an extension from TheBrowser."
    )

    static let extensionsPinAction = NSLocalizedString(
        "browser.extensions.pin",
        comment: "Context menu item for pinning an extension."
    )

    static let extensionsUnpinAction = NSLocalizedString(
        "browser.extensions.unpin",
        comment: "Context menu item for unpinning an extension."
    )

    static let extensionsManageExtension = NSLocalizedString(
        "browser.extensions.manage_extension",
        comment: "Context menu item for opening an extension's details page."
    )

    static let extensionsViewWebPermissions = NSLocalizedString(
        "browser.extensions.view_web_permissions",
        comment: "Context menu item for opening extension web permissions."
    )

    static let extensionsInspectPopup = NSLocalizedString(
        "browser.extensions.inspect_popup",
        comment: "Context menu item for inspecting an extension popup."
    )

    static let tabRenameAction = NSLocalizedString(
        "browser.tab.rename_action",
        comment: "Context menu title for renaming a tab."
    )

    static let tabRenamePromptTitle = NSLocalizedString(
        "browser.tab.rename_prompt.title",
        comment: "Prompt title for renaming an icon-only tab."
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

    static let syncAccountSignInWithApple = NSLocalizedString(
        "browser.sync.account.sign_in_with_apple",
        comment: "Button title for signing into sync with Apple."
    )

    static let syncAccountSignOut = NSLocalizedString(
        "browser.sync.account.sign_out",
        comment: "Button title for signing out of sync."
    )

    static let syncAccountSignedIn = NSLocalizedString(
        "browser.sync.account.signed_in",
        comment: "Fallback title for a signed-in sync account."
    )

    static let syncAccountServerNotConfigured = NSLocalizedString(
        "browser.sync.account.server_not_configured",
        comment: "Message shown when sync is disabled because no server URL is configured."
    )

    static let settingsAutomaticUpdates = NSLocalizedString(
        "browser.settings.general.automatic_updates",
        comment: "Automatic updates setting title."
    )

    static let settingsAutomaticUpdatesDetail = NSLocalizedString(
        "browser.settings.general.automatic_updates.detail",
        comment: "Automatic updates row detail."
    )

    static let settingsUpdateChannel = NSLocalizedString(
        "browser.settings.general.update_channel",
        comment: "Update channel setting title."
    )

    static let settingsUpdateChannelDetail = NSLocalizedString(
        "browser.settings.general.update_channel.detail",
        comment: "Update channel setting detail."
    )

    static let updateChannelStable = NSLocalizedString(
        "browser.updates.channel.stable",
        comment: "Stable update channel title."
    )

    static let updateChannelBeta = NSLocalizedString(
        "browser.updates.channel.beta",
        comment: "Beta update channel title."
    )

    static let updateReadyTitle = NSLocalizedString(
        "browser.updates.ready.title",
        comment: "Title shown when an update has been downloaded."
    )

    static let updateRestartAction = NSLocalizedString(
        "browser.updates.restart_action",
        comment: "Button title for installing a downloaded update immediately."
    )

    static let updateDismissAction = NSLocalizedString(
        "browser.updates.dismiss_action",
        comment: "Accessibility label for dismissing the update toast."
    )

    static let settingsAppearance = NSLocalizedString(
        "browser.settings.general.appearance",
        comment: "Appearance setting title."
    )

    static let settingsAppearanceDetail = NSLocalizedString(
        "browser.settings.general.appearance.detail",
        comment: "Appearance setting detail."
    )

    static let settingsAppearanceSystem = NSLocalizedString(
        "browser.settings.general.appearance.system",
        comment: "Appearance setting option that follows the system appearance."
    )

    static let settingsAppearanceLight = NSLocalizedString(
        "browser.settings.general.appearance.light",
        comment: "Appearance setting option that forces the light appearance."
    )

    static let settingsAppearanceDark = NSLocalizedString(
        "browser.settings.general.appearance.dark",
        comment: "Appearance setting option that forces the dark appearance."
    )

    static let settingsWarnBeforeQuitting = NSLocalizedString(
        "browser.settings.general.warn_before_quitting",
        comment: "Warn before quitting setting title."
    )

    static let settingsBlurredBackground = NSLocalizedString(
        "browser.settings.general.blurred_background",
        comment: "Blurred browser background setting title."
    )

    static let settingsBatterySaver = NSLocalizedString(
        "browser.settings.general.battery_saver",
        comment: "Battery Saver setting title."
    )

    static let settingsBatterySaverDetail = NSLocalizedString(
        "browser.settings.general.battery_saver.detail",
        comment: "Battery Saver setting description."
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

    static let settingsCurrentProfile = NSLocalizedString(
        "browser.settings.profiles.current_profile",
        comment: "Label for the profile used by the current browser window."
    )

    static let settingsOpenProfile = NSLocalizedString(
        "browser.settings.profiles.open_profile",
        comment: "Button title for opening a browser window with a profile."
    )

    static let settingsNewProfile = NSLocalizedString(
        "browser.settings.profiles.new_profile",
        comment: "Button title for creating a new browser profile."
    )

    static let settingsBackUpProfile = NSLocalizedString(
        "browser.settings.profiles.back_up",
        comment: "Button title for creating a backup archive of a browser profile."
    )

    static let settingsDeleteProfile = NSLocalizedString(
        "browser.settings.profiles.delete",
        comment: "Button title for deleting a browser profile."
    )

    static let settingsDefaultBrowserPrompt = NSLocalizedString(
        "browser.settings.default_browser.prompt",
        comment: "Settings row title prompting the user to set TheBrowser as default."
    )

    static let settingsDefaultBrowserAction = NSLocalizedString(
        "browser.settings.default_browser.action",
        comment: "Settings row button title for setting TheBrowser as default."
    )

    static let settingsSearch = NSLocalizedString(
        "browser.settings.search",
        comment: "Search settings section title."
    )

    static let settingsSearchEngine = NSLocalizedString(
        "browser.settings.search_engine",
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

    static let settingsSearchEngineEcosia = NSLocalizedString(
        "browser.settings.search_engine.ecosia",
        comment: "Ecosia search engine picker title."
    )

    static let settingsSearchEngineBrave = NSLocalizedString(
        "browser.settings.search_engine.brave",
        comment: "Brave Search engine picker title."
    )

    static let settingsSearchEngineQwant = NSLocalizedString(
        "browser.settings.search_engine.qwant",
        comment: "Qwant search engine picker title."
    )

    static let settingsSearchEngineYandex = NSLocalizedString(
        "browser.settings.search_engine.yandex",
        comment: "Yandex search engine picker title."
    )

    static let settingsSearchEngineBaidu = NSLocalizedString(
        "browser.settings.search_engine.baidu",
        comment: "Baidu search engine picker title."
    )

    static let settingsManageSearch = NSLocalizedString(
        "browser.settings.manage_search",
        comment: "Manage search button title."
    )

    static let settingsSearchSuggestions = NSLocalizedString(
        "browser.settings.search_suggestions",
        comment: "Search engine suggestions toggle title."
    )

    static let settingsAISearchProvider = NSLocalizedString(
        "browser.settings.ai_search_provider",
        comment: "AI provider picker title."
    )

    static let settingsAISearchProviderChatGPT = NSLocalizedString(
        "browser.settings.ai_search_provider.chatgpt",
        comment: "ChatGPT AI provider picker title."
    )

    static let settingsAISearchProviderClaude = NSLocalizedString(
        "browser.settings.ai_search_provider.claude",
        comment: "Claude AI provider picker title."
    )

    static let settingsAISearchProviderGemini = NSLocalizedString(
        "browser.settings.ai_search_provider.gemini",
        comment: "Gemini AI provider picker title."
    )

    static let settingsAISearchProviderPerplexity = NSLocalizedString(
        "browser.settings.ai_search_provider.perplexity",
        comment: "Perplexity AI provider picker title."
    )

    static let settingsAISearchProviderDeepSeek = NSLocalizedString(
        "browser.settings.ai_search_provider.deepseek",
        comment: "DeepSeek AI provider picker title."
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

    static let settingsShortcutNotSet = NSLocalizedString(
        "browser.settings.shortcuts.not_set",
        comment: "Displayed when a command has no keyboard shortcut."
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

    static let settingsShowBookmarksBar = NSLocalizedString(
        "browser.settings.content.show_bookmarks_bar",
        comment: "Show bookmarks bar setting title."
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

    static func bookmarksOpenAllAction(count: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.bookmarks.open_all_action",
                comment: "Context menu title for opening all bookmarks in a folder. Receives the bookmark count."
            ),
            count
        )
    }

    static func commandBarAskAI(_ providerName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.command_bar.ask_ai",
                comment: "Command bar suggestion title for opening the query in the selected AI provider."
            ),
            providerName
        )
    }

    static func settingsProfileDirectory(_ directoryName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.settings.profiles.directory",
                comment: "Detail text showing the Chromium profile directory name."
            ),
            directoryName
        )
    }

    static func settingsProfileBackupCreated(_ filename: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.settings.profiles.backup_created",
                comment: "Message shown after a profile backup archive was created. The argument is the archive filename."
            ),
            filename
        )
    }

    static func settingsProfileBackupFailed(_ message: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.settings.profiles.backup_failed",
                comment: "Message shown when creating a profile backup archive fails. The argument is the error message."
            ),
            message
        )
    }

    static func syncAccountDevice(_ deviceID: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.sync.account.device",
                comment: "Sync account device detail with device identifier placeholder."
            ),
            deviceID
        )
    }

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

    static func updateReadyMessage(version: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.updates.ready.message",
                comment: "Message shown when an update is ready. The argument is the update version."
            ),
            version
        )
    }

    static func downloadsProgressKnownTotal(received: String, total: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.downloads.progress.known_total",
                comment: "Download progress detail with received and total byte counts."
            ),
            received,
            total
        )
    }

    static func downloadsProgressKnownTotalWithSpeed(
        received: String,
        total: String,
        speed: String
    ) -> String {
        String(
            format: NSLocalizedString(
                "browser.downloads.progress.known_total_with_speed",
                comment: "Download progress detail with received bytes, total bytes, and speed."
            ),
            received,
            total,
            speed
        )
    }

    static func downloadsProgressUnknownTotal(_ received: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.downloads.progress.unknown_total",
                comment: "Download progress detail when total size is unknown."
            ),
            received
        )
    }

    static func downloadsProgressUnknownTotalWithSpeed(received: String, speed: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.downloads.progress.unknown_total_with_speed",
                comment: "Download progress detail with received bytes and speed when total size is unknown."
            ),
            received,
            speed
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
