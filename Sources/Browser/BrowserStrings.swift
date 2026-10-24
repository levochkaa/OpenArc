import Foundation

// MARK: - BrowserStrings

enum BrowserStrings {
    static let beforeUnloadTitle = NSLocalizedString(
        "browser.before_unload.title",
        comment: "Manual tab close confirmation."
    )
    static let beforeUnloadMessage = NSLocalizedString(
        "browser.before_unload.message",
        comment: "Unsaved webpage warning."
    )
    static let beforeUnloadKeepTab = NSLocalizedString("browser.before_unload.keep", comment: "Cancel closing the tab.")
    static let beforeUnloadCloseTab = NSLocalizedString(
        "browser.before_unload.close",
        comment: "Confirm closing the tab."
    )

    static let archiveTitle = NSLocalizedString(
        "browser.archive.title",
        comment: "Window title."
    )
    static let archiveMenuTitle = NSLocalizedString(
        "browser.archive.menu",
        comment: "Open the profile Archive."
    )
    static let archiveViewAction = NSLocalizedString(
        "browser.archive.view",
        comment: "Command Bar action to open the profile Archive."
    )
    static let archiveSearch = NSLocalizedString(
        "browser.archive.search",
        comment: "Archive search placeholder."
    )
    static let archiveRestore = NSLocalizedString(
        "browser.archive.restore",
        comment: "Restore an archived tab with a new identity."
    )
    static let archiveRemove = NSLocalizedString(
        "browser.archive.remove",
        comment: "Remove an archive entry."
    )
    static let archiveClear = NSLocalizedString(
        "browser.archive.clear",
        comment: "Clear local archive entries."
    )
    static let archiveClearConfirm = NSLocalizedString(
        "browser.archive.clear_confirm",
        comment: "Confirm clearing the captured archive entries."
    )
    static let archiveClearMessage = NSLocalizedString(
        "browser.archive.clear_message",
        comment: "Archive clear confirmation scope."
    )
    static let archiveDestinationTitle = NSLocalizedString(
        "browser.archive.destination_title",
        comment: "Missing original Space recovery title."
    )
    static let archiveDestinationMessage = NSLocalizedString(
        "browser.archive.destination_message",
        comment: "Explicit archive destination."
    )
    static let archiveEmpty = NSLocalizedString(
        "browser.archive.empty",
        comment: "Empty archive."
    )
    static let archiveNoResults = NSLocalizedString(
        "browser.archive.no_results",
        comment: "Empty archive search."
    )
    static let archiveLoading = NSLocalizedString(
        "browser.archive.loading",
        comment: "Archive loading state."
    )
    static let archiveNewer = NSLocalizedString(
        "browser.archive.newer",
        comment: "Previous archive page."
    )
    static let archiveOlder = NSLocalizedString(
        "browser.archive.older",
        comment: "Next archive page."
    )
    static let archiveColumnTitle = NSLocalizedString(
        "browser.archive.column_title",
        comment: "Archive title column."
    )
    static let archiveColumnURL = NSLocalizedString(
        "browser.archive.column_url",
        comment: "Archive URL column."
    )
    static let archiveColumnDate = NSLocalizedString(
        "browser.archive.column_date",
        comment: "Archive date column."
    )
    static let archiveRestoreFailed = NSLocalizedString(
        "browser.archive.restore_failed",
        comment: "Durable restore failure."
    )
    static let archiveDestinationMissing = NSLocalizedString(
        "browser.archive.destination_missing",
        comment: "Missing destination."
    )
    static let archiveEntryMissing = NSLocalizedString(
        "browser.archive.entry_missing",
        comment: "Missing or consumed archive entry."
    )
    static let archiveActionFailed = NSLocalizedString(
        "browser.archive.action_failed",
        comment: "Archive operation failure."
    )
    static let archiveUnavailable = NSLocalizedString(
        "browser.archive.unavailable",
        comment: "Archive unavailable state."
    )
    static let archiveSearchInvalid = NSLocalizedString(
        "browser.archive.search_invalid",
        comment: "Invalid archive query."
    )

    static let sessionRecoveryTitle = NSLocalizedString(
        "browser.session.recovery.title",
        comment: "Unsaved session banner title."
    )
    static let sessionRecoveryRetryMessage = NSLocalizedString(
        "browser.session.recovery.retry_message",
        comment: "Temporary persistence failure."
    )
    static let sessionRecoveryTerminalMessage = NSLocalizedString(
        "browser.session.recovery.terminal_message",
        comment: "Session cannot be retried safely."
    )
    static let sessionRecoveryRetry = NSLocalizedString(
        "browser.session.recovery.retry",
        comment: "Retry saving the session."
    )
    static let sessionRecoverySaveCopy = NSLocalizedString(
        "browser.session.recovery.save_copy",
        comment: "Export the unsaved session."
    )
    static let sessionRecoveryExportFailed = NSLocalizedString(
        "browser.session.recovery.export_failed",
        comment: "Session export error title."
    )
    static let sessionRecoveryCloseTitle = NSLocalizedString(
        "browser.session.recovery.close_title",
        comment: "Confirm loss of unsaved session changes."
    )
    static let sessionRecoveryCloseMessage = NSLocalizedString(
        "browser.session.recovery.close_message",
        comment: "Cancel to export a session copy."
    )
    static let sessionRecoveryCloseWithoutSaving = NSLocalizedString(
        "browser.session.recovery.close_without_saving",
        comment: "Explicitly discard unsaved changes."
    )
    static let sessionRecoveryCloseProfileBeforeDeleting = NSLocalizedString(
        "browser.session.recovery.close_profile_before_deleting",
        comment: "Open profiles cannot be deleted."
    )
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

    static let pinnedTabFolderDeleteAction = NSLocalizedString(
        "browser.pinned_tab_folder.delete_action",
        comment: "Context menu action deleting a pinned folder and its current contents."
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

    static let loadingOpeningTab = NSLocalizedString(
        "browser.loading.opening_tab",
        comment: "Loading message shown while a tab opens."
    )

    static let tabCreationFailedTitle = NSLocalizedString(
        "browser.tab.creation_failed.title",
        comment: "Title shown when a tab could not open."
    )

    static let tabCreationFailedMessage = NSLocalizedString(
        "browser.tab.creation_failed.message",
        comment: "Recovery instruction shown when a tab could not open."
    )

    static let tabCreationRetry = NSLocalizedString(
        "browser.tab.creation_failed.retry",
        comment: "Button that retries opening the selected tab."
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

    static let menuNewLittleWindow = NSLocalizedString(
        "browser.menu.new_little_window",
        comment: "File menu item and command that opens a small window of its own."
    )

    static let peekOpenInMenuTitle = NSLocalizedString(
        "browser.peek.open_in",
        comment: "Header of the menu that moves a Peek card or small window into a Space as a tab."
    )

    static let peekAddressPlaceholder = NSLocalizedString(
        "browser.peek.address_placeholder",
        comment: "Placeholder of the small window's address field."
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

    static let menuAddSplitView = NSLocalizedString(
        "browser.menu.add_split_view",
        comment: "Add Split View menu item title."
    )

    static let menuCloseSplitPane = NSLocalizedString(
        "browser.menu.close_split_pane",
        comment: "Close this Split Pane menu item title."
    )

    static let menuSeparatePageFromSplitView = NSLocalizedString(
        "browser.menu.separate_page_from_split_view",
        comment: "Separate Page from Split View menu item title."
    )

    static let menuToggleSplitOrientation = NSLocalizedString(
        "browser.menu.toggle_split_orientation",
        comment: "Settings and command title for switching a split between side by side and stacked panes."
    )

    static let menuFocusNextSplitPane = NSLocalizedString(
        "browser.menu.focus_next_split_pane",
        comment: "Command title that focuses the next Split View pane."
    )

    static let menuFocusPreviousSplitPane = NSLocalizedString(
        "browser.menu.focus_previous_split_pane",
        comment: "Command title that focuses the previous Split View pane."
    )

    static let splitMovePaneLeft = NSLocalizedString(
        "browser.split.move_left",
        comment: "Split View Menu action that moves the focused pane one place to the left."
    )

    static let splitMovePaneRight = NSLocalizedString(
        "browser.split.move_right",
        comment: "Split View Menu action that moves the focused pane one place to the right."
    )

    static let splitMovePaneUp = NSLocalizedString(
        "browser.split.move_up",
        comment: "Split View Menu action that moves the focused pane of a stacked split up."
    )

    static let splitMovePaneDown = NSLocalizedString(
        "browser.split.move_down",
        comment: "Split View Menu action that moves the focused pane of a stacked split down."
    )

    static let splitAddLeft = NSLocalizedString(
        "browser.split.add_left",
        comment: "Split View Menu action that adds a pane left of the focused pane."
    )

    static let splitAddRight = NSLocalizedString(
        "browser.split.add_right",
        comment: "Split View Menu action that adds a pane right of the focused pane."
    )

    static let splitAddTop = NSLocalizedString(
        "browser.split.add_top",
        comment: "Split View Menu action that adds a pane above the focused pane of a stacked split."
    )

    static let splitAddBottom = NSLocalizedString(
        "browser.split.add_bottom",
        comment: "Split View Menu action that adds a pane below the focused pane of a stacked split."
    )

    static let menuExpandCurrentSplit = NSLocalizedString(
        "browser.menu.expand_current_split",
        comment: "View menu and command title that shows only the focused Split View pane."
    )

    static let menuShowAllSplitPanes = NSLocalizedString(
        "browser.menu.show_all_split_panes",
        comment: "View menu and command title that restores every pane after Expand Current Split."
    )

    static let settingsSidebarPosition = NSLocalizedString(
        "browser.settings.sidebar_position",
        comment: "Settings title for the window edge that shows the sidebar."
    )

    static let settingsSidebarPositionLeft = NSLocalizedString(
        "browser.settings.sidebar_position.left",
        comment: "Sidebar position option: the left window edge."
    )

    static let settingsSidebarPositionRight = NSLocalizedString(
        "browser.settings.sidebar_position.right",
        comment: "Sidebar position option: the right window edge."
    )

    static let menuMoveSidebarRight = NSLocalizedString(
        "browser.menu.move_sidebar_right",
        comment: "View menu and command title that moves the sidebar to the right window edge."
    )

    static let menuShowToolbar = NSLocalizedString(
        "browser.menu.show_toolbar",
        comment: "View menu and command title that shows the page URL as a toolbar above the page."
    )

    static let menuHideToolbar = NSLocalizedString(
        "browser.menu.hide_toolbar",
        comment: "View menu and command title that moves the page URL from the toolbar back into the sidebar."
    )

    static let splitPaneGripAccessibilityLabel = NSLocalizedString(
        "browser.split.pane_grip",
        comment: "Accessibility label of the handle that reorders a Split View pane by dragging."
    )

    static let menuDeveloperTools = NSLocalizedString(
        "browser.menu.developer_tools",
        comment: "View menu and command title that opens the page's developer tools."
    )

    static let menuViewSource = NSLocalizedString(
        "browser.menu.view_source",
        comment: "View menu and command title that opens the page's HTML source in a new tab."
    )

    static let settingsImportArcSidebar = NSLocalizedString(
        "browser.settings.import_arc_sidebar",
        comment: "Settings import button that adds Arc's Spaces, pinned tabs, folders and Favorites."
    )

    static let arcImportMissing = NSLocalizedString(
        "browser.arc_import.missing",
        comment: "Alert shown when Arc's sidebar file does not exist."
    )

    static let arcImportUnreadable = NSLocalizedString(
        "browser.arc_import.unreadable",
        comment: "Alert shown when Arc's sidebar file cannot be parsed."
    )

    static let arcImportNothing = NSLocalizedString(
        "browser.arc_import.nothing",
        comment: "Alert shown when Arc's sidebar has nothing to import."
    )

    static let arcImportUnavailable = NSLocalizedString(
        "browser.arc_import.unavailable",
        comment: "Alert shown when the window cannot take an import right now."
    )

    static let peekCloseAction = NSLocalizedString("browser.peek.close", comment: "Button that closes a Peek card.")

    static let peekOpenInSplitViewAction = NSLocalizedString(
        "browser.peek.open_in_split_view",
        comment: "Button that moves a Peek card's page into a Split View beside the page behind it."
    )

    static let peekOpenInTabAction = NSLocalizedString(
        "browser.peek.open_in_tab",
        comment: "Button that moves a Peek card's page into a tab."
    )

    static let settingsPeek = NSLocalizedString(
        "browser.settings.peek",
        comment: "Settings toggle: Shift-clicked links open in a floating Peek card."
    )

    static let settingsLittleArc = NSLocalizedString(
        "browser.settings.little_arc",
        comment: "Settings toggle: links from other apps open in a small window of their own."
    )

    static let settingsLittleArcDetail = NSLocalizedString(
        "browser.settings.little_arc.detail",
        comment: "Settings detail for the small window for links from other apps."
    )

    static let settingsPeekDetail = NSLocalizedString(
        "browser.settings.peek.detail",
        comment: "Settings detail for the Peek toggle."
    )

    static let settingsLittleWindowOptionCommandClick = NSLocalizedString(
        "browser.settings.little_window_option_command_click",
        comment: "Settings toggle: Option-Command-clicked links open in a small window of their own."
    )

    static let settingsLittleWindowFromAnyApp = NSLocalizedString(
        "browser.settings.little_window_any_app",
        comment: "Settings toggle: Option-Command-N opens a small window even while another app is active."
    )

    static let settingsFolderPreviews = NSLocalizedString(
        "browser.settings.folder_previews",
        comment: "Settings toggle: resting the pointer on a collapsed sidebar folder lists its tabs."
    )

    static let folderPreviewSearchPlaceholder = NSLocalizedString(
        "browser.folder_preview.search_placeholder",
        comment: "Placeholder of the search field in a sidebar folder's preview."
    )

    static let settingsPeekOtherSites = NSLocalizedString(
        "browser.settings.peek_other_sites",
        comment: "Settings toggle: links to other sites from pinned tabs and Favorites open in Peek."
    )

    static let settingsPeekOtherSitesDetail = NSLocalizedString(
        "browser.settings.peek_other_sites.detail",
        comment: "Settings detail for opening links to other sites from pinned tabs in Peek."
    )

    static let settingsLinkRoutesTitle = NSLocalizedString(
        "browser.settings.link_routes",
        comment: "Settings section of rules that choose where links from other apps open."
    )

    static let settingsLinkRoutesDetail = NSLocalizedString(
        "browser.settings.link_routes.detail",
        comment: "Settings detail explaining the rules for links from other apps."
    )

    static let settingsLinkRouteSite = NSLocalizedString(
        "browser.settings.link_routes.site",
        comment: "Link rule condition: the link is on this site."
    )

    static let settingsLinkRouteContains = NSLocalizedString(
        "browser.settings.link_routes.contains",
        comment: "Link rule condition: the link's address contains this text."
    )

    static let settingsLinkRoutePatternPlaceholder = NSLocalizedString(
        "browser.settings.link_routes.pattern_placeholder",
        comment: "Placeholder of a link rule's site or text field."
    )

    static let settingsLinkRouteOpensIn = NSLocalizedString(
        "browser.settings.link_routes.opens_in",
        comment: "Label between a link rule's condition and its destination."
    )

    static let settingsLinkRouteLittleWindow = NSLocalizedString(
        "browser.settings.link_routes.little_window",
        comment: "Link rule destination: a small window of its own."
    )

    static let settingsLinkRouteAdd = NSLocalizedString(
        "browser.settings.link_routes.add",
        comment: "Button that adds a rule for links from other apps."
    )

    static let settingsLinkRouteRemove = NSLocalizedString(
        "browser.settings.link_routes.remove",
        comment: "Accessibility label of the button that removes a link rule."
    )

    static let menuRestoreLastClosedTab = NSLocalizedString(
        "browser.menu.restore_last_closed_tab",
        comment: "File menu and command title that reopens the most recently closed tab."
    )

    static let menuOpenLocation = NSLocalizedString(
        "browser.menu.open_location",
        comment: "File menu and command title that edits the current page's URL in the command bar."
    )

    static let menuTabs = NSLocalizedString("browser.menu.tabs", comment: "Title of the Tabs menu.")

    static let menuSpaces = NSLocalizedString("browser.menu.spaces", comment: "Title of the Spaces menu.")

    static let menuPinTab = NSLocalizedString(
        "browser.menu.pin_tab",
        comment: "Tabs menu and command title that moves the selected tab into the pinned tabs."
    )

    static let menuUnpinTab = NSLocalizedString(
        "browser.menu.unpin_tab",
        comment: "Tabs menu and command title that moves the selected pinned tab back to the temporary tabs."
    )

    static let menuDuplicateTab = NSLocalizedString(
        "browser.menu.duplicate_tab",
        comment: "Tabs menu and command title that opens a copy of the selected tab."
    )

    static let menuRenameTab = NSLocalizedString(
        "browser.menu.rename_tab",
        comment: "Tabs menu and command title that starts renaming the selected tab in the sidebar."
    )

    static let menuResetTabToPinnedURL = NSLocalizedString(
        "browser.menu.reset_tab_to_pinned_url",
        comment: "Tabs menu and command title that returns a pinned tab to its pinned URL."
    )

    static let spaceChangeColorAction = NSLocalizedString(
        "browser.space.change_color_action",
        comment: "Space menu submenu that tints the window for the Space."
    )

    static let spaceColorNone = NSLocalizedString(
        "browser.space.color.none",
        comment: "Space color option that keeps the window neutral."
    )

    static let spaceColorBlue = NSLocalizedString(
        "browser.space.color.blue",
        comment: "Space color option."
    )

    static let spaceColorPurple = NSLocalizedString(
        "browser.space.color.purple",
        comment: "Space color option."
    )

    static let spaceColorPink = NSLocalizedString(
        "browser.space.color.pink",
        comment: "Space color option."
    )

    static let spaceColorRed = NSLocalizedString(
        "browser.space.color.red",
        comment: "Space color option."
    )

    static let spaceColorOrange = NSLocalizedString(
        "browser.space.color.orange",
        comment: "Space color option."
    )

    static let spaceColorYellow = NSLocalizedString(
        "browser.space.color.yellow",
        comment: "Space color option."
    )

    static let spaceColorGreen = NSLocalizedString(
        "browser.space.color.green",
        comment: "Space color option."
    )

    static let spaceColorTeal = NSLocalizedString(
        "browser.space.color.teal",
        comment: "Space color option."
    )

    static let spaceColorGray = NSLocalizedString(
        "browser.space.color.gray",
        comment: "Space color option."
    )

    static let menuResetSpaceTabs = NSLocalizedString(
        "browser.menu.reset_space_tabs",
        comment: "Spaces menu, Space menu and command title that returns every pinned tab of the Space to its pinned page."
    )

    static let menuCollapseAllFolders = NSLocalizedString(
        "browser.menu.collapse_all_folders",
        comment: "Tabs menu and command title that collapses every folder of the Space."
    )

    static let menuExpandAllFolders = NSLocalizedString(
        "browser.menu.expand_all_folders",
        comment: "Tabs menu and command title that expands every folder of the Space."
    )

    static let menuViewDownloads = NSLocalizedString(
        "browser.menu.view_downloads",
        comment: "View menu and command title that opens the downloads list."
    )

    static let menuSelectNextTabAlternate = NSLocalizedString(
        "browser.menu.select_next_tab_alternate",
        comment: "Settings shortcut title for the second shortcut of Next Tab."
    )

    static let menuSelectPreviousTabAlternate = NSLocalizedString(
        "browser.menu.select_previous_tab_alternate",
        comment: "Settings shortcut title for the second shortcut of Previous Tab."
    )

    static let menuSelectNextSpace = NSLocalizedString(
        "browser.menu.select_next_space",
        comment: "View menu and command title that switches to the next Space."
    )

    static let menuSelectPreviousSpace = NSLocalizedString(
        "browser.menu.select_previous_space",
        comment: "View menu and command title that switches to the previous Space."
    )

    static let settingsDownloadsTitle = NSLocalizedString(
        "browser.settings.downloads",
        comment: "Settings section title for downloads."
    )

    static let settingsDownloadLocation = NSLocalizedString(
        "browser.settings.download_location",
        comment: "Settings row title for the folder that receives downloads."
    )

    static let settingsDownloadLocationChoose = NSLocalizedString(
        "browser.settings.download_location.choose",
        comment: "Button that picks another folder for downloads."
    )

    static let settingsDownloadLocationReset = NSLocalizedString(
        "browser.settings.download_location.reset",
        comment: "Button that saves downloads to the Downloads folder again."
    )

    static let menuOpenExtensions = NSLocalizedString(
        "browser.menu.open_extensions",
        comment: "View menu and command title that opens the site control center with the extensions."
    )

    static let menuRevealCurrentTab = NSLocalizedString(
        "browser.menu.reveal_current_tab",
        comment: "View menu and command title that scrolls the sidebar to the selected tab and shows it."
    )

    static let menuCopyLinkAsMarkdown = NSLocalizedString(
        "browser.menu.copy_link_as_markdown",
        comment: "Edit menu and command title that copies the page as a Markdown link."
    )

    static let menuSelectNextTab = NSLocalizedString(
        "browser.menu.select_next_tab",
        comment: "View menu and command title that selects the next item in the sidebar."
    )

    static let menuSelectPreviousTab = NSLocalizedString(
        "browser.menu.select_previous_tab",
        comment: "View menu and command title that selects the previous item in the sidebar."
    )

    static let menuGoToLastSidebarItem = NSLocalizedString(
        "browser.menu.go_to_last_sidebar_item",
        comment: "Command title that selects the last tab in the sidebar."
    )

    static let menuMoveSidebarLeft = NSLocalizedString(
        "browser.menu.move_sidebar_left",
        comment: "View menu and command title that moves the sidebar to the left window edge."
    )

    static let splitViewButtonTitle = NSLocalizedString(
        "browser.split.button",
        comment: "Toolbar button and menu title for Split View."
    )

    static let splitDividerAccessibilityLabel = NSLocalizedString(
        "browser.split.divider",
        comment: "Accessibility label of the handle that resizes Split View panes."
    )

    static let splitOpenInSplitViewAction = NSLocalizedString(
        "browser.split.open_in_split_view",
        comment: "Tab context menu action that opens the tab as a new Split View pane."
    )

    static let splitSeparateTabAction = NSLocalizedString(
        "browser.split.separate_tab",
        comment: "Removes one tab from its Split View."
    )

    static let splitSeparateAllTabsAction = NSLocalizedString(
        "browser.split.separate_all_tabs",
        comment: "Ends a Split View and keeps its tabs as separate tabs."
    )

    static let splitConvertToVerticalAction = NSLocalizedString(
        "browser.split.convert_to_vertical",
        comment: "Stacks Split View panes top to bottom."
    )

    static let splitConvertToHorizontalAction = NSLocalizedString(
        "browser.split.convert_to_horizontal",
        comment: "Places Split View panes side by side."
    )

    static let menuToggleSidebar = NSLocalizedString(
        "browser.menu.toggle_sidebar",
        comment: "Toggle Sidebar menu item title."
    )

    static let menuClearTemporaryTabs = NSLocalizedString(
        "browser.menu.clear_temporary_tabs",
        comment: "Clear Temporary Tabs menu item title."
    )

    static let webAppInstallAction = NSLocalizedString(
        "browser.web_app.install_action",
        comment: "Menu item for installing the current website as a standalone app."
    )

    static let webAppInfoAction = NSLocalizedString(
        "browser.web_app.info_action",
        comment: "Menu item for showing information about an installed web app."
    )

    static let webAppCopyURLAction = NSLocalizedString(
        "browser.web_app.copy_url_action",
        comment: "Menu item for copying the current URL from a web app."
    )

    static let webAppOpenInBrowserAction = NSLocalizedString(
        "browser.web_app.open_in_browser_action",
        comment: "Menu item for opening the current web app page in the main browser."
    )

    static let webAppCloseWindowAction = NSLocalizedString(
        "browser.web_app.close_window_action",
        comment: "File menu item for closing a web app window."
    )

    static let webAppZoomOutAction = NSLocalizedString(
        "browser.web_app.zoom_out_action",
        comment: "Menu item for decreasing web app page zoom."
    )

    static let webAppZoomResetAction = NSLocalizedString(
        "browser.web_app.zoom_reset_action",
        comment: "Menu item for resetting web app page zoom."
    )

    static let webAppZoomInAction = NSLocalizedString(
        "browser.web_app.zoom_in_action",
        comment: "Menu item for increasing web app page zoom."
    )

    static let webAppEditMenu = NSLocalizedString(
        "browser.web_app.edit_menu",
        comment: "Edit submenu title in a web app's More menu."
    )

    static let webAppCastAction = NSLocalizedString(
        "browser.web_app.cast_action",
        comment: "Cast menu item in a web app."
    )

    static let webAppMoreAction = NSLocalizedString(
        "browser.web_app.more_action",
        comment: "Tooltip for the web app More menu."
    )

    static let webAppAlwaysShowToolbarInFullscreen = NSLocalizedString(
        "browser.web_app.always_show_toolbar_in_fullscreen",
        comment: "View menu item controlling web app toolbar visibility in fullscreen."
    )

    static let webAppAlwaysShowFullURLs = NSLocalizedString(
        "browser.web_app.always_show_full_urls",
        comment: "View menu item controlling whether a web app displays full URLs."
    )

    static let webAppInstallPromptTitle = NSLocalizedString(
        "browser.web_app.install_prompt.title",
        comment: "Title of the web app installation prompt."
    )

    static let webAppInstallPromptMessage = NSLocalizedString(
        "browser.web_app.install_prompt.message",
        comment: "Message of the web app installation prompt."
    )

    static let webAppInstallButton = NSLocalizedString(
        "browser.web_app.install_prompt.install",
        comment: "Confirmation button in the web app installation prompt."
    )

    static let cancelAction = NSLocalizedString(
        "browser.action.cancel",
        comment: "Generic cancel button title."
    )

    static let webAppOperationFailedTitle = NSLocalizedString(
        "browser.web_app.operation_failed.title",
        comment: "Title of an alert shown when a web app operation fails."
    )

    static let webAppUninstallPromptTitle = NSLocalizedString(
        "browser.web_app.uninstall_prompt.title",
        comment: "Title of the web app uninstall confirmation alert."
    )

    static let webAppUninstallButton = NSLocalizedString(
        "browser.web_app.uninstall_prompt.uninstall",
        comment: "Confirmation button in the web app uninstall alert."
    )

    static let webAppInfoInstalledWith = NSLocalizedString(
        "browser.web_app.info.installed_with",
        comment: "Footer in web app information identifying TheBrowser."
    )

    static let webAppInfoDoneAction = NSLocalizedString(
        "browser.web_app.info.done_action",
        comment: "Button closing the web app information alert."
    )

    static let webAppErrorApplicationsDirectoryUnavailable = NSLocalizedString(
        "browser.web_app.error.applications_directory_unavailable",
        comment: "Error shown when the user's Applications directory is unavailable."
    )

    static let webAppErrorInvalidHostBundle = NSLocalizedString(
        "browser.web_app.error.invalid_host_bundle",
        comment: "Error shown when TheBrowser's host app bundle is invalid."
    )

    static let webAppErrorInvalidName = NSLocalizedString(
        "browser.web_app.error.invalid_name",
        comment: "Error shown when a web app name is invalid."
    )

    static let webAppErrorMissingHostExecutable = NSLocalizedString(
        "browser.web_app.error.missing_host_executable",
        comment: "Error shown when TheBrowser's executable is unavailable for a web app shim."
    )

    static let webAppErrorMissingLauncherExecutable = NSLocalizedString(
        "browser.web_app.error.missing_launcher_executable",
        comment: "Error shown when TheBrowser's dedicated web app launcher is unavailable."
    )

    static let webAppErrorUnsupportedURL = NSLocalizedString(
        "browser.web_app.error.unsupported_url",
        comment: "Error shown when a page cannot be installed as a web app."
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

    static let splitRenameAction = NSLocalizedString(
        "browser.split.rename_action",
        comment: "Split View row menu item and prompt title that names the split."
    )

    static let splitChangeIconAction = NSLocalizedString(
        "browser.split.change_icon_action",
        comment: "Split View row menu submenu that picks the split's icon."
    )

    static let splitArchiveAction = NSLocalizedString(
        "browser.split.archive_action",
        comment: "Split View row menu item that archives every pane of the split."
    )

    static let tabMuteAction = NSLocalizedString(
        "browser.tab.mute_action",
        comment: "Context menu title that silences a tab."
    )

    static let tabUnmuteAction = NSLocalizedString(
        "browser.tab.unmute_action",
        comment: "Context menu and button title that lets a muted tab play sound again."
    )

    static let tabDuplicateAction = NSLocalizedString(
        "browser.tab.duplicate_action",
        comment: "Context menu title that opens a copy of the tab below it."
    )

    static let tabMoveToSpaceAction = NSLocalizedString(
        "browser.tab.move_to_space_action",
        comment: "Context menu submenu title listing the Spaces a tab can move to."
    )

    static let tabArchiveOtherTabsAction = NSLocalizedString(
        "browser.tab.archive_other_tabs_action",
        comment: "Context menu title for archiving the other temporary tabs of the Space."
    )

    static let tabArchiveTabsAboveAction = NSLocalizedString(
        "browser.tab.archive_tabs_above_action",
        comment: "Context menu title for archiving the temporary tabs above the current tab."
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

    static let menuCaptureArea = NSLocalizedString(
        "browser.menu.capture_area",
        comment: "File menu and command title that lets the user outline part of the page to copy as an image."
    )

    static let captureAreaAccessibilityLabel = NSLocalizedString(
        "browser.capture_area.accessibility",
        comment: "Accessibility label of the overlay where the user outlines part of the page to capture."
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

    static let tabChangeIconAction = NSLocalizedString(
        "browser.tab.change_icon_action",
        comment: "Tab menu submenu that shows a symbol in place of the tab's site icon."
    )

    static let tabSiteIconAction = NSLocalizedString(
        "browser.tab.site_icon_action",
        comment: "Change Icon submenu item that goes back to the tab's site icon."
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

    static let syncAccountEnable = NSLocalizedString(
        "browser.sync.account.enable",
        comment: "Enable profile sync button."
    )
    static let syncAccountEnableDetail = NSLocalizedString(
        "browser.sync.account.enable_detail",
        comment: "Consent to sync this profile."
    )
    static let syncAccountEnabled = NSLocalizedString("browser.sync.account.enabled", comment: "Sync enabled status.")
    static let syncAccountDifferentOwner = NSLocalizedString(
        "browser.sync.account.different_owner",
        comment: "Sync profile belongs to another account."
    )
    static let syncAccountSignInAgain = NSLocalizedString(
        "browser.sync.account.sign_in_again",
        comment: "Credentials need fresh sign-in."
    )
    static let syncAccountUnavailable = NSLocalizedString(
        "browser.sync.account.unavailable",
        comment: "Durable sync store unavailable."
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

    static let settingsLinksTab = NSLocalizedString(
        "browser.settings.links_tab",
        comment: "Settings pane for the small window, Peek and rules for links from other apps."
    )

    static let settingsSmallWindowSection = NSLocalizedString(
        "browser.settings.small_window_section",
        comment: "Settings section title for the small window of its own."
    )

    static let settingsPeekSection = NSLocalizedString(
        "browser.settings.peek_section",
        comment: "Settings section title for Peek, the floating card for links."
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

    static let settingsAutomaticArchivalOff = NSLocalizedString(
        "browser.settings.automatic_archival.off",
        comment: "Disable automatic archiving for this synchronized profile."
    )
    static let settingsAutomaticArchivalThirtyDays = NSLocalizedString(
        "browser.settings.automatic_archival.30d",
        comment: "Thirty days without the local-only Default label; synced profiles default to Off."
    )
    static let settingsAutomaticArchivalSyncDescription = NSLocalizedString(
        "browser.settings.automatic_archival.sync_description",
        comment: "Synchronized automatic archive behavior and recovery entry point."
    )
    static let settingsTemporaryTabsSyncUnavailable = NSLocalizedString(
        "browser.settings.temporary_tabs.sync_unavailable",
        comment: "Explains why automatic archiving is disabled for synchronized desktop profiles."
    )

    static let settingsTemporaryTabsSaveFailed = NSLocalizedString(
        "browser.settings.temporary_tabs.save_failed",
        comment: "Archive timing preference could not be saved."
    )

    static let settingsTemporaryTabsLoadFailed = NSLocalizedString(
        "browser.settings.temporary_tabs.load_failed",
        comment: "Automatic archive settings could not be read."
    )

    static let settingsLifetimeTwentyFourHours = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.24h",
        comment: "Option title for archiving temporary tabs after 24 hours."
    )

    static let settingsLifetimeSevenDays = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.7d",
        comment: "Option title for archiving temporary tabs after 7 days."
    )

    static let settingsLifetimeThreeDays = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.3d",
        comment: "Option title for archiving temporary tabs after 3 days."
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

    static let menuHideOthers = NSLocalizedString(
        "browser.menu.hide_others",
        comment: "App menu item that hides the other apps."
    )

    static let menuShowAll = NSLocalizedString(
        "browser.menu.show_all",
        comment: "App menu item that shows every hidden app."
    )

    static let menuServices = NSLocalizedString(
        "browser.menu.services",
        comment: "App menu title of the system Services submenu."
    )

    static let menuWindow = NSLocalizedString(
        "browser.menu.window",
        comment: "Title of the Window menu."
    )

    static let menuMinimize = NSLocalizedString(
        "browser.menu.minimize",
        comment: "Window menu item that minimizes the front window."
    )

    static let menuZoom = NSLocalizedString(
        "browser.menu.zoom",
        comment: "Window menu item that zooms the front window."
    )

    static let menuBringAllToFront = NSLocalizedString(
        "browser.menu.bring_all_to_front",
        comment: "Window menu item that brings every app window to the front."
    )

    /// A rule's Space that this window does not have: closed in another profile or deleted.
    static func settingsLinkRouteUnavailableSpace(_ title: String?, profileName: String?) -> String {
        let space = title ?? NSLocalizedString(
            "browser.settings.link_routes.missing_space",
            comment: "Link rule destination whose Space no longer exists."
        )
        guard let profileName else { return space }
        return String(
            format: NSLocalizedString(
                "browser.settings.link_routes.other_profile_space",
                comment: "Link rule destination in another profile. The arguments are the Space and profile names."
            ),
            space,
            profileName
        )
    }

    /// Shared with iOS, so it takes counts rather than the macOS import result.
    static func arcImportResult(spaces: Int, pinnedTabs: Int, folders: Int, favorites: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.arc_import.result",
                comment: "Alert after importing from Arc: Spaces, pinned tabs, folders, Favorites."
            ),
            spaces,
            pinnedTabs,
            folders,
            favorites
        )
    }

    static func menuGoToSidebarItem(_ number: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.go_to_sidebar_item",
                comment: "Command title that selects a sidebar tab by its position. %d is 1 to 8."
            ),
            number
        )
    }

    static func splitFocusPaneTitle(_ number: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.focus_split_pane",
                comment: "Command title that focuses a Split View pane by its position. %d is 1 to 4."
            ),
            number
        )
    }

    static func webAppErrorBundleSigningFailed(_ details: String) -> String {
        let format = NSLocalizedString(
            "browser.web_app.error.bundle_signing_failed",
            comment: "Error shown when the generated web app bundle cannot be signed."
        )
        return String(format: format, details)
    }

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

    static func hideMenuItem(appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.hide",
                comment: "Hide menu item title with the app name placeholder."
            ),
            appName
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

    static func webAppUninstallAction(_ appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.web_app.uninstall_action",
                comment: "Menu item for uninstalling a web app, with its name as the placeholder."
            ),
            appName
        )
    }

    static func webAppZoomMenu(_ percent: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.web_app.zoom_menu",
                comment: "Web app zoom submenu title with the current percentage."
            ),
            percent
        )
    }

    static func webAppUninstallPromptMessage(_ appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.web_app.uninstall_prompt.message",
                comment: "Uninstall confirmation message with the web app name."
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

    #if os(macOS)
    static func title(for lifetime: BrowserTemporaryTabLifetime) -> String {
        switch lifetime {
        case .twelveHours:
            settingsLifetimeTwelveHours
        case .twentyFourHours:
            settingsLifetimeTwentyFourHours
        case .threeDays:
            settingsLifetimeThreeDays
        case .sevenDays:
            settingsLifetimeSevenDays
        case .thirtyDays:
            settingsLifetimeThirtyDays
        }
    }
    #endif
}
