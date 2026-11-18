// BrowserStrings.swift

import Foundation

// MARK: - BrowserStrings

enum BrowserStrings {
    static let menuOpenPageInWebKit = NSLocalizedString(
        "browser.menu.open_page_in_webkit",
        comment: "View menu: show the page in WebKit, which plays protected video.",
    )
    static let menuOpenPageInChromium = NSLocalizedString(
        "browser.menu.open_page_in_chromium",
        comment: "View menu: show a WebKit page in Chromium again.",
    )
    static let settingsProtectedVideoSection = NSLocalizedString(
        "browser.settings.protected_video.section",
        comment: "Settings section about DRM video.",
    )
    static let settingsStreamingInWebKit = NSLocalizedString(
        "browser.settings.protected_video.webkit",
        comment: "Settings toggle: pages whose protected video fails in Chromium move to WebKit.",
    )
    static let settingsStreamingInWebKitDetail = NSLocalizedString(
        "browser.settings.protected_video.webkit.detail",
        comment: "Explains the protected video toggle.",
    )
    static let settingsFairPlayInChromium = NSLocalizedString(
        "browser.settings.protected_video.fairplay",
        comment: "Settings toggle: play protected media in Chromium through FairPlay.",
    )
    static let settingsFairPlayInChromiumDetail = NSLocalizedString(
        "browser.settings.protected_video.fairplay.detail",
        comment: "Explains the FairPlay in Chromium toggle.",
    )
    static let settingsSiteEnginesReset = NSLocalizedString(
        "browser.settings.protected_video.reset",
        comment: "Settings button: forget the engine chosen for each website.",
    )
    static let settingsSiteEnginesResetDetail = NSLocalizedString(
        "browser.settings.protected_video.reset.detail",
        comment: "Explains the reset of website engine choices.",
    )
    static let protectedVideoPromptTitle = NSLocalizedString(
        "browser.protected_video.prompt.title",
        comment: "Prompt title when Chromium cannot play a page's protected video.",
    )
    static let protectedVideoPromptDetail = NSLocalizedString(
        "browser.protected_video.prompt.detail",
        comment: "Prompt detail; the argument is the site's host.",
    )
    static let protectedVideoPromptOpen = NSLocalizedString(
        "browser.protected_video.prompt.open",
        comment: "Prompt button: open the page in WebKit and keep that for the site.",
    )
    static let protectedVideoPromptStay = NSLocalizedString(
        "browser.protected_video.prompt.stay",
        comment: "Prompt button: keep the page in Chromium.",
    )
    static let protectedVideoPromptNever = NSLocalizedString(
        "browser.protected_video.prompt.never",
        comment: "Prompt button: keep the site in Chromium and stop asking.",
    )
    static let webKitDialogOK = NSLocalizedString("browser.webkit.dialog.ok", comment: "Accept a page's alert.")
    static let webKitDialogCancel = NSLocalizedString(
        "browser.webkit.dialog.cancel",
        comment: "Dismiss a page's confirmation or prompt.",
    )
    static let webKitDialogTitle = NSLocalizedString(
        "browser.webkit.dialog.title",
        comment: "Title of a page's alert without a host.",
    )
    static let beforeUnloadTitle = NSLocalizedString(
        "browser.before_unload.title",
        comment: "Manual tab close confirmation.",
    )
    static let beforeUnloadMessage = NSLocalizedString(
        "browser.before_unload.message",
        comment: "Unsaved webpage warning.",
    )
    static let beforeUnloadKeepTab = NSLocalizedString("browser.before_unload.keep", comment: "Cancel closing the tab.")
    static let beforeUnloadCloseTab = NSLocalizedString(
        "browser.before_unload.close",
        comment: "Confirm closing the tab.",
    )

    static let archiveTitle = NSLocalizedString(
        "browser.archive.title",
        comment: "Window title.",
    )
    static let archiveMenuTitle = NSLocalizedString(
        "browser.archive.menu",
        comment: "Open the profile Archive.",
    )
    static let archiveViewAction = NSLocalizedString(
        "browser.archive.view",
        comment: "Command Bar action to open the profile Archive.",
    )
    static let archiveSearch = NSLocalizedString(
        "browser.archive.search",
        comment: "Archive search placeholder.",
    )
    static let archiveRestore = NSLocalizedString(
        "browser.archive.restore",
        comment: "Restore an archived tab with a new identity.",
    )
    static let archiveRemove = NSLocalizedString(
        "browser.archive.remove",
        comment: "Remove an archive entry.",
    )
    static let archiveClear = NSLocalizedString(
        "browser.archive.clear",
        comment: "Clear local archive entries.",
    )
    static let archiveClearConfirm = NSLocalizedString(
        "browser.archive.clear_confirm",
        comment: "Confirm clearing the captured archive entries.",
    )
    static let archiveClearMessage = NSLocalizedString(
        "browser.archive.clear_message",
        comment: "Archive clear confirmation scope.",
    )
    static let archiveDestinationTitle = NSLocalizedString(
        "browser.archive.destination_title",
        comment: "Missing original Space recovery title.",
    )
    static let archiveDestinationMessage = NSLocalizedString(
        "browser.archive.destination_message",
        comment: "Explicit archive destination.",
    )
    static let archiveEmpty = NSLocalizedString(
        "browser.archive.empty",
        comment: "Empty archive.",
    )
    static let archiveNoResults = NSLocalizedString(
        "browser.archive.no_results",
        comment: "Empty archive search.",
    )
    static let archiveLoading = NSLocalizedString(
        "browser.archive.loading",
        comment: "Archive loading state.",
    )
    static let archiveNewer = NSLocalizedString(
        "browser.archive.newer",
        comment: "Previous archive page.",
    )
    static let archiveOlder = NSLocalizedString(
        "browser.archive.older",
        comment: "Next archive page.",
    )
    static let archiveColumnTitle = NSLocalizedString(
        "browser.archive.column_title",
        comment: "Archive title column.",
    )
    static let archiveColumnURL = NSLocalizedString(
        "browser.archive.column_url",
        comment: "Archive URL column.",
    )
    static let archiveColumnDate = NSLocalizedString(
        "browser.archive.column_date",
        comment: "Archive date column.",
    )
    static let archiveRestoreFailed = NSLocalizedString(
        "browser.archive.restore_failed",
        comment: "Durable restore failure.",
    )
    static let archiveDestinationMissing = NSLocalizedString(
        "browser.archive.destination_missing",
        comment: "Missing destination.",
    )
    static let archiveEntryMissing = NSLocalizedString(
        "browser.archive.entry_missing",
        comment: "Missing or consumed archive entry.",
    )
    static let archiveActionFailed = NSLocalizedString(
        "browser.archive.action_failed",
        comment: "Archive operation failure.",
    )
    static let archiveUnavailable = NSLocalizedString(
        "browser.archive.unavailable",
        comment: "Archive unavailable state.",
    )
    static let archiveSearchInvalid = NSLocalizedString(
        "browser.archive.search_invalid",
        comment: "Invalid archive query.",
    )

    static let sessionRecoveryTitle = NSLocalizedString(
        "browser.session.recovery.title",
        comment: "Unsaved session banner title.",
    )
    static let sessionRecoveryRetryMessage = NSLocalizedString(
        "browser.session.recovery.retry_message",
        comment: "Temporary persistence failure.",
    )
    static let sessionRecoveryTerminalMessage = NSLocalizedString(
        "browser.session.recovery.terminal_message",
        comment: "Session cannot be retried safely.",
    )
    static let sessionRecoveryRetry = NSLocalizedString(
        "browser.session.recovery.retry",
        comment: "Retry saving the session.",
    )
    static let sessionRecoverySaveCopy = NSLocalizedString(
        "browser.session.recovery.save_copy",
        comment: "Export the unsaved session.",
    )
    static let sessionRecoveryExportFailed = NSLocalizedString(
        "browser.session.recovery.export_failed",
        comment: "Session export error title.",
    )
    static let sessionRecoveryCloseTitle = NSLocalizedString(
        "browser.session.recovery.close_title",
        comment: "Confirm loss of unsaved session changes.",
    )
    static let sessionRecoveryCloseMessage = NSLocalizedString(
        "browser.session.recovery.close_message",
        comment: "Cancel to export a session copy.",
    )
    static let sessionRecoveryCloseWithoutSaving = NSLocalizedString(
        "browser.session.recovery.close_without_saving",
        comment: "Explicitly discard unsaved changes.",
    )
    static let sessionRecoveryCloseProfileBeforeDeleting = NSLocalizedString(
        "browser.session.recovery.close_profile_before_deleting",
        comment: "Open profiles cannot be deleted.",
    )
    static let applicationName = NSLocalizedString(
        "browser.app.name",
        comment: "The localized application name.",
    )

    static let newTabTitle = NSLocalizedString(
        "browser.tab.new",
        comment: "Fallback title for a new tab without page metadata.",
    )

    static let sidebarNewTab = NSLocalizedString(
        "browser.sidebar.new_tab",
        comment: "Sidebar button title for creating a new tab.",
    )

    static let spaceRenameAction = NSLocalizedString(
        "browser.space.rename_action",
        comment: "Context menu title for renaming a space.",
    )

    static let spaceChangeIconAction = NSLocalizedString(
        "browser.space.change_icon_action",
        comment: "Context menu title for changing a space icon.",
    )

    static let spaceNewAction = NSLocalizedString(
        "browser.space.new_action",
        comment: "Tooltip title for creating a new space.",
    )

    static let spaceDeleteAction = NSLocalizedString(
        "browser.space.delete_action",
        comment: "Context menu title for deleting a space.",
    )

    static let pinnedTabFolderDefaultTitle = NSLocalizedString(
        "browser.pinned_tab_folder.default_title",
        comment: "Default title for a pinned tab folder.",
    )

    static let pinnedTabFolderNewAction = NSLocalizedString(
        "browser.pinned_tab_folder.new_action",
        comment: "Context menu title for creating a pinned tab folder from a pinned tab or selected pinned tabs.",
    )

    static let pinnedTabFolderRenameAction = NSLocalizedString(
        "browser.pinned_tab_folder.rename_action",
        comment: "Context menu title for renaming a pinned tab folder.",
    )

    static let pinnedTabFolderChangeIconAction = NSLocalizedString(
        "browser.pinned_tab_folder.change_icon_action",
        comment: "Context menu title for changing a pinned tab folder icon.",
    )

    static let pinnedTabFolderNoIconAction = NSLocalizedString(
        "browser.pinned_tab_folder.no_icon_action",
        comment: "Menu title for removing a pinned tab folder icon.",
    )

    static let pinnedTabFolderDeleteAction = NSLocalizedString(
        "browser.pinned_tab_folder.delete_action",
        comment: "Context menu action deleting a pinned folder and its current contents.",
    )

    static let pinnedTabSeparate = NSLocalizedString(
        "browser.pinned_tab.separate",
        comment: "Secondary sidebar label on a pinned tab's favicon while Command is held: a click moves the page to its own tab.",
    )

    static let pinnedTabBackToPinnedURL = NSLocalizedString(
        "browser.pinned_tab.back_to_pinned_url",
        comment: "Secondary sidebar label shown while hovering the pinned-tab favicon reset button.",
    )

    static let pinnedTabReplaceURLWithCurrentAction = NSLocalizedString(
        "browser.pinned_tab.replace_url_with_current_action",
        comment: "Context menu title for replacing a pinned tab URL with the current page URL.",
    )

    static let pinnedTabEditURLAction = NSLocalizedString(
        "browser.pinned_tab.edit_url_action",
        comment: "Context menu title for editing a pinned tab URL.",
    )

    static let pinnedTabEditURLPromptTitle = NSLocalizedString(
        "browser.pinned_tab.edit_url_prompt.title",
        comment: "Prompt title for editing a pinned tab URL.",
    )

    static let sidebarHide = NSLocalizedString(
        "browser.sidebar.hide",
        comment: "Tooltip for hiding the sidebar.",
    )

    static let sidebarShow = NSLocalizedString(
        "browser.sidebar.show",
        comment: "Tooltip for showing the sidebar.",
    )

    static let navigationBack = NSLocalizedString(
        "browser.navigation.back",
        comment: "Title for back navigation actions.",
    )

    static let navigationForward = NSLocalizedString(
        "browser.navigation.forward",
        comment: "Title for forward navigation actions.",
    )

    static let navigationRefresh = NSLocalizedString(
        "browser.navigation.refresh",
        comment: "Title for refresh actions.",
    )

    static let navigationStopLoading = NSLocalizedString(
        "browser.navigation.stop_loading",
        comment: "Title for stop loading actions.",
    )

    static let loadingLaunchingBrowser = NSLocalizedString(
        "browser.loading.launching",
        comment: "Loading message shown while the browser initializes.",
    )

    static let loadingOpeningTab = NSLocalizedString(
        "browser.loading.opening_tab",
        comment: "Loading message shown while a tab opens.",
    )

    static let tabCreationFailedTitle = NSLocalizedString(
        "browser.tab.creation_failed.title",
        comment: "Title shown when a tab could not open.",
    )

    static let tabCreationFailedMessage = NSLocalizedString(
        "browser.tab.creation_failed.message",
        comment: "Recovery instruction shown when a tab could not open.",
    )

    static let tabCreationRetry = NSLocalizedString(
        "browser.tab.creation_failed.retry",
        comment: "Button that retries opening the selected tab.",
    )

    static let commandBarClose = NSLocalizedString(
        "browser.command_bar.close",
        comment: "Button beside the small window bar's field that closes the bar.",
    )
    static let commandBarPlaceholder = NSLocalizedString(
        "browser.command_bar.placeholder",
        comment: "Placeholder shown in the command bar search field.",
    )

    static let sitePermissionCamera = NSLocalizedString(
        "browser.site_permission.camera",
        comment: "Site permission prompt line: the page wants the camera.",
    )

    static let sitePermissionMicrophone = NSLocalizedString(
        "browser.site_permission.microphone",
        comment: "Site permission prompt line: the page wants the microphone.",
    )

    static let sitePermissionLocation = NSLocalizedString(
        "browser.site_permission.location",
        comment: "Site permission prompt line: the page wants the location.",
    )

    static let sitePermissionNotifications = NSLocalizedString(
        "browser.site_permission.notifications",
        comment: "Site permission prompt line: the page wants to show notifications.",
    )

    static let sitePermissionClipboard = NSLocalizedString(
        "browser.site_permission.clipboard",
        comment: "Site permission prompt line: the page wants to read the clipboard.",
    )

    static let sitePermissionMIDI = NSLocalizedString(
        "browser.site_permission.midi",
        comment: "Site permission prompt line: the page wants full MIDI access.",
    )

    static let sitePermissionWindowManagement = NSLocalizedString(
        "browser.site_permission.window_management",
        comment: "Site permission prompt line: the page wants to place windows.",
    )

    static let sitePermissionLocalFonts = NSLocalizedString(
        "browser.site_permission.local_fonts",
        comment: "Site permission prompt line: the page wants the installed fonts.",
    )

    static let sitePermissionIdleDetection = NSLocalizedString(
        "browser.site_permission.idle_detection",
        comment: "Site permission prompt line: the page wants idle detection.",
    )

    static let sitePermissionStorageAccess = NSLocalizedString(
        "browser.site_permission.storage_access",
        comment: "Site permission prompt line: embedded content wants its cookies.",
    )

    static let sitePermissionMultipleDownloads = NSLocalizedString(
        "browser.site_permission.multiple_downloads",
        comment: "Site permission prompt line: the page wants to download more than one file.",
    )

    static let sitePermissionOther = NSLocalizedString(
        "browser.site_permission.other",
        comment: "Site permission prompt line for a request without its own name.",
    )

    static let sitePermissionAllow = NSLocalizedString(
        "browser.site_permission.allow",
        comment: "Button that grants a site permission request.",
    )

    static let sitePermissionBlock = NSLocalizedString(
        "browser.site_permission.block",
        comment: "Button that refuses a site permission request.",
    )

    static let sitePermissionDismiss = NSLocalizedString(
        "browser.site_permission.dismiss",
        comment: "Accessibility label of the button that closes a site permission prompt without an answer.",
    )

    static let settingsSitePermissionsTitle = NSLocalizedString(
        "browser.settings.site_permissions",
        comment: "Settings section of sites with a remembered camera or microphone answer.",
    )

    static let settingsSitePermissionsDetail = NSLocalizedString(
        "browser.settings.site_permissions.detail",
        comment: "Settings detail of the remembered camera and microphone answers.",
    )

    static let settingsSitePermissionsEmpty = NSLocalizedString(
        "browser.settings.site_permissions.empty",
        comment: "Settings text when no site has a remembered camera or microphone answer.",
    )

    static let settingsSitePermissionsForget = NSLocalizedString(
        "browser.settings.site_permissions.forget",
        comment: "Button that forgets a site's camera and microphone answers.",
    )

    static let sitePermissionAllowedState = NSLocalizedString(
        "browser.settings.site_permissions.allowed",
        comment: "A remembered site permission answer: allowed.",
    )

    static let sitePermissionBlockedState = NSLocalizedString(
        "browser.settings.site_permissions.blocked",
        comment: "A remembered site permission answer: blocked.",
    )

    static let siteSettingCamera = NSLocalizedString(
        "browser.site_setting.camera",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingMicrophone = NSLocalizedString(
        "browser.site_setting.microphone",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingLocation = NSLocalizedString(
        "browser.site_setting.location",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingNotifications = NSLocalizedString(
        "browser.site_setting.notifications",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingClipboard = NSLocalizedString(
        "browser.site_setting.clipboard",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingPopups = NSLocalizedString(
        "browser.site_setting.popups",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingSound = NSLocalizedString(
        "browser.site_setting.sound",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingAutomaticDownloads = NSLocalizedString(
        "browser.site_setting.automatic_downloads",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingMIDI = NSLocalizedString(
        "browser.site_setting.midi",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingWindowManagement = NSLocalizedString(
        "browser.site_setting.window_management",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingLocalFonts = NSLocalizedString(
        "browser.site_setting.local_fonts",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingIdleDetection = NSLocalizedString(
        "browser.site_setting.idle_detection",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingAutoPictureInPicture = NSLocalizedString(
        "browser.site_setting.auto_picture_in_picture",
        comment: "Site setting row title in the site control center.",
    )

    static let siteSettingAskState = NSLocalizedString(
        "browser.site_setting.ask",
        comment: "A site setting that asks the user each time.",
    )

    static let siteSettingAskAction = NSLocalizedString(
        "browser.site_setting.ask_action",
        comment: "Site setting menu item that makes the site ask again.",
    )

    static let siteControlSettingsSection = NSLocalizedString(
        "browser.site_control.settings",
        comment: "Section of the site control center listing the site's settings.",
    )

    static let siteControlSecure = NSLocalizedString(
        "browser.site_control.secure",
        comment: "Site control center label for a page loaded over HTTPS.",
    )

    static let siteControlNotSecure = NSLocalizedString(
        "browser.site_control.not_secure",
        comment: "Site control center label for a page loaded without HTTPS.",
    )

    static let siteControlShare = NSLocalizedString(
        "browser.site_control.share",
        comment: "Site control center button that shares the page.",
    )

    static let siteControlCapture = NSLocalizedString(
        "browser.site_control.capture",
        comment: "Site control center button that captures part of the page.",
    )

    static let siteControlMore = NSLocalizedString(
        "browser.site_control.more",
        comment: "Accessibility label of the site control center's menu button.",
    )

    static let siteControlClearCache = NSLocalizedString(
        "browser.site_control.clear_cache",
        comment: "Site control center menu item that clears the cache and reloads.",
    )

    static let newDocumentGoogleDoc = NSLocalizedString(
        "browser.new_document.google_doc",
        comment: "Command bar entry that opens a new Google Doc.",
    )

    static let newDocumentGoogleSheet = NSLocalizedString(
        "browser.new_document.google_sheet",
        comment: "Command bar entry that opens a new Google Sheet.",
    )

    static let newDocumentGoogleSlides = NSLocalizedString(
        "browser.new_document.google_slides",
        comment: "Command bar entry that opens new Google Slides.",
    )

    static let newDocumentWord = NSLocalizedString(
        "browser.new_document.word",
        comment: "Command bar entry that opens a new Word document.",
    )

    static let newDocumentNotion = NSLocalizedString(
        "browser.new_document.notion",
        comment: "Command bar entry that opens a new Notion page.",
    )

    static let newDocumentFigma = NSLocalizedString(
        "browser.new_document.figma",
        comment: "Command bar entry that opens a new Figma file.",
    )

    static let newDocumentFigJam = NSLocalizedString(
        "browser.new_document.figjam",
        comment: "Command bar entry that opens a new FigJam board.",
    )

    static let newDocumentMeeting = NSLocalizedString(
        "browser.new_document.meeting",
        comment: "Command bar entry that starts a new Google Meet.",
    )

    static let newDocumentsAppGoogleDocs = NSLocalizedString(
        "browser.new_documents_app.google_docs",
        comment: "Settings option: new documents open in Google Docs.",
    )

    static let newDocumentsAppWord = NSLocalizedString(
        "browser.new_documents_app.word",
        comment: "Settings option: new documents open in Word.",
    )

    static let newDocumentsAppNotion = NSLocalizedString(
        "browser.new_documents_app.notion",
        comment: "Settings option: new documents open in Notion.",
    )

    static let settingsNewDocumentsTitle = NSLocalizedString(
        "browser.settings.new_documents.title",
        comment: "Settings section about new documents.",
    )

    static let settingsNewDocumentsApp = NSLocalizedString(
        "browser.settings.new_documents.app",
        comment: "Settings picker for the app new documents open in.",
    )

    static let settingsSmallWindowLifetime = NSLocalizedString(
        "browser.settings.small_window.lifetime",
        comment: "Settings picker for how long an unused small window stays open.",
    )

    static let settingsSmallWindowLifetimeOneHour = NSLocalizedString(
        "browser.settings.small_window.lifetime.one_hour",
        comment: "Option: unused small windows close after one hour.",
    )

    static let settingsSmallWindowLifetimeTwelveHours = NSLocalizedString(
        "browser.settings.small_window.lifetime.twelve_hours",
        comment: "Option: unused small windows close after twelve hours.",
    )

    static let settingsSmallWindowLifetimeOneDay = NSLocalizedString(
        "browser.settings.small_window.lifetime.one_day",
        comment: "Option: unused small windows close after a day.",
    )

    static let settingsSmallWindowLifetimeNever = NSLocalizedString(
        "browser.settings.small_window.lifetime.never",
        comment: "Option: unused small windows stay open.",
    )

    static let siteControlClearCookies = NSLocalizedString(
        "browser.site_control.clear_cookies",
        comment: "Site control center menu item that clears cookies and reloads.",
    )

    static let siteControlAllSiteSettings = NSLocalizedString(
        "browser.site_control.all_site_settings",
        comment: "Site control center menu item that opens every setting of the site.",
    )

    static let commandBarSiteSearchPlaceholder = NSLocalizedString(
        "browser.command_bar.site_search.placeholder",
        comment: "Placeholder of the command bar field while it searches one site.",
    )

    static let settingsSiteSearchTitle = NSLocalizedString(
        "browser.settings.site_search",
        comment: "Settings section of sites the command bar can search with Tab.",
    )

    static let settingsSiteSearchDetail = NSLocalizedString(
        "browser.settings.site_search.detail",
        comment: "Settings detail explaining site search shortcuts in the command bar.",
    )

    static let settingsSiteSearchName = NSLocalizedString(
        "browser.settings.site_search.name",
        comment: "Placeholder of a site search's name field.",
    )

    static let settingsSiteSearchKeyword = NSLocalizedString(
        "browser.settings.site_search.keyword",
        comment: "Placeholder of a site search's shortcut field.",
    )

    static let settingsSiteSearchURL = NSLocalizedString(
        "browser.settings.site_search.url",
        comment: "Placeholder of a site search's address field; %s stands for the query.",
    )

    static let settingsSiteSearchAdd = NSLocalizedString(
        "browser.settings.site_search.add",
        comment: "Button that adds a site search.",
    )

    static let settingsSiteSearchRemove = NSLocalizedString(
        "browser.settings.site_search.remove",
        comment: "Accessibility label of the button that removes a site search.",
    )

    static let settingsSiteSearchRestoreDefaults = NSLocalizedString(
        "browser.settings.site_search.restore_defaults",
        comment: "Button that adds back the built-in site searches that were removed.",
    )

    static let settingsSiteSearchImport = NSLocalizedString(
        "browser.settings.site_search.import",
        comment: "Menu button that imports site searches from another browser.",
    )

    static let settingsSiteSearchImportNothing = NSLocalizedString(
        "browser.settings.site_search.import.nothing",
        comment: "Alert after a site search import that found no site searches.",
    )

    static let settingsSiteSearchImportMissing = NSLocalizedString(
        "browser.settings.site_search.import.missing",
        comment: "Alert when the browser to import site searches from has no profile on this Mac.",
    )

    static let bookmarksAddCurrentPage = NSLocalizedString(
        "browser.bookmarks.add_current_page",
        comment: "Tooltip for adding the selected page to bookmarks.",
    )

    static let bookmarksRemoveCurrentPage = NSLocalizedString(
        "browser.bookmarks.remove_current_page",
        comment: "Tooltip for removing the selected page from bookmarks.",
    )

    static let bookmarksEditAction = NSLocalizedString(
        "browser.bookmarks.edit_action",
        comment: "Context menu title that edits a bookmark's name, address and folder.",
    )

    static let bookmarksEditTitle = NSLocalizedString(
        "browser.bookmarks.edit_title",
        comment: "Title of the window that edits a bookmark.",
    )

    static let bookmarksRenameFolderTitle = NSLocalizedString(
        "browser.bookmarks.rename_folder_title",
        comment: "Title of the window that edits a bookmark folder.",
    )

    static let bookmarksAddPageAction = NSLocalizedString(
        "browser.bookmarks.add_page_action",
        comment: "Context menu title that adds a bookmark at this place.",
    )

    static let bookmarksAddPageTitle = NSLocalizedString(
        "browser.bookmarks.add_page_title",
        comment: "Title of the window that adds a bookmark.",
    )

    static let bookmarksAddFolderAction = NSLocalizedString(
        "browser.bookmarks.add_folder_action",
        comment: "Context menu title that adds a bookmark folder at this place.",
    )

    static let bookmarksNameField = NSLocalizedString(
        "browser.bookmarks.name_field",
        comment: "Label of the bookmark name field.",
    )

    static let bookmarksURLField = NSLocalizedString(
        "browser.bookmarks.url_field",
        comment: "Label of the bookmark address field.",
    )

    static let bookmarksFolderField = NSLocalizedString(
        "browser.bookmarks.folder_field",
        comment: "Label of the folder chooser when editing a bookmark.",
    )

    static let bookmarksOpenInNewTab = NSLocalizedString(
        "browser.bookmarks.open_new_tab",
        comment: "Context menu title that opens a bookmark in a new tab.",
    )

    static let bookmarksOpenInLittleWindow = NSLocalizedString(
        "browser.bookmarks.open_little_window",
        comment: "Context menu title that opens a bookmark in a small window.",
    )

    static let bookmarksOpenInSplitView = NSLocalizedString(
        "browser.bookmarks.open_split_view",
        comment: "Context menu title that opens a bookmark in Split View.",
    )

    static let bookmarksOpenInIncognito = NSLocalizedString(
        "browser.bookmarks.open_incognito",
        comment: "Context menu title that opens a bookmark in an incognito window.",
    )

    static let bookmarksCut = NSLocalizedString(
        "browser.bookmarks.cut",
        comment: "Context menu title that cuts a bookmark.",
    )

    static let bookmarksCopy = NSLocalizedString(
        "browser.bookmarks.copy",
        comment: "Context menu title that copies a bookmark.",
    )

    static let bookmarksPaste = NSLocalizedString(
        "browser.bookmarks.paste",
        comment: "Context menu title that pastes a bookmark.",
    )

    static let bookmarksSave = NSLocalizedString("browser.bookmarks.save", comment: "Button that saves a bookmark.")

    static let bookmarksCancel = NSLocalizedString(
        "browser.bookmarks.cancel",
        comment: "Button that closes the bookmark editor without saving.",
    )

    static let bookmarksEmptyFolder = NSLocalizedString(
        "browser.bookmarks.empty_folder",
        comment: "Shown in a bookmark folder with nothing in it.",
    )

    static let bookmarksMoreItems = NSLocalizedString(
        "browser.bookmarks.more_items",
        comment: "Tooltip of the button listing bookmarks that do not fit in the bar.",
    )

    static let bookmarksRenameAction = NSLocalizedString(
        "browser.bookmarks.rename_action",
        comment: "Context menu title for renaming a bookmark.",
    )

    static let bookmarksEditAddressAction = NSLocalizedString(
        "browser.bookmarks.edit_address_action",
        comment: "Context menu title for editing a bookmark address.",
    )

    static let bookmarksMoveToAction = NSLocalizedString(
        "browser.bookmarks.move_to_action",
        comment: "Context menu title for moving a bookmark.",
    )

    static let bookmarksBarDestination = NSLocalizedString(
        "browser.bookmarks.bar_destination",
        comment: "Bookmark move destination title for the bookmarks bar root.",
    )

    static let bookmarksNewFolderAction = NSLocalizedString(
        "browser.bookmarks.new_folder_action",
        comment: "Context menu title for creating a bookmark folder.",
    )

    static let bookmarksDeleteAction = NSLocalizedString(
        "browser.bookmarks.delete_action",
        comment: "Context menu title for deleting a bookmark.",
    )

    static let bookmarksManageAction = NSLocalizedString(
        "browser.bookmarks.manage_action",
        comment: "Context menu title for opening bookmark management.",
    )

    static let bookmarksRenamePromptTitle = NSLocalizedString(
        "browser.bookmarks.rename_prompt.title",
        comment: "Prompt title for renaming a bookmark.",
    )

    static let bookmarksEditAddressPromptTitle = NSLocalizedString(
        "browser.bookmarks.edit_address_prompt.title",
        comment: "Prompt title for editing a bookmark URL.",
    )

    static let bookmarksNewFolderPromptTitle = NSLocalizedString(
        "browser.bookmarks.new_folder_prompt.title",
        comment: "Prompt title for creating a bookmark folder.",
    )

    static let bookmarksImport = NSLocalizedString(
        "browser.bookmarks.import",
        comment: "Menu title for importing bookmarks.",
    )

    static let bookmarksUntitledFolder = NSLocalizedString(
        "browser.bookmarks.untitled_folder",
        comment: "Fallback title for an untitled bookmarks folder.",
    )

    static let bookmarksHideBarAction = NSLocalizedString(
        "browser.bookmarks.hide_bar_action",
        comment: "Context menu title for hiding the bookmarks bar.",
    )

    static let downloadsTitle = NSLocalizedString(
        "browser.downloads.title",
        comment: "Title and tooltip for the downloads manager.",
    )

    static let downloadsEmpty = NSLocalizedString(
        "browser.downloads.empty",
        comment: "Message shown when there are no downloads.",
    )

    static let downloadsClearFinished = NSLocalizedString(
        "browser.downloads.clear_finished",
        comment: "Button title for clearing finished downloads.",
    )

    static let downloadsOpen = NSLocalizedString(
        "browser.downloads.open",
        comment: "Button title for opening a downloaded file.",
    )

    static let downloadsReveal = NSLocalizedString(
        "browser.downloads.reveal",
        comment: "Button title for revealing a downloaded file in Finder.",
    )

    static let downloadsDefaultFileName = NSLocalizedString(
        "browser.downloads.default_file_name",
        comment: "Fallback file name for downloads without a suggested name.",
    )

    static let downloadsStatusInProgress = NSLocalizedString(
        "browser.downloads.status.in_progress",
        comment: "Status text for a download that is still running.",
    )

    static let downloadsStatusCompleted = NSLocalizedString(
        "browser.downloads.status.completed",
        comment: "Status text for a completed download.",
    )

    static let downloadsStatusCanceled = NSLocalizedString(
        "browser.downloads.status.canceled",
        comment: "Status text for a canceled download.",
    )

    static let downloadsStatusInterrupted = NSLocalizedString(
        "browser.downloads.status.interrupted",
        comment: "Status text for an interrupted download.",
    )

    static let downloadsCompletedDetail = NSLocalizedString(
        "browser.downloads.detail.completed",
        comment: "Detail text for a completed download.",
    )

    static let downloadsCancelAction = NSLocalizedString(
        "browser.downloads.cancel",
        comment: "Button or menu item that stops a running download.",
    )
    static let downloadsCanceledDetail = NSLocalizedString(
        "browser.downloads.detail.canceled",
        comment: "Detail text for a canceled download.",
    )

    static let downloadsInterruptedDetail = NSLocalizedString(
        "browser.downloads.detail.interrupted",
        comment: "Detail text for an interrupted download.",
    )

    static let downloadsTrayFailed = NSLocalizedString(
        "browser.downloads.tray_failed",
        comment: "Tray row detail for a download that stopped with an error.",
    )

    static let downloadsCopyImage = NSLocalizedString(
        "browser.downloads.copy_image",
        comment: "Menu item that copies a downloaded picture.",
    )

    static let downloadsCopyFile = NSLocalizedString(
        "browser.downloads.copy_file",
        comment: "Menu item that copies a downloaded file.",
    )

    static let downloadsOpenImage = NSLocalizedString(
        "browser.downloads.open_image",
        comment: "Menu item that opens a downloaded picture.",
    )

    static let downloadsRemoveFromList = NSLocalizedString(
        "browser.downloads.remove_from_list",
        comment: "Menu item that drops a download from the list and keeps the file.",
    )

    static let downloadsMoveToTrash = NSLocalizedString(
        "browser.downloads.move_to_trash",
        comment: "Menu item that moves a downloaded file to the Trash.",
    )

    static let downloadsMoreActions = NSLocalizedString(
        "browser.downloads.more_actions",
        comment: "Tooltip and accessibility label of the button that opens a download's menu.",
    )

    /// "Open in Preview": the app that opens the file by default.
    static func downloadsOpenIn(_ application: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.downloads.open_in_app",
                comment: "Menu item that opens a downloaded file. %@ is the app's name.",
            ),
            application,
        )
    }

    static let findBarPlaceholder = NSLocalizedString(
        "browser.find_bar.placeholder",
        comment: "Placeholder shown in the page find field.",
    )

    static let findBarNotFound = NSLocalizedString(
        "browser.find_bar.not_found",
        comment: "Shown in capitals in the find bar when the page has no match.",
    )

    static let findBarPreviousMatch = NSLocalizedString(
        "browser.find_bar.previous_match",
        comment: "Tooltip for moving to the previous in-page search match.",
    )

    static let findBarNextMatch = NSLocalizedString(
        "browser.find_bar.next_match",
        comment: "Tooltip for moving to the next in-page search match.",
    )

    static let findBarClose = NSLocalizedString(
        "browser.find_bar.close",
        comment: "Tooltip for closing the page find bar.",
    )

    static let menuFile = NSLocalizedString(
        "browser.menu.file",
        comment: "File menu title.",
    )

    static let menuEdit = NSLocalizedString(
        "browser.menu.edit",
        comment: "Edit menu title.",
    )

    static let menuView = NSLocalizedString(
        "browser.menu.view",
        comment: "View menu title.",
    )

    static let menuFindTitle = NSLocalizedString(
        "browser.menu.find.title",
        comment: "Find submenu title.",
    )

    static let menuSettings = NSLocalizedString(
        "browser.menu.settings",
        comment: "Settings menu item title.",
    )

    static let menuCheckForUpdates = NSLocalizedString(
        "browser.menu.check_for_updates",
        comment: "Check for Updates menu item title.",
    )

    static let menuSetAsDefaultBrowser = NSLocalizedString(
        "browser.menu.set_as_default_browser",
        comment: "Set as Default Browser menu item title.",
    )

    static let aboutUnknownVersion = NSLocalizedString(
        "browser.about.unknown_version",
        comment: "Fallback version text when a bundle version is unavailable.",
    )

    static let aboutCopyright = NSLocalizedString(
        "browser.about.copyright",
        comment: "Copyright text shown in the About window.",
    )

    static let aboutMadePossiblePrefix = NSLocalizedString(
        "browser.about.made_possible.prefix",
        comment: "Opening text before the Chromium project link in the About window credits paragraph.",
    )

    static let aboutChromiumProjectLinkTitle = NSLocalizedString(
        "browser.about.chromium_project_link",
        comment: "Linked Chromium project name in the About window credits paragraph.",
    )

    static let aboutMadePossibleChromiumProjectSuffix = NSLocalizedString(
        "browser.about.made_possible.chromium_project_suffix",
        comment: "Text after the Chromium project link and before Chromium credits link in the About window.",
    )

    static let aboutOpenSourceSoftwareLinkTitle = NSLocalizedString(
        "browser.about.open_source_software_link",
        comment: "Linked open source software phrase in the About window credits paragraph.",
    )

    static let aboutMadePossibleOtherPrefix = NSLocalizedString(
        "browser.about.made_possible.other_prefix",
        comment: "Text between the Chromium credits link and OpenArc credits link in the About window.",
    )

    static let aboutMadePossibleSuffix = NSLocalizedString(
        "browser.about.made_possible.suffix",
        comment: "Closing punctuation for the About window credits paragraph.",
    )

    static let undoMoveAction = NSLocalizedString(
        "browser.undo.move_action",
        comment: "Undo menu action name for moving sidebar rows or Spaces.",
    )
    static let undoCopyAction = NSLocalizedString(
        "browser.undo.copy_action",
        comment: "Undo menu action name for copying sidebar rows with an Option-drag.",
    )
    static let undoRenameAction = NSLocalizedString(
        "browser.undo.rename_action",
        comment: "Undo menu action name for renaming a tab, folder, Space or Split View.",
    )
    static let menuUndo = NSLocalizedString(
        "browser.menu.undo",
        comment: "Undo menu item title.",
    )

    static let menuRedo = NSLocalizedString(
        "browser.menu.redo",
        comment: "Redo menu item title.",
    )

    static let menuCut = NSLocalizedString(
        "browser.menu.cut",
        comment: "Cut menu item title.",
    )

    static let menuCopy = NSLocalizedString(
        "browser.menu.copy",
        comment: "Copy menu item title.",
    )

    static let menuPaste = NSLocalizedString(
        "browser.menu.paste",
        comment: "Paste menu item title.",
    )

    static let menuPasteAndMatchStyle = NSLocalizedString(
        "browser.menu.paste_and_match_style",
        comment: "Paste and Match Style menu item title.",
    )

    static let menuSelectAll = NSLocalizedString(
        "browser.menu.select_all",
        comment: "Select All menu item title.",
    )

    static let menuFind = NSLocalizedString(
        "browser.menu.find",
        comment: "Find menu item title.",
    )

    static let menuFindAndReplace = NSLocalizedString(
        "browser.menu.find_and_replace",
        comment: "Find and Replace menu item title.",
    )

    static let menuFindNext = NSLocalizedString(
        "browser.menu.find_next",
        comment: "Find Next menu item title.",
    )

    static let menuFindPrevious = NSLocalizedString(
        "browser.menu.find_previous",
        comment: "Find Previous menu item title.",
    )

    static let menuUseSelectionToFind = NSLocalizedString(
        "browser.menu.use_selection_to_find",
        comment: "Use Selection to Find menu item title.",
    )

    static let menuJumpToSelection = NSLocalizedString(
        "browser.menu.jump_to_selection",
        comment: "Jump to Selection menu item title.",
    )

    static let menuNewTab = NSLocalizedString(
        "browser.menu.new_tab",
        comment: "New Tab menu item title.",
    )

    static let menuNewWindow = NSLocalizedString(
        "browser.menu.new_window",
        comment: "Menu command that opens another window with the same Spaces.",
    )

    static let menuNewIncognitoWindow = NSLocalizedString(
        "browser.menu.new_incognito_window",
        comment: "New Incognito Window menu item title.",
    )

    static let menuNewLittleWindow = NSLocalizedString(
        "browser.menu.new_little_window",
        comment: "File menu item and command that opens a small window of its own.",
    )

    static let peekOpenInPrefix = NSLocalizedString(
        "browser.peek.open_in_prefix",
        comment: "Start of the small window's button, followed by the Space's name: \"Open in Work\". Keep the trailing space.",
    )

    static let peekOpenInMenuTitle = NSLocalizedString(
        "browser.peek.open_in",
        comment: "Header of the menu that moves a Peek card or small window into a Space as a tab.",
    )

    static let peekAddressPlaceholder = NSLocalizedString(
        "browser.peek.address_placeholder",
        comment: "Placeholder of the small window's address field.",
    )

    static let incognitoBannerTitle = NSLocalizedString(
        "browser.incognito.banner.title",
        comment: "Banner title shown above web content in incognito windows.",
    )

    static let incognitoTabsTitle = NSLocalizedString(
        "browser.incognito.tabs.title",
        comment: "Sidebar label shown above the new tab button in incognito windows.",
    )

    static let menuHistory = NSLocalizedString(
        "browser.menu.history",
        comment: "History menu item title.",
    )

    static let menuSavePageAs = NSLocalizedString(
        "browser.menu.save_page_as",
        comment: "Save Page As menu item title.",
    )

    static let menuPrint = NSLocalizedString(
        "browser.menu.print",
        comment: "Print menu item title.",
    )

    static let menuForceRefresh = NSLocalizedString(
        "browser.menu.force_refresh",
        comment: "Force Refresh menu item title.",
    )

    static let menuClearCacheAndRefresh = NSLocalizedString(
        "browser.menu.clear_cache_and_refresh",
        comment: "Clear Cache and Refresh menu item title.",
    )

    static let menuClearCookiesAndRefresh = NSLocalizedString(
        "browser.menu.clear_cookies_and_refresh",
        comment: "Clear Cookies and Refresh menu item title.",
    )

    static let menuAddSplitView = NSLocalizedString(
        "browser.menu.add_split_view",
        comment: "Add Split View menu item title.",
    )

    static let menuCloseSplitPane = NSLocalizedString(
        "browser.menu.close_split_pane",
        comment: "Close this Split Pane menu item title.",
    )

    static let menuSeparatePageFromSplitView = NSLocalizedString(
        "browser.menu.separate_page_from_split_view",
        comment: "Separate Page from Split View menu item title.",
    )

    static let menuToggleSplitOrientation = NSLocalizedString(
        "browser.menu.toggle_split_orientation",
        comment: "Settings and command title for switching a split between side by side and stacked panes.",
    )

    static let menuFocusNextSplitPane = NSLocalizedString(
        "browser.menu.focus_next_split_pane",
        comment: "Command title that focuses the next Split View pane.",
    )

    static let menuFocusPreviousSplitPane = NSLocalizedString(
        "browser.menu.focus_previous_split_pane",
        comment: "Command title that focuses the previous Split View pane.",
    )

    static let splitMovePaneLeft = NSLocalizedString(
        "browser.split.move_left",
        comment: "Split View Menu action that moves the focused pane one place to the left.",
    )

    static let splitMovePaneRight = NSLocalizedString(
        "browser.split.move_right",
        comment: "Split View Menu action that moves the focused pane one place to the right.",
    )

    static let splitMovePaneUp = NSLocalizedString(
        "browser.split.move_up",
        comment: "Split View Menu action that moves the focused pane of a stacked split up.",
    )

    static let splitMovePaneDown = NSLocalizedString(
        "browser.split.move_down",
        comment: "Split View Menu action that moves the focused pane of a stacked split down.",
    )

    static let splitAddLeft = NSLocalizedString(
        "browser.split.add_left",
        comment: "Split View Menu action that adds a pane left of the focused pane.",
    )

    static let splitAddRight = NSLocalizedString(
        "browser.split.add_right",
        comment: "Split View Menu action that adds a pane right of the focused pane.",
    )

    static let splitAddTop = NSLocalizedString(
        "browser.split.add_top",
        comment: "Split View Menu action that adds a pane above the focused pane of a stacked split.",
    )

    static let splitAddBottom = NSLocalizedString(
        "browser.split.add_bottom",
        comment: "Split View Menu action that adds a pane below the focused pane of a stacked split.",
    )

    static let menuExpandCurrentSplit = NSLocalizedString(
        "browser.menu.expand_current_split",
        comment: "View menu and command title that shows only the focused Split View pane.",
    )

    static let menuShowAllSplitPanes = NSLocalizedString(
        "browser.menu.show_all_split_panes",
        comment: "View menu and command title that restores every pane after Expand Current Split.",
    )

    static let settingsSidebarPosition = NSLocalizedString(
        "browser.settings.sidebar_position",
        comment: "Settings title for the window edge that shows the sidebar.",
    )

    static let settingsSidebarPositionLeft = NSLocalizedString(
        "browser.settings.sidebar_position.left",
        comment: "Sidebar position option: the left window edge.",
    )

    static let settingsSidebarPositionRight = NSLocalizedString(
        "browser.settings.sidebar_position.right",
        comment: "Sidebar position option: the right window edge.",
    )

    static let menuMoveSidebarRight = NSLocalizedString(
        "browser.menu.move_sidebar_right",
        comment: "View menu and command title that moves the sidebar to the right window edge.",
    )

    static let settingsAgentAccess = NSLocalizedString(
        "browser.settings.agent_access",
        comment: "Settings toggle that lets local programs and AI agents control the browser.",
    )

    static let settingsAgentAccessDetail = NSLocalizedString(
        "browser.settings.agent_access_detail",
        comment: "Explains agent access in Settings.",
    )

    static let agentSignInDetail = NSLocalizedString(
        "browser.agent.signin_detail",
        comment: "Explains that the agent never sees the password.",
    )

    static let agentSignInAllow = NSLocalizedString(
        "browser.agent.signin_allow",
        comment: "Button allowing an agent's sign-in.",
    )

    static let agentSignInDeny = NSLocalizedString(
        "browser.agent.signin_deny",
        comment: "Button refusing an agent's sign-in.",
    )

    static let commandBarSwitchToTab = NSLocalizedString(
        "browser.command_bar.switch_to_tab",
        comment: "Trailing label on a command bar row for an open tab.",
    )

    static let onboardingWelcomeTitle = NSLocalizedString(
        "browser.onboarding.welcome_title",
        comment: "First-run welcome window.",
    )

    static let onboardingWelcomeSubtitle = NSLocalizedString(
        "browser.onboarding.welcome_subtitle",
        comment: "First-run welcome window.",
    )

    static let onboardingGetStarted = NSLocalizedString(
        "browser.onboarding.get_started",
        comment: "First-run welcome window.",
    )

    static let onboardingImportTitle = NSLocalizedString(
        "browser.onboarding.import_title",
        comment: "First-run welcome window.",
    )

    static let onboardingImportSubtitle = NSLocalizedString(
        "browser.onboarding.import_subtitle",
        comment: "First-run welcome window.",
    )

    static let onboardingImportNothingFound = NSLocalizedString(
        "browser.onboarding.import_nothing",
        comment: "First-run welcome window.",
    )

    static let onboardingImportKeychainNote = NSLocalizedString(
        "browser.onboarding.import_note",
        comment: "First-run welcome window.",
    )

    static let onboardingImport = NSLocalizedString("browser.onboarding.import", comment: "First-run welcome window.")

    static let onboardingContinue = NSLocalizedString(
        "browser.onboarding.continue",
        comment: "First-run welcome window.",
    )

    static let onboardingSkip = NSLocalizedString("browser.onboarding.skip", comment: "First-run welcome window.")

    static let onboardingNotNow = NSLocalizedString("browser.onboarding.not_now", comment: "First-run welcome window.")

    static let onboardingItemSpaces = NSLocalizedString(
        "browser.onboarding.item_spaces",
        comment: "First-run welcome window.",
    )

    static let onboardingItemBookmarks = NSLocalizedString(
        "browser.onboarding.item_bookmarks",
        comment: "First-run welcome window.",
    )

    static let onboardingItemPasswords = NSLocalizedString(
        "browser.onboarding.item_passwords",
        comment: "First-run welcome window.",
    )

    static let onboardingItemHistory = NSLocalizedString(
        "browser.onboarding.item_history",
        comment: "First-run welcome window.",
    )

    static let onboardingItemSignIns = NSLocalizedString(
        "browser.onboarding.item_signins",
        comment: "First-run welcome window.",
    )

    static let onboardingItemExtensions = NSLocalizedString(
        "browser.onboarding.item_extensions",
        comment: "First-run welcome window.",
    )

    static let onboardingItemSiteSearches = NSLocalizedString(
        "browser.onboarding.item_site_searches",
        comment: "First-run welcome window.",
    )

    static let onboardingLookTitle = NSLocalizedString(
        "browser.onboarding.look_title",
        comment: "First-run welcome window.",
    )

    static let onboardingLookSubtitle = NSLocalizedString(
        "browser.onboarding.look_subtitle",
        comment: "First-run welcome window.",
    )

    static let onboardingSidebarLeft = NSLocalizedString(
        "browser.onboarding.sidebar_left",
        comment: "First-run welcome window.",
    )

    static let onboardingSidebarRight = NSLocalizedString(
        "browser.onboarding.sidebar_right",
        comment: "First-run welcome window.",
    )

    static let onboardingShowToolbar = NSLocalizedString(
        "browser.onboarding.show_toolbar",
        comment: "First-run welcome window.",
    )

    static let onboardingDefaultTitle = NSLocalizedString(
        "browser.onboarding.default_title",
        comment: "First-run welcome window.",
    )

    static let onboardingDefaultSubtitle = NSLocalizedString(
        "browser.onboarding.default_subtitle",
        comment: "First-run welcome window.",
    )

    static let onboardingDefaultDone = NSLocalizedString(
        "browser.onboarding.default_done",
        comment: "First-run welcome window.",
    )

    static let onboardingSetDefault = NSLocalizedString(
        "browser.onboarding.set_default",
        comment: "First-run welcome window.",
    )

    static let onboardingDoneTitle = NSLocalizedString(
        "browser.onboarding.done_title",
        comment: "First-run welcome window.",
    )

    static let onboardingStart = NSLocalizedString("browser.onboarding.start", comment: "First-run welcome window.")

    static let onboardingTipCommandBar = NSLocalizedString(
        "browser.onboarding.tip_command_bar",
        comment: "First-run welcome window.",
    )

    static let onboardingTipSidebar = NSLocalizedString(
        "browser.onboarding.tip_sidebar",
        comment: "First-run welcome window.",
    )

    static let onboardingTipSplit = NSLocalizedString(
        "browser.onboarding.tip_split",
        comment: "First-run welcome window.",
    )

    static let onboardingTipToolbar = NSLocalizedString(
        "browser.onboarding.tip_toolbar",
        comment: "First-run welcome window.",
    )

    static let menuShowWelcome = NSLocalizedString("browser.menu.show_welcome", comment: "First-run welcome window.")

    static let screenShareTitle = NSLocalizedString(
        "browser.screen_share.title",
        comment: "Window that chooses what a website can capture.",
    )

    static let screenShareScreens = NSLocalizedString(
        "browser.screen_share.screens",
        comment: "Window that chooses what a website can capture.",
    )

    static let screenShareWindows = NSLocalizedString(
        "browser.screen_share.windows",
        comment: "Window that chooses what a website can capture.",
    )

    static let screenShareAction = NSLocalizedString(
        "browser.screen_share.share",
        comment: "Window that chooses what a website can capture.",
    )

    static let screenShareCancel = NSLocalizedString(
        "browser.screen_share.cancel",
        comment: "Window that chooses what a website can capture.",
    )

    static let screenShareNeedsPermission = NSLocalizedString(
        "browser.screen_share.needs_permission",
        comment: "Window that chooses what a website can capture.",
    )

    static let screenShareOpenSettings = NSLocalizedString(
        "browser.screen_share.open_settings",
        comment: "Window that chooses what a website can capture.",
    )

    static let menuCustomizeToolbar = NSLocalizedString(
        "browser.menu.customize_toolbar",
        comment: "View menu command that starts customizing the top toolbar.",
    )

    static let toolbarCustomizeHint = NSLocalizedString(
        "browser.toolbar.customize_hint",
        comment: "Instruction at the top of the toolbar customization palette.",
    )

    static let toolbarRestoreDefaults = NSLocalizedString(
        "browser.toolbar.restore_defaults",
        comment: "Button restoring the default toolbar.",
    )

    static let toolbarCustomizeDone = NSLocalizedString(
        "browser.toolbar.customize_done",
        comment: "Button finishing toolbar customization.",
    )

    static let toolbarAddressItem = NSLocalizedString(
        "browser.toolbar.address_item",
        comment: "Palette name of the page address in the toolbar.",
    )

    static let toolbarFlexibleSpaceItem = NSLocalizedString(
        "browser.toolbar.flexible_space_item",
        comment: "Palette name of the empty space that stretches in the toolbar.",
    )

    static let toolbarPinnedExtensionsItem = NSLocalizedString(
        "browser.toolbar.pinned_extensions_item",
        comment: "Palette name of the pinned extension buttons in the toolbar.",
    )

    static let menuShowToolbar = NSLocalizedString(
        "browser.menu.show_toolbar",
        comment: "View menu and command title that shows the page URL as a toolbar above the page.",
    )

    static let menuHideToolbar = NSLocalizedString(
        "browser.menu.hide_toolbar",
        comment: "View menu and command title that moves the page URL from the toolbar back into the sidebar.",
    )

    static let splitPaneGripAccessibilityLabel = NSLocalizedString(
        "browser.split.pane_grip",
        comment: "Accessibility label of the handle that reorders a Split View pane by dragging.",
    )

    static let menuDeveloperTools = NSLocalizedString(
        "browser.menu.developer_tools",
        comment: "View menu and command title that opens the page's developer tools.",
    )

    static let menuViewSource = NSLocalizedString(
        "browser.menu.view_source",
        comment: "View menu and command title that opens the page's HTML source in a new tab.",
    )

    static let settingsImportArcSidebar = NSLocalizedString(
        "browser.settings.import_arc_sidebar",
        comment: "Settings import button that adds Arc's Spaces, pinned tabs, folders and Favorites.",
    )

    static let sidebarImportUnavailable = NSLocalizedString(
        "browser.sidebar_import.unavailable",
        comment: "Alert shown when the window cannot take an import right now.",
    )

    static let peekSearchSpacesPlaceholder = NSLocalizedString(
        "browser.peek.search_spaces",
        comment: "Placeholder of the small window's Space picker field.",
    )
    static let peekCloseAction = NSLocalizedString("browser.peek.close", comment: "Button that closes a Peek card.")

    static let peekOpenInSplitViewAction = NSLocalizedString(
        "browser.peek.open_in_split_view",
        comment: "Button that moves a Peek card's page into a Split View beside the page behind it.",
    )

    static let peekOpenInTabAction = NSLocalizedString(
        "browser.peek.open_in_tab",
        comment: "Button that moves a Peek card's page into a tab.",
    )

    static let settingsPeek = NSLocalizedString(
        "browser.settings.peek",
        comment: "Settings toggle: Shift-clicked links open in a floating Peek card.",
    )

    static let settingsLittleArc = NSLocalizedString(
        "browser.settings.little_arc",
        comment: "Settings toggle: links from other apps open in a small window of their own.",
    )

    static let settingsLittleArcDetail = NSLocalizedString(
        "browser.settings.little_arc.detail",
        comment: "Settings detail for the small window for links from other apps.",
    )

    static let settingsPeekDetail = NSLocalizedString(
        "browser.settings.peek.detail",
        comment: "Settings detail for the Peek toggle.",
    )

    static let settingsLittleWindowOptionCommandClick = NSLocalizedString(
        "browser.settings.little_window_option_command_click",
        comment: "Settings toggle: Option-Command-clicked links open in a small window of their own.",
    )

    static let settingsLittleWindowFromAnyApp = NSLocalizedString(
        "browser.settings.little_window_any_app",
        comment: "Settings toggle: Option-Command-N opens a small window even while another app is active.",
    )

    static let settingsFolderPreviews = NSLocalizedString(
        "browser.settings.folder_previews",
        comment: "Settings toggle: resting the pointer on a collapsed sidebar folder lists its tabs.",
    )

    static let folderPreviewSearchNamedPlaceholder = NSLocalizedString(
        "browser.folder_preview.search_named_placeholder",
        comment: "Placeholder of the search field in a sidebar folder's preview; the folder's name.",
    )
    static let folderPreviewNoMatches = NSLocalizedString(
        "browser.folder_preview.no_matches",
        comment: "Shown in a folder's preview when no tab matches the search.",
    )
    static let folderPreviewSearchPlaceholder = NSLocalizedString(
        "browser.folder_preview.search_placeholder",
        comment: "Placeholder of the search field in a sidebar folder's preview.",
    )

    static let settingsPeekOtherSites = NSLocalizedString(
        "browser.settings.peek_other_sites",
        comment: "Settings toggle: links to other sites from pinned tabs and Favorites open in Peek.",
    )

    static let settingsPeekOtherSitesDetail = NSLocalizedString(
        "browser.settings.peek_other_sites.detail",
        comment: "Settings detail for opening links to other sites from pinned tabs in Peek.",
    )

    static let settingsLinkRoutesTitle = NSLocalizedString(
        "browser.settings.link_routes",
        comment: "Settings section of rules that choose where links from other apps open.",
    )

    static let settingsLinkRoutesDetail = NSLocalizedString(
        "browser.settings.link_routes.detail",
        comment: "Settings detail explaining the rules for links from other apps.",
    )

    static let settingsLinkRouteSite = NSLocalizedString(
        "browser.settings.link_routes.site",
        comment: "Link rule condition: the link is on this site.",
    )

    static let settingsLinkRouteContains = NSLocalizedString(
        "browser.settings.link_routes.contains",
        comment: "Link rule condition: the link's address contains this text.",
    )

    static let settingsLinkRoutePatternPlaceholder = NSLocalizedString(
        "browser.settings.link_routes.pattern_placeholder",
        comment: "Placeholder of a link rule's site or text field.",
    )

    static let settingsLinkRouteOpensIn = NSLocalizedString(
        "browser.settings.link_routes.opens_in",
        comment: "Label between a link rule's condition and its destination.",
    )

    static let settingsLinkRouteLittleWindow = NSLocalizedString(
        "browser.settings.link_routes.little_window",
        comment: "Link rule destination: a small window of its own.",
    )

    static let settingsLinkRouteAdd = NSLocalizedString(
        "browser.settings.link_routes.add",
        comment: "Button that adds a rule for links from other apps.",
    )

    static let settingsLinkRouteRemove = NSLocalizedString(
        "browser.settings.link_routes.remove",
        comment: "Accessibility label of the button that removes a link rule.",
    )

    static let menuRestoreLastClosedTab = NSLocalizedString(
        "browser.menu.restore_last_closed_tab",
        comment: "File menu and command title that reopens the most recently closed tab.",
    )

    static let menuOpenLocation = NSLocalizedString(
        "browser.menu.open_location",
        comment: "File menu and command title that edits the current page's URL in the command bar.",
    )

    static let menuTabs = NSLocalizedString("browser.menu.tabs", comment: "Title of the Tabs menu.")

    static let menuSpaces = NSLocalizedString("browser.menu.spaces", comment: "Title of the Spaces menu.")

    static let menuPinTab = NSLocalizedString(
        "browser.menu.pin_tab",
        comment: "Tabs menu and command title that moves the selected tab into the pinned tabs.",
    )

    static let menuUnpinTab = NSLocalizedString(
        "browser.menu.unpin_tab",
        comment: "Tabs menu and command title that moves the selected pinned tab back to the temporary tabs.",
    )

    static let menuDuplicateTab = NSLocalizedString(
        "browser.menu.duplicate_tab",
        comment: "Tabs menu and command title that opens a copy of the selected tab.",
    )

    static let menuRenameTab = NSLocalizedString(
        "browser.menu.rename_tab",
        comment: "Tabs menu and command title that starts renaming the selected tab in the sidebar.",
    )

    static let menuResetTabToPinnedURL = NSLocalizedString(
        "browser.menu.reset_tab_to_pinned_url",
        comment: "Tabs menu and command title that returns a pinned tab to its pinned URL.",
    )

    static let iconPickerSearch = NSLocalizedString(
        "browser.icon_picker.search",
        comment: "Placeholder of the icon picker's search field.",
    )

    static let iconPickerEmoji = NSLocalizedString(
        "browser.icon_picker.emoji",
        comment: "Icon picker tab with emoji.",
    )

    static let iconPickerIcon = NSLocalizedString(
        "browser.icon_picker.icon",
        comment: "Icon picker tab with symbols.",
    )

    static let spaceCreationTitle = NSLocalizedString(
        "browser.space.creation.title",
        comment: "Title of the sidebar page that creates a Space.",
    )

    static let spaceCreationDetail = NSLocalizedString(
        "browser.space.creation.detail",
        comment: "Description on the sidebar page that creates a Space.",
    )

    static let spaceCreationNamePlaceholder = NSLocalizedString(
        "browser.space.creation.name_placeholder",
        comment: "Placeholder of the new Space's name field.",
    )

    static let spaceCreationTheme = NSLocalizedString(
        "browser.space.creation.theme",
        comment: "Button that opens the theme editor for a new Space.",
    )

    static let spaceCreationCreate = NSLocalizedString(
        "browser.space.creation.create",
        comment: "Button that creates the new Space.",
    )

    static let spaceCreationCancel = NSLocalizedString(
        "browser.space.creation.cancel",
        comment: "Button that leaves the page without creating a Space.",
    )

    static let dockMenuNewSpace = NSLocalizedString(
        "browser.dock_menu.new_space",
        comment: "Item of the menu on the sidebar's plus button.",
    )

    static let dockMenuNewFolder = NSLocalizedString(
        "browser.dock_menu.new_folder",
        comment: "Item of the menu on the sidebar's plus button.",
    )

    static let dockMenuNewSplit = NSLocalizedString(
        "browser.dock_menu.new_split",
        comment: "Item of the menu on the sidebar's plus button.",
    )

    static let dockMenuNewTab = NSLocalizedString(
        "browser.dock_menu.new_tab",
        comment: "Item of the menu on the sidebar's plus button.",
    )

    static let spaceSetProfileAction = NSLocalizedString(
        "browser.space.set_profile_action",
        comment: "Space menu submenu that chooses the browser profile for the Space.",
    )

    static let spaceCreationProfile = NSLocalizedString(
        "browser.space.creation.profile",
        comment: "Label of the profile choice for a new Space.",
    )

    static let spaceEditThemeAction = NSLocalizedString(
        "browser.space.edit_theme_action",
        comment: "Space menu action that opens the theme editor.",
    )

    static let spaceThemeEmpty = NSLocalizedString(
        "browser.space.theme.empty",
        comment: "Theme editor's pad when the Space has no color.",
    )

    static let spaceThemeModeAutomatic = NSLocalizedString(
        "browser.space.theme.mode_automatic",
        comment: "Theme editor button: follow the system's light or dark mode.",
    )

    static let spaceThemeModeLight = NSLocalizedString(
        "browser.space.theme.mode_light",
        comment: "Theme editor button: always use the light look.",
    )

    static let spaceThemeModeDark = NSLocalizedString(
        "browser.space.theme.mode_dark",
        comment: "Theme editor button: always use the dark look.",
    )

    static let spaceThemeAddColor = NSLocalizedString(
        "browser.space.theme.add_color",
        comment: "Theme editor button that adds a color.",
    )

    static let spaceThemeRemoveColor = NSLocalizedString(
        "browser.space.theme.remove_color",
        comment: "Theme editor button that removes a color.",
    )

    static let spaceThemeNextPage = NSLocalizedString(
        "browser.space.theme.next_page",
        comment: "Theme editor button that shows the next page of colors.",
    )

    static let spaceThemePreviousPage = NSLocalizedString(
        "browser.space.theme.previous_page",
        comment: "Theme editor button that shows the previous page of colors.",
    )

    static let spaceThemeIntensity = NSLocalizedString(
        "browser.space.theme.intensity",
        comment: "Theme editor slider label: how strongly the colors cover the window.",
    )

    static let spaceThemeCycleTexture = NSLocalizedString(
        "browser.space.theme.cycle_texture",
        comment: "Theme editor dial tooltip.",
    )

    // Spoken color names for the theme editor's swatches.
    static let colorRed = NSLocalizedString("browser.color.red", comment: "Spoken name of a theme color.")
    static let colorOrange = NSLocalizedString("browser.color.orange", comment: "Spoken name of a theme color.")
    static let colorYellow = NSLocalizedString("browser.color.yellow", comment: "Spoken name of a theme color.")
    static let colorGreen = NSLocalizedString("browser.color.green", comment: "Spoken name of a theme color.")
    static let colorTeal = NSLocalizedString("browser.color.teal", comment: "Spoken name of a theme color.")
    static let colorBlue = NSLocalizedString("browser.color.blue", comment: "Spoken name of a theme color.")
    static let colorPurple = NSLocalizedString("browser.color.purple", comment: "Spoken name of a theme color.")
    static let colorPink = NSLocalizedString("browser.color.pink", comment: "Spoken name of a theme color.")
    static let colorGray = NSLocalizedString("browser.color.gray", comment: "Spoken name of a theme color.")
    static let colorWhite = NSLocalizedString("browser.color.white", comment: "Spoken name of a theme color.")
    static let colorBlack = NSLocalizedString("browser.color.black", comment: "Spoken name of a theme color.")
    static let spaceThemeSetColor = NSLocalizedString(
        "browser.space.theme.set_color",
        comment: "Theme editor swatch button label.",
    )

    static let menuResetSpaceTabs = NSLocalizedString(
        "browser.menu.reset_space_tabs",
        comment: "Spaces menu, Space menu and command title that returns every pinned tab of the Space to its pinned page.",
    )

    static let menuCollapseAllFolders = NSLocalizedString(
        "browser.menu.collapse_all_folders",
        comment: "Tabs menu and command title that collapses every folder of the Space.",
    )

    static let menuExpandAllFolders = NSLocalizedString(
        "browser.menu.expand_all_folders",
        comment: "Tabs menu and command title that expands every folder of the Space.",
    )

    static let menuInspectElements = NSLocalizedString(
        "browser.menu.inspect_elements",
        comment: "Menu item.",
    )

    static let menuJavaScriptConsole = NSLocalizedString(
        "browser.menu.javascript_console",
        comment: "Menu item.",
    )

    static let menuMuteAllTabs = NSLocalizedString(
        "browser.menu.mute_all_tabs",
        comment: "Command that mutes every open tab.",
    )

    static let menuUnmuteAllTabs = NSLocalizedString(
        "browser.menu.unmute_all_tabs",
        comment: "Command that brings back the sound of every open tab.",
    )

    static let menuClosePictureInPicture = NSLocalizedString(
        "browser.menu.close_picture_in_picture",
        comment: "Command that brings the page's video back from its floating window.",
    )

    static let menuOpenPictureInPicture = NSLocalizedString(
        "browser.menu.open_picture_in_picture",
        comment: "Command that moves the page's video to a floating window, or back.",
    )

    static let sidebarDragToAddFavorites = NSLocalizedString(
        "browser.sidebar.drag_to_add_favorites",
        comment: "Shown where a dragged tab can become the first Favorite.",
    )

    static let menuManageSpaces = NSLocalizedString(
        "browser.menu.manage_spaces",
        comment: "Menu item.",
    )

    static let menuShareTab = NSLocalizedString(
        "browser.menu.share_tab",
        comment: "Menu item.",
    )

    static let menuViewLibrary = NSLocalizedString(
        "browser.menu.view_library",
        comment: "Menu item that opens the Library.",
    )

    /// The Window menu says Open Library…; Settings say View Library.
    static let menuOpenLibrary = NSLocalizedString(
        "browser.menu.open_library",
        comment: "Window menu item that opens the Library.",
    )

    /// The Spaces menu says Edit Theme…; a Space's own menu says Edit Theme Color….
    static let menuEditTheme = NSLocalizedString(
        "browser.menu.edit_theme",
        comment: "Spaces menu item that edits the shown Space's theme.",
    )

    static let libraryMoreActions = NSLocalizedString(
        "browser.library.more_actions",
        comment: "Accessibility label of the … button on a Space's card in the Library.",
    )
    static let libraryMedia = NSLocalizedString(
        "browser.library.media",
        comment: "Library section with pictures.",
    )

    static let libraryDownloads = NSLocalizedString(
        "browser.library.downloads",
        comment: "Library section with downloads.",
    )

    static let librarySpaces = NSLocalizedString(
        "browser.library.spaces",
        comment: "Library section with all Spaces.",
    )

    static let libraryArchive = NSLocalizedString(
        "browser.library.archive",
        comment: "Library section with archived tabs.",
    )

    static let pinnedTabEditPageAction = NSLocalizedString(
        "browser.pinned_tab.edit_page",
        comment: "Pinned tab submenu.",
    )
    static let tabRemovePinAction = NSLocalizedString("browser.tab.remove_pin", comment: "Pinned tab menu item.")
    static let menuAllowJavaScriptFromAppleEvents = NSLocalizedString(
        "browser.menu.allow_javascript_from_apple_events",
        comment: "Developer menu item.",
    )
    static let scriptJavaScriptTurnedOff = NSLocalizedString(
        "browser.script.javascript_turned_off",
        comment: "Error for a script that runs JavaScript while the setting is off.",
    )
    static let menuTurnOnDeveloperMode = NSLocalizedString(
        "browser.menu.developer_mode_on",
        comment: "Developer menu item.",
    )
    static let menuTurnOffDeveloperMode = NSLocalizedString(
        "browser.menu.developer_mode_off",
        comment: "Developer menu item.",
    )
    static let developerReloadOptions = NSLocalizedString(
        "browser.developer.reload_options",
        comment: "Tooltip of the reload options button.",
    )
    static let developerReload = NSLocalizedString("browser.developer.reload", comment: "Reload option.")
    static let developerReloadIgnoreCache = NSLocalizedString(
        "browser.developer.reload_ignore_cache",
        comment: "Reload option.",
    )
    static let settingsShowAISearchSuggestion = NSLocalizedString(
        "browser.settings.show_ai_search_suggestion",
        comment: "Settings toggle for the AI row in the command bar.",
    )
    static let blankWindowTabsTitle = NSLocalizedString(
        "browser.sidebar.blank_window_tabs",
        comment: "Title above a blank window's tabs.",
    )
    static let captureToastCopied = NSLocalizedString("browser.capture.toast_copied", comment: "Note after a capture.")
    static let copiedCurrentURLToast = NSLocalizedString(
        "browser.toast.copied_current_url",
        comment: "Note at the page's top right after Copy URL from the menu or its shortcut.",
    )
    static let captureToastSave = NSLocalizedString(
        "browser.capture.toast_save",
        comment: "Button that saves a capture.",
    )
    static let fullScreenExitNote = NSLocalizedString(
        "browser.fullscreen.exit_note",
        comment: "Note shown on entering a full screen window.",
    )
    static let captureToastHintLeading = NSLocalizedString(
        "browser.capture.toast_hint_leading",
        comment: "Text before the keys.",
    )
    static let captureToastHintTrailing = NSLocalizedString(
        "browser.capture.toast_hint_trailing",
        comment: "Text after the keys.",
    )
    static let captureCardSendTo = NSLocalizedString(
        "browser.capture.card.send_to",
        comment: "Placeholder of the field that filters the capture card's menu.",
    )
    static let captureCardAccessibilityLabel = NSLocalizedString(
        "browser.capture.card.accessibility",
        comment: "VoiceOver name of the card shown after a capture.",
    )
    static let captureCardSaveToLibrary = NSLocalizedString(
        "browser.capture.card.save_to_library",
        comment: "Capture card item that saves the capture to the Library.",
    )
    static let captureCardSavedToLibrary = NSLocalizedString(
        "browser.capture.card.saved_to_library",
        comment: "Capture card item once the capture is in the Library; choosing it removes it again.",
    )
    static let captureCardCopy = NSLocalizedString("browser.capture.card.copy", comment: "Capture card item.")
    static let captureCardSave = NSLocalizedString(
        "browser.capture.card.save",
        comment: "Capture card item that saves the picture to a file.",
    )
    static let captureCardSendMessage = NSLocalizedString(
        "browser.capture.card.send_message",
        comment: "Capture card item that sends the picture in Messages.",
    )
    static let captureCardEdit = NSLocalizedString(
        "browser.capture.card.edit",
        comment: "Capture card item that opens the picture in Preview to mark it up.",
    )
    static let captureCardRetake = NSLocalizedString(
        "browser.capture.card.retake",
        comment: "Capture card item that outlines a new part of the page.",
    )
    static let captureCardNewEasel = NSLocalizedString(
        "browser.capture.card.new_easel",
        comment: "Capture card item that starts an Easel with the picture.",
    )
    static let captureFileName = NSLocalizedString(
        "browser.capture.file_name",
        comment: "Default name of a saved capture.",
    )
    static let settingsIconTab = NSLocalizedString(
        "browser.settings.icon_tab",
        comment: "Settings pane for the Dock icon.",
    )
    static let appIconStandard = NSLocalizedString("browser.app_icon.standard", comment: "App icon name.")
    static let appIconNeon = NSLocalizedString("browser.app_icon.neon", comment: "App icon name.")
    static let appIconCandy = NSLocalizedString("browser.app_icon.candy", comment: "App icon name.")
    static let appIconHologram = NSLocalizedString("browser.app_icon.hologram", comment: "App icon name.")
    static let appIconSunset = NSLocalizedString("browser.app_icon.sunset", comment: "App icon name.")
    static let appIconSticker = NSLocalizedString("browser.app_icon.sticker", comment: "App icon name.")
    static let appIconMonochrome = NSLocalizedString("browser.app_icon.monochrome", comment: "App icon name.")
    static let settingsRecentPagesPreviews = NSLocalizedString(
        "browser.settings.recent_pages_previews",
        comment: "Settings toggle for hover previews on some sites.",
    )
    static let captureInPortraitMode = NSLocalizedString("browser.capture.portrait", comment: "Menu item and button.")
    static let liveFoldersMenu = NSLocalizedString("browser.live_folders.menu", comment: "Space submenu.")
    static let liveFolderGitHubTitle = NSLocalizedString(
        "browser.live_folders.github",
        comment: "GitHub live folder's name.",
    )
    static let siteSettingDeveloperMode = NSLocalizedString(
        "browser.site_setting.developer_mode",
        comment: "Site setting.",
    )
    static let siteSettingOn = NSLocalizedString("browser.site_setting.on", comment: "Site setting's state.")
    static let siteSettingOff = NSLocalizedString("browser.site_setting.off", comment: "Site setting's state.")
    static let siteSettingTurnOn = NSLocalizedString(
        "browser.site_setting.turn_on",
        comment: "Site setting's menu item.",
    )
    static let siteSettingTurnOff = NSLocalizedString(
        "browser.site_setting.turn_off",
        comment: "Site setting's menu item.",
    )
    static let settingsSoundEffects = NSLocalizedString("browser.settings.sound_effects", comment: "Settings toggle.")
    static let cardSaveTitle = NSLocalizedString("browser.card.save_title", comment: "Prompt.")
    static let cardFillTitle = NSLocalizedString("browser.card.fill_title", comment: "Prompt.")
    static let cardFillDetail = NSLocalizedString("browser.card.fill_detail", comment: "Prompt's detail.")
    static let cardFillReason = NSLocalizedString("browser.card.fill_reason", comment: "System authentication dialog.")
    static let settingsCards = NSLocalizedString("browser.settings.cards", comment: "Settings section.")
    static let cardNoneSaved = NSLocalizedString("browser.card.none_saved", comment: "Settings, empty list.")
    static let pinnedTabFolderCopyAllLinksAction = NSLocalizedString(
        "browser.pinned_tab_folder.copy_all_links",
        comment: "Folder context menu item; copies the address of every tab in the folder, one per line.",
    )
    static let pinnedTabFolderNewNestedAction = NSLocalizedString(
        "browser.pinned_tab_folder.new_nested",
        comment: "Folder menu.",
    )
    static let pinnedTabFolderTurnIntoSpaceAction = NSLocalizedString(
        "browser.pinned_tab_folder.turn_into_space",
        comment: "Folder menu. The folder's name.",
    )
    nonisolated static let javaScriptDialogSays = NSLocalizedString(
        "browser.js_dialog.says",
        comment: "A page's alert. The site's name.",
    )
    nonisolated static let javaScriptDialogPageSays = NSLocalizedString(
        "browser.js_dialog.page_says",
        comment: "A page's alert with no site name.",
    )
    static let menuGettingStarted = NSLocalizedString("browser.menu.getting_started", comment: "Help menu.")
    static let menuTroubleshooting = NSLocalizedString("browser.menu.troubleshooting", comment: "Help menu.")
    static let menuRecordTrace = NSLocalizedString("browser.menu.record_trace", comment: "Help menu.")
    static let menuTaskManager = NSLocalizedString("browser.menu.task_manager", comment: "Help menu.")
    static let menuRestoreData = NSLocalizedString("browser.menu.restore_data", comment: "Help menu.")
    static let restoreDataRestore = NSLocalizedString("browser.restore_data.restore", comment: "Button.")
    static let restoreDataRestart = NSLocalizedString("browser.restore_data.restart", comment: "Button.")
    static let restoreDataNone = NSLocalizedString("browser.restore_data.none", comment: "No copies yet.")
    static let restoreDataNote = NSLocalizedString("browser.restore_data.note", comment: "Window's note.")
    static let restoreDataConfirm = NSLocalizedString(
        "browser.restore_data.confirm",
        comment: "Alert. The copy's date.",
    )
    static let restoreDataConfirmDetail = NSLocalizedString("browser.restore_data.confirm_detail", comment: "Alert.")
    static let settingsMailPreviews = NSLocalizedString("browser.settings.mail_previews", comment: "Settings toggle.")
    static let mailPreviewLoading = NSLocalizedString("browser.mail_preview.loading", comment: "Preview row.")
    static let mailPreviewSignIn = NSLocalizedString("browser.mail_preview.sign_in", comment: "Preview row.")
    static let mailPreviewEmpty = NSLocalizedString("browser.mail_preview.empty", comment: "Preview row.")
    static let taskManagerTask = NSLocalizedString("browser.task_manager.task", comment: "Column.")
    static let taskManagerMemory = NSLocalizedString("browser.task_manager.memory", comment: "Column.")
    static let taskManagerCPU = NSLocalizedString("browser.task_manager.cpu", comment: "Column.")
    static let taskManagerProcessID = NSLocalizedString("browser.task_manager.process_id", comment: "Column.")
    static let taskManagerEndProcess = NSLocalizedString("browser.task_manager.end_process", comment: "Button.")
    static let taskManagerBrowser = NSLocalizedString("browser.task_manager.browser", comment: "The app's own row.")
    static let traceDuration = NSLocalizedString("browser.trace.duration", comment: "Record Trace window.")
    static let traceIssue = NSLocalizedString("browser.trace.issue", comment: "Record Trace window.")
    static let traceStart = NSLocalizedString("browser.trace.start", comment: "Record Trace window.")
    static let traceRecording = NSLocalizedString("browser.trace.recording", comment: "Record Trace window.")
    static let traceNote = NSLocalizedString("browser.trace.note", comment: "Record Trace window.")
    static let traceSeconds = NSLocalizedString("browser.trace.seconds", comment: "Record Trace window: 15 seconds.")
    static let authDialogTitle = NSLocalizedString("browser.auth.title", comment: "Sign-in sheet. The site's name.")
    static let authDialogPrivate = NSLocalizedString("browser.auth.private", comment: "Sign-in sheet.")
    static let authDialogNotPrivate = NSLocalizedString("browser.auth.not_private", comment: "Sign-in sheet.")
    static let authDialogUsername = NSLocalizedString("browser.auth.username", comment: "Sign-in sheet.")
    static let authDialogPassword = NSLocalizedString("browser.auth.password", comment: "Sign-in sheet.")
    static let authDialogSignIn = NSLocalizedString("browser.auth.sign_in", comment: "Sign-in sheet.")
    static let javaScriptDialogOK = NSLocalizedString("browser.js_dialog.ok", comment: "A page's alert.")
    static let javaScriptDialogCancel = NSLocalizedString("browser.js_dialog.cancel", comment: "A page's alert.")
    static let addressSaveTitle = NSLocalizedString("browser.address.save_title", comment: "Prompt.")
    static let addressFillTitle = NSLocalizedString("browser.address.fill_title", comment: "Prompt.")
    static let addressFillDetail = NSLocalizedString("browser.address.fill_detail", comment: "Prompt's detail.")
    static let settingsAddresses = NSLocalizedString("browser.settings.addresses", comment: "Settings section.")
    static let addressNoneSaved = NSLocalizedString("browser.address.none_saved", comment: "Settings, empty list.")
    static let passwordSaveTitle = NSLocalizedString("browser.password.save_title", comment: "Prompt; the site.")
    static let passwordUpdateTitle = NSLocalizedString("browser.password.update_title", comment: "Prompt; the site.")
    static let passwordFillTitle = NSLocalizedString("browser.password.fill_title", comment: "Prompt; the site.")
    static let passwordFillDetail = NSLocalizedString("browser.password.fill_detail", comment: "Prompt's detail.")
    static let passwordNoUsername = NSLocalizedString(
        "browser.password.no_username",
        comment: "A sign-in with no username.",
    )
    static let passwordSave = NSLocalizedString("browser.password.save", comment: "Button.")
    static let passwordUpdate = NSLocalizedString("browser.password.update", comment: "Button.")
    static let passwordNotNow = NSLocalizedString("browser.password.not_now", comment: "Button.")
    static let passwordNever = NSLocalizedString("browser.password.never", comment: "Button.")
    static let passwordDelete = NSLocalizedString("browser.password.delete", comment: "Button in Settings.")
    static let passwordCopy = NSLocalizedString("browser.password.copy", comment: "Button in Settings.")
    static let passwordNoneSaved = NSLocalizedString("browser.password.none_saved", comment: "Settings, empty list.")
    static let menuTranslatePage = NSLocalizedString("browser.menu.translate_page", comment: "Command.")
    static let menuGoBack = NSLocalizedString("browser.menu.go_back", comment: "Archive menu item.")
    static let menuGoForward = NSLocalizedString("browser.menu.go_forward", comment: "Archive menu item.")
    static let menuRefreshPage = NSLocalizedString("browser.menu.refresh_page", comment: "View menu item.")
    static let menuHideSidebar = NSLocalizedString("browser.menu.hide_sidebar", comment: "View menu item.")
    static let menuShowSidebar = NSLocalizedString("browser.menu.show_sidebar", comment: "View menu item.")
    static let menuCloseLibrary = NSLocalizedString("browser.menu.close_library", comment: "Window menu item.")
    static let menuManageExtensions = NSLocalizedString(
        "browser.menu.manage_extensions",
        comment: "Extensions menu item.",
    )
    static let menuImportFromBrowser = NSLocalizedString("browser.menu.import_from_browser", comment: "App menu item.")
    static let menuBlankWindow = NSLocalizedString("browser.menu.blank_window", comment: "File menu item.")
    static let menuNewProfile = NSLocalizedString("browser.menu.new_profile", comment: "File menu item.")
    static let spaceMenuNewProfile = NSLocalizedString(
        "browser.space.menu_new_profile",
        comment: "Space menu › Set Profile item that makes a profile for the Space.",
    )
    static let menuDelete = NSLocalizedString("browser.menu.delete", comment: "Edit menu item.")
    static let menuSpellingAndGrammar = NSLocalizedString("browser.menu.spelling", comment: "Edit submenu.")
    static let menuShowSpelling = NSLocalizedString("browser.menu.show_spelling", comment: "Spelling menu item.")
    static let menuCheckDocument = NSLocalizedString("browser.menu.check_document", comment: "Spelling menu item.")
    static let menuCheckSpellingWhileTyping = NSLocalizedString(
        "browser.menu.check_while_typing",
        comment: "Spelling menu item.",
    )
    static let menuCheckGrammar = NSLocalizedString("browser.menu.check_grammar", comment: "Spelling menu item.")
    static let menuCorrectSpelling = NSLocalizedString("browser.menu.correct_spelling", comment: "Spelling menu item.")
    static let menuSubstitutions = NSLocalizedString("browser.menu.substitutions", comment: "Edit submenu.")
    static let menuShowSubstitutions = NSLocalizedString(
        "browser.menu.show_substitutions",
        comment: "Substitutions menu item.",
    )
    static let menuSmartCopyPaste = NSLocalizedString(
        "browser.menu.smart_copy_paste",
        comment: "Substitutions menu item.",
    )
    static let menuSmartQuotes = NSLocalizedString("browser.menu.smart_quotes", comment: "Substitutions menu item.")
    static let menuSmartDashes = NSLocalizedString("browser.menu.smart_dashes", comment: "Substitutions menu item.")
    static let menuSmartLinks = NSLocalizedString("browser.menu.smart_links", comment: "Substitutions menu item.")
    static let menuDataDetectors = NSLocalizedString("browser.menu.data_detectors", comment: "Substitutions menu item.")
    static let menuTextReplacement = NSLocalizedString(
        "browser.menu.text_replacement",
        comment: "Substitutions menu item.",
    )
    static let menuTransformations = NSLocalizedString("browser.menu.transformations", comment: "Edit submenu.")
    static let menuMakeUpperCase = NSLocalizedString("browser.menu.upper_case", comment: "Transformations menu item.")
    static let menuMakeLowerCase = NSLocalizedString("browser.menu.lower_case", comment: "Transformations menu item.")
    static let menuCapitalize = NSLocalizedString("browser.menu.capitalize", comment: "Transformations menu item.")
    static let menuSpeech = NSLocalizedString("browser.menu.speech", comment: "Edit submenu.")
    static let menuStartSpeaking = NSLocalizedString("browser.menu.start_speaking", comment: "Speech menu item.")
    static let menuStopSpeaking = NSLocalizedString("browser.menu.stop_speaking", comment: "Speech menu item.")
    static let menuFormat = NSLocalizedString("browser.menu.format", comment: "Edit submenu.")
    static let menuFont = NSLocalizedString("browser.menu.font", comment: "Format submenu.")
    static let menuBold = NSLocalizedString("browser.menu.bold", comment: "Font menu item.")
    static let menuItalic = NSLocalizedString("browser.menu.italic", comment: "Font menu item.")
    static let menuUnderline = NSLocalizedString("browser.menu.underline", comment: "Font menu item.")
    static let menuAppearance = NSLocalizedString("browser.menu.appearance", comment: "View submenu.")
    static let menuCollapsePinnedTabs = NSLocalizedString("browser.menu.collapse_pinned", comment: "View menu item.")
    static let menuExpandPinnedTabs = NSLocalizedString("browser.menu.expand_pinned", comment: "View menu item.")
    static let menuCast = NSLocalizedString("browser.menu.cast", comment: "View menu item.")
    static let menuDeveloper = NSLocalizedString("browser.menu.developer", comment: "View submenu.")
    static let devToolsDockRight = NSLocalizedString(
        "browser.devtools.dock_right", comment: "Docked Developer Tools edge menu: put them at the page's right.",
    )
    static let devToolsDockBottom = NSLocalizedString(
        "browser.devtools.dock_bottom", comment: "Docked Developer Tools edge menu: put them below the page.",
    )
    static let devToolsDockBack = NSLocalizedString(
        "browser.devtools.dock_back",
        comment: "View › Developer item, shown while Developer Tools open in a window of their own.",
    )
    static let devToolsUndock = NSLocalizedString(
        "browser.devtools.undock", comment: "Docked Developer Tools edge menu: move them into a window of their own.",
    )
    static let devToolsDockLeft = NSLocalizedString(
        "browser.devtools.dock_left", comment: "Docked Developer Tools edge menu: put them at the page's left.",
    )
    static let menuNetworkInspector = NSLocalizedString(
        "browser.menu.network_inspector",
        comment: "Developer menu item.",
    )
    static let menuRenameSpace = NSLocalizedString("browser.menu.rename_space", comment: "Spaces menu item.")
    static let menuChangeProfile = NSLocalizedString("browser.menu.change_profile", comment: "Spaces submenu.")
    static let menuArchive = NSLocalizedString("browser.menu.archive", comment: "Menu bar title.")
    static let menuExtensions = NSLocalizedString("browser.menu.extensions", comment: "Menu bar title.")
    static let menuStayOnTop = NSLocalizedString("browser.menu.stay_on_top", comment: "Window menu item.")
    static let menuViewMedia = NSLocalizedString("browser.menu.view_media", comment: "Window menu item.")
    static let menuHelp = NSLocalizedString("browser.menu.help", comment: "Menu bar title.")
    static let menuKeyboardShortcuts = NSLocalizedString("browser.menu.keyboard_shortcuts", comment: "Help menu item.")
    static let menuContactTeam = NSLocalizedString("browser.menu.contact_team", comment: "Help menu item.")
    static let menuReportIssue = NSLocalizedString("browser.menu.report_issue", comment: "Help menu item.")
    static let menuRevealData = NSLocalizedString("browser.menu.reveal_data", comment: "Help menu item.")
    static let menuCopyInfo = NSLocalizedString("browser.menu.copy_info", comment: "Help menu item.")

    static let libraryBack = NSLocalizedString(
        "browser.library.back",
        comment: "Button that leaves the Library.",
    )

    static let libraryFilter = NSLocalizedString(
        "browser.library.filter",
        comment: "Pop-up button that filters a Library section.",
    )

    static let libraryFilterAll = NSLocalizedString(
        "browser.library.filter_all",
        comment: "Library filter choice that shows everything.",
    )

    static let libraryFilterImages = NSLocalizedString(
        "browser.library.filter_images",
        comment: "Library filter choice for downloaded images.",
    )

    static let libraryFilterDocuments = NSLocalizedString(
        "browser.library.filter_documents",
        comment: "Library filter choice for downloaded documents.",
    )

    static let libraryFilterArchives = NSLocalizedString(
        "browser.library.filter_archives",
        comment: "Library filter choice for downloaded archives.",
    )

    static let libraryToday = NSLocalizedString(
        "browser.library.today",
        comment: "Heading over tabs archived today.",
    )

    static let libraryYesterday = NSLocalizedString(
        "browser.library.yesterday",
        comment: "Heading over tabs archived yesterday.",
    )

    static let libraryRevealInFinder = NSLocalizedString(
        "browser.library.reveal_in_finder",
        comment: "Library row menu item.",
    )

    static let libraryEmptyTitle = NSLocalizedString(
        "browser.library.empty_title",
        comment: "Title of an empty Library section.",
    )

    static let libraryEmptyDetail = NSLocalizedString(
        "browser.library.empty_detail",
        comment: "Detail of an empty Library section.",
    )

    static let libraryMediaSourcesTitle = NSLocalizedString(
        "browser.library.media_sources",
        comment: "Disabled header of the Library button's menu, above the folders Media shows.",
    )
    static let libraryMediaDocuments = NSLocalizedString(
        "browser.library.media_source.documents", comment: "Media folder: the user's Documents folder.",
    )
    static let libraryMediaDesktop = NSLocalizedString(
        "browser.library.media_source.desktop", comment: "Media folder: the user's Desktop.",
    )
    static let libraryMediaScreenshots = NSLocalizedString(
        "browser.library.media_source.screenshots", comment: "Media folder: where screenshots are saved.",
    )
    static let libraryMediaCaptures = NSLocalizedString(
        "browser.library.media_source.captures", comment: "Media source: pictures saved to the Library from captures.",
    )
    static let libraryCaptureCopyURL = NSLocalizedString(
        "browser.library.capture.copy_url", comment: "Menu item of a saved capture: copies the address of its page.",
    )
    static let libraryCaptureOpenURL = NSLocalizedString(
        "browser.library.capture.open_url", comment: "Menu item of a saved capture: opens its page in a new tab.",
    )
    static let libraryCaptureAirDrop = NSLocalizedString(
        "browser.library.capture.airdrop", comment: "Menu item of a saved capture: sends the picture with AirDrop.",
    )
    static let libraryCaptureSendMessage = NSLocalizedString(
        "browser.library.capture.send_message", comment: "Menu item of a saved capture: sends the picture in Messages.",
    )
    static let libraryCaptureDelete = NSLocalizedString(
        "browser.library.capture.delete", comment: "Menu item of a saved capture: deletes it after a confirmation.",
    )
    static let libraryCaptureDeleteTitle = NSLocalizedString(
        "browser.library.capture.delete_title", comment: "Title of the alert before a saved capture is deleted.",
    )
    static let libraryCaptureDeleteDetail = NSLocalizedString(
        "browser.library.capture.delete_detail", comment: "Detail of the alert before a saved capture is deleted.",
    )
    static let libraryMediaDownloads = NSLocalizedString(
        "browser.library.media_source.downloads", comment: "Media folder: the download folder.",
    )
    static let libraryEmptyMedia = NSLocalizedString(
        "browser.library.empty_media",
        comment: "Detail of the empty Media section of the Library.",
    )

    static let menuNewSpaceEllipsis = NSLocalizedString(
        "browser.menu.new_space_ellipsis",
        comment: "Spaces menu item; it opens the new Space's page.",
    )
    static let menuNewFolderEllipsis = NSLocalizedString(
        "browser.menu.new_folder_ellipsis",
        comment: "Tabs menu item; it creates a folder and starts naming it.",
    )
    static let menuViewDownloadsEllipsis = NSLocalizedString(
        "browser.menu.view_downloads_ellipsis",
        comment: "Window menu item; it opens the downloads list.",
    )
    static let menuViewDownloads = NSLocalizedString(
        "browser.menu.view_downloads",
        comment: "View menu and command title that opens the downloads list.",
    )

    static let menuSelectNextTabAlternate = NSLocalizedString(
        "browser.menu.select_next_tab_alternate",
        comment: "Settings shortcut title for the second shortcut of Next Tab.",
    )

    static let menuSelectPreviousTabAlternate = NSLocalizedString(
        "browser.menu.select_previous_tab_alternate",
        comment: "Settings shortcut title for the second shortcut of Previous Tab.",
    )

    static let menuSelectNextSpace = NSLocalizedString(
        "browser.menu.select_next_space",
        comment: "View menu and command title that switches to the next Space.",
    )

    static let menuSelectPreviousSpace = NSLocalizedString(
        "browser.menu.select_previous_space",
        comment: "View menu and command title that switches to the previous Space.",
    )

    static let settingsDownloadsTitle = NSLocalizedString(
        "browser.settings.downloads",
        comment: "Settings section title for downloads.",
    )

    static let settingsDownloadLocation = NSLocalizedString(
        "browser.settings.download_location",
        comment: "Settings row title for the folder that receives downloads.",
    )

    static let settingsDownloadLocationChoose = NSLocalizedString(
        "browser.settings.download_location.choose",
        comment: "Button that picks another folder for downloads.",
    )

    static let settingsDownloadLocationReset = NSLocalizedString(
        "browser.settings.download_location.reset",
        comment: "Button that saves downloads to the Downloads folder again.",
    )

    static let menuOpenExtensions = NSLocalizedString(
        "browser.menu.open_extensions",
        comment: "View menu and command title that opens the site control center with the extensions.",
    )

    static let menuRevealCurrentTab = NSLocalizedString(
        "browser.menu.reveal_current_tab",
        comment: "View menu and command title that scrolls the sidebar to the selected tab and shows it.",
    )

    static let menuCopyLinkAsMarkdown = NSLocalizedString(
        "browser.menu.copy_link_as_markdown",
        comment: "Edit menu and command title that copies the page as a Markdown link.",
    )

    static let menuCopyLinkAsQuote = NSLocalizedString(
        "browser.menu.copy_link_as_quote",
        comment: "Edit menu and command title that copies a link to the text selected in the page.",
    )

    static let menuSelectNextTab = NSLocalizedString(
        "browser.menu.select_next_tab",
        comment: "View menu and command title that selects the next item in the sidebar.",
    )

    static let menuSelectPreviousTab = NSLocalizedString(
        "browser.menu.select_previous_tab",
        comment: "View menu and command title that selects the previous item in the sidebar.",
    )

    static let menuGoToLastSidebarItem = NSLocalizedString(
        "browser.menu.go_to_last_sidebar_item",
        comment: "Command title that selects the last tab in the sidebar.",
    )

    static let menuMoveSidebarLeft = NSLocalizedString(
        "browser.menu.move_sidebar_left",
        comment: "View menu and command title that moves the sidebar to the left window edge.",
    )

    static let splitViewButtonTitle = NSLocalizedString(
        "browser.split.button",
        comment: "Toolbar button and menu title for Split View.",
    )

    static let splitDividerAccessibilityLabel = NSLocalizedString(
        "browser.split.divider",
        comment: "Accessibility label of the handle that resizes Split View panes.",
    )

    static let splitOpenInSplitViewAction = NSLocalizedString(
        "browser.split.open_in_split_view",
        comment: "Tab context menu action that opens the tab as a new Split View pane.",
    )

    static let splitSeparateTabAction = NSLocalizedString(
        "browser.split.separate_tab",
        comment: "Removes one tab from its Split View.",
    )

    static let splitSeparateAllTabsAction = NSLocalizedString(
        "browser.split.separate_all_tabs",
        comment: "Ends a Split View and keeps its tabs as separate tabs.",
    )

    static let splitConvertToVerticalAction = NSLocalizedString(
        "browser.split.convert_to_vertical",
        comment: "Stacks Split View panes top to bottom.",
    )

    static let splitConvertToHorizontalAction = NSLocalizedString(
        "browser.split.convert_to_horizontal",
        comment: "Places Split View panes side by side.",
    )

    static let menuToggleSidebar = NSLocalizedString(
        "browser.menu.toggle_sidebar",
        comment: "Toggle Sidebar menu item title.",
    )

    static let menuClearTemporaryTabs = NSLocalizedString(
        "browser.menu.clear_temporary_tabs",
        comment: "Clear Temporary Tabs menu item title.",
    )

    static let webAppInstallAction = NSLocalizedString(
        "browser.web_app.install_action",
        comment: "Menu item for installing the current website as a standalone app.",
    )

    static let webAppInfoAction = NSLocalizedString(
        "browser.web_app.info_action",
        comment: "Menu item for showing information about an installed web app.",
    )

    static let webAppCopyURLAction = NSLocalizedString(
        "browser.web_app.copy_url_action",
        comment: "Menu item for copying the current URL from a web app.",
    )

    static let webAppOpenInBrowserAction = NSLocalizedString(
        "browser.web_app.open_in_browser_action",
        comment: "Menu item for opening the current web app page in the main browser.",
    )

    static let webAppCloseWindowAction = NSLocalizedString(
        "browser.web_app.close_window_action",
        comment: "File menu item for closing a web app window.",
    )

    static let webAppZoomOutAction = NSLocalizedString(
        "browser.web_app.zoom_out_action",
        comment: "Menu item for decreasing web app page zoom.",
    )

    static let webAppZoomResetAction = NSLocalizedString(
        "browser.web_app.zoom_reset_action",
        comment: "Menu item for resetting web app page zoom.",
    )

    static let webAppZoomInAction = NSLocalizedString(
        "browser.web_app.zoom_in_action",
        comment: "Menu item for increasing web app page zoom.",
    )

    static let webAppEditMenu = NSLocalizedString(
        "browser.web_app.edit_menu",
        comment: "Edit submenu title in a web app's More menu.",
    )

    static let webAppCastAction = NSLocalizedString(
        "browser.web_app.cast_action",
        comment: "Cast menu item in a web app.",
    )

    static let webAppMoreAction = NSLocalizedString(
        "browser.web_app.more_action",
        comment: "Tooltip for the web app More menu.",
    )

    static let webAppAlwaysShowToolbarInFullscreen = NSLocalizedString(
        "browser.web_app.always_show_toolbar_in_fullscreen",
        comment: "View menu item controlling web app toolbar visibility in fullscreen.",
    )

    static let webAppAlwaysShowFullURLs = NSLocalizedString(
        "browser.web_app.always_show_full_urls",
        comment: "View menu item controlling whether a web app displays full URLs.",
    )

    static let webAppInstallPromptTitle = NSLocalizedString(
        "browser.web_app.install_prompt.title",
        comment: "Title of the web app installation prompt.",
    )

    static let webAppInstallPromptMessage = NSLocalizedString(
        "browser.web_app.install_prompt.message",
        comment: "Message of the web app installation prompt.",
    )

    static let webAppInstallButton = NSLocalizedString(
        "browser.web_app.install_prompt.install",
        comment: "Confirmation button in the web app installation prompt.",
    )

    static let cancelAction = NSLocalizedString(
        "browser.action.cancel",
        comment: "Generic cancel button title.",
    )

    static let webAppOperationFailedTitle = NSLocalizedString(
        "browser.web_app.operation_failed.title",
        comment: "Title of an alert shown when a web app operation fails.",
    )

    static let webAppUninstallPromptTitle = NSLocalizedString(
        "browser.web_app.uninstall_prompt.title",
        comment: "Title of the web app uninstall confirmation alert.",
    )

    static let webAppUninstallButton = NSLocalizedString(
        "browser.web_app.uninstall_prompt.uninstall",
        comment: "Confirmation button in the web app uninstall alert.",
    )

    static let webAppInfoInstalledWith = NSLocalizedString(
        "browser.web_app.info.installed_with",
        comment: "Footer in web app information identifying OpenArc.",
    )

    static let webAppInfoDoneAction = NSLocalizedString(
        "browser.web_app.info.done_action",
        comment: "Button closing the web app information alert.",
    )

    static let webAppErrorApplicationsDirectoryUnavailable = NSLocalizedString(
        "browser.web_app.error.applications_directory_unavailable",
        comment: "Error shown when the user's Applications directory is unavailable.",
    )

    static let webAppErrorInvalidHostBundle = NSLocalizedString(
        "browser.web_app.error.invalid_host_bundle",
        comment: "Error shown when OpenArc's host app bundle is invalid.",
    )

    static let webAppErrorInvalidName = NSLocalizedString(
        "browser.web_app.error.invalid_name",
        comment: "Error shown when a web app name is invalid.",
    )

    static let webAppErrorMissingHostExecutable = NSLocalizedString(
        "browser.web_app.error.missing_host_executable",
        comment: "Error shown when OpenArc's executable is unavailable for a web app shim.",
    )

    static let webAppErrorMissingLauncherExecutable = NSLocalizedString(
        "browser.web_app.error.missing_launcher_executable",
        comment: "Error shown when OpenArc's dedicated web app launcher is unavailable.",
    )

    static let webAppErrorUnsupportedURL = NSLocalizedString(
        "browser.web_app.error.unsupported_url",
        comment: "Error shown when a page cannot be installed as a web app.",
    )

    static let quitShortcutTitle = NSLocalizedString(
        "browser.menu.quit_shortcut_title",
        comment: "Conflict title for the system quit shortcut.",
    )

    static let sidebarClearTemporaryTabs = NSLocalizedString(
        "browser.sidebar.clear_temporary_tabs",
        comment: "Button title for clearing temporary tabs.",
    )

    static let sidebarClearTemporaryTabsTooltip = NSLocalizedString(
        "browser.sidebar.clear_temporary_tabs_tooltip",
        comment: "Tooltip shown for clearing temporary tabs.",
    )

    static let tabMoveToNewWindowAction = NSLocalizedString(
        "browser.tab.move_to_new_window_action",
        comment: "Undo name after tabs were dragged out of the window into a new one.",
    )
    static let menuEnterFullScreen = NSLocalizedString(
        "browser.menu.enter_full_screen",
        comment: "View menu item that puts the window in full screen.",
    )
    static let menuExitFullScreen = NSLocalizedString(
        "browser.menu.exit_full_screen",
        comment: "The View menu's full screen item while the window is in full screen.",
    )
    static let menuCloseTab = NSLocalizedString(
        "browser.menu.close_tab",
        comment: "File menu item for Command-W, which archives the shown tab.",
    )
    static let movedPageShowHere = NSLocalizedString(
        "browser.content.moved_page_show_here",
        comment: "Accessibility label of a faded picture of a page another window shows; a click brings it back.",
    )
    static let tabArchiveAction = NSLocalizedString(
        "browser.tab.archive_action",
        comment: "Context menu title for archiving a tab.",
    )

    static let splitRenameAction = NSLocalizedString(
        "browser.split.rename_action",
        comment: "Split View row menu item and prompt title that names the split.",
    )

    static let splitChangeIconAction = NSLocalizedString(
        "browser.split.change_icon_action",
        comment: "Split View row menu submenu that picks the split's icon.",
    )

    static let splitArchiveAction = NSLocalizedString(
        "browser.split.archive_action",
        comment: "Split View row menu item that archives every pane of the split.",
    )

    static let tabMenuMuteAction = NSLocalizedString(
        "browser.tab.menu_mute_action",
        comment: "Tab row menu item that silences the tab.",
    )
    static let tabMenuUnmuteAction = NSLocalizedString(
        "browser.tab.menu_unmute_action",
        comment: "Tab row menu item that lets a silenced tab play sound again.",
    )
    static let tabMuteAction = NSLocalizedString(
        "browser.tab.mute_action",
        comment: "Context menu title that silences a tab.",
    )

    static let sadTabMessage = NSLocalizedString(
        "browser.sad_tab.message",
        comment: "Shown over a page whose renderer crashed. %@ is the link that reloads it, browser.sad_tab.reload.",
    )

    static let sadTabReloadLink = NSLocalizedString(
        "browser.sad_tab.reload",
        comment: "The link in browser.sad_tab.message that reloads the crashed page.",
    )

    static let sadTabErrorCode = NSLocalizedString(
        "browser.sad_tab.error_code",
        comment: "Below the crash message: Chromium's error code for the crash.",
    )

    static let miniPlayerBackToTab = NSLocalizedString(
        "browser.mini_player.back_to_tab",
        comment: "Tooltip of the mini player's tab icon, which shows the tab playing the media.",
    )

    static let miniPlayerPreviousTrack = NSLocalizedString(
        "browser.mini_player.previous_track",
        comment: "Mini player button that plays the previous track.",
    )

    static let miniPlayerNextTrack = NSLocalizedString(
        "browser.mini_player.next_track",
        comment: "Mini player button that plays the next track.",
    )

    static let miniPlayerPlay = NSLocalizedString(
        "browser.mini_player.play",
        comment: "Mini player button that resumes paused media.",
    )

    static let miniPlayerPause = NSLocalizedString(
        "browser.mini_player.pause",
        comment: "Mini player button that pauses the media.",
    )

    static let miniPlayerClose = NSLocalizedString(
        "browser.mini_player.close",
        comment: "Mini player button that hides it; the media keeps playing.",
    )

    static let tabUnmuteAction = NSLocalizedString(
        "browser.tab.unmute_action",
        comment: "Context menu and button title that lets a muted tab play sound again.",
    )

    static let tabDuplicateAction = NSLocalizedString(
        "browser.tab.duplicate_action",
        comment: "Context menu title that opens a copy of the tab below it.",
    )

    static let tabMoveToSpaceAction = NSLocalizedString(
        "browser.tab.move_to_space_action",
        comment: "Context menu submenu title listing the Spaces a tab can move to.",
    )

    static let tabArchiveOtherTabsAction = NSLocalizedString(
        "browser.tab.archive_other_tabs_action",
        comment: "Context menu title for archiving the other temporary tabs of the Space.",
    )

    static let tabArchiveTabsAboveAction = NSLocalizedString(
        "browser.tab.archive_tabs_above_action",
        comment: "Context menu title for archiving the temporary tabs above the current tab.",
    )

    static let tabArchiveTabsBelowAction = NSLocalizedString(
        "browser.tab.archive_tabs_below_action",
        comment: "Context menu title for archiving tabs below the current tab.",
    )

    static let tabArchiveTooltip = NSLocalizedString(
        "browser.tab.archive_tooltip",
        comment: "Tooltip shown for archiving a tab.",
    )

    static let tabCloseAction = NSLocalizedString(
        "browser.tab.close_action",
        comment: "Context menu title for closing a tab.",
    )

    static let appTabRemoveFavoriteAction = NSLocalizedString(
        "browser.app_tab.remove_favorite_action",
        comment: "Context menu title for removing an app tab from favorites.",
    )

    static let tabCopyLinkAction = NSLocalizedString(
        "browser.tab.copy_link_action",
        comment: "Menu item title for copying a tab link.",
    )

    static let tabCopyURLAction = NSLocalizedString(
        "browser.tab.copy_url_action",
        comment: "Tooltip title for copying the current page URL.",
    )

    static let siteControlCenterAction = NSLocalizedString(
        "browser.site_control_center.action",
        comment: "Tooltip title for opening the current site's controls.",
    )

    static let menuCaptureArea = NSLocalizedString(
        "browser.menu.capture_area",
        comment: "File menu and command title that lets the user outline part of the page to copy as an image.",
    )

    static let captureAreaAccessibilityLabel = NSLocalizedString(
        "browser.capture_area.accessibility",
        comment: "Accessibility label of the overlay where the user outlines part of the page to capture.",
    )

    static let siteCaptureFullPageAction = NSLocalizedString(
        "browser.site.capture_full_page",
        comment: "Context menu item for capturing the full current page to the pasteboard.",
    )

    static let siteShowAsToolbarAction = NSLocalizedString(
        "browser.site.show_as_toolbar",
        comment: "Context menu item for showing the URL row as a toolbar.",
    )

    static let siteShowInSidebarAction = NSLocalizedString(
        "browser.site.show_in_sidebar",
        comment: "Context menu item for moving the URL toolbar back into the sidebar.",
    )

    static let siteShowFullURLAction = NSLocalizedString(
        "browser.site.show_full_url",
        comment: "Context menu item for showing the full URL in the URL toolbar.",
    )

    static let siteHideFullURLAction = NSLocalizedString(
        "browser.site.hide_full_url",
        comment: "Context menu item for hiding the full URL in the URL toolbar.",
    )

    static let extensionsSectionTitle = NSLocalizedString(
        "browser.extensions.section.title",
        comment: "Section title for extensions in the site control center popover.",
    )

    static let extensionsManageAction = NSLocalizedString(
        "browser.extensions.manage",
        comment: "Button title for opening the extensions management page.",
    )

    static let extensionsAddAction = NSLocalizedString(
        "browser.extensions.add",
        comment: "Accessibility title for adding an extension.",
    )

    static let extensionsCloseSidePanel = NSLocalizedString(
        "browser.extensions.close_side_panel",
        comment: "Tooltip title for closing an extension side panel.",
    )

    static let extensionsSiteAccessMenu = NSLocalizedString(
        "browser.extensions.site_access.menu",
        comment: "Context menu title for extension site access controls.",
    )

    static let extensionsSiteAccessOnClick = NSLocalizedString(
        "browser.extensions.site_access.on_click",
        comment: "Context menu item for extension access when clicked.",
    )

    static let extensionsSiteAccessCurrentSite = NSLocalizedString(
        "browser.extensions.site_access.current_site",
        comment: "Context menu item for extension access on the current site; receives the host name.",
    )

    static let extensionsSiteAccessAllSites = NSLocalizedString(
        "browser.extensions.site_access.all_sites",
        comment: "Context menu item for extension access on all sites.",
    )

    static let extensionsSiteAccessLearnMore = NSLocalizedString(
        "browser.extensions.site_access.learn_more",
        comment: "Context menu item for learning about extension site access.",
    )

    static let extensionsRemoveFromOpenArc = NSLocalizedString(
        "browser.extensions.remove_from_openarc",
        comment: "Context menu item for removing an extension from OpenArc.",
    )

    static let extensionsPinAction = NSLocalizedString(
        "browser.extensions.pin",
        comment: "Context menu item for pinning an extension.",
    )

    static let extensionsUnpinAction = NSLocalizedString(
        "browser.extensions.unpin",
        comment: "Context menu item for unpinning an extension.",
    )

    static let extensionsManageExtension = NSLocalizedString(
        "browser.extensions.manage_extension",
        comment: "Context menu item for opening an extension's details page.",
    )

    static let extensionsViewWebPermissions = NSLocalizedString(
        "browser.extensions.view_web_permissions",
        comment: "Context menu item for opening extension web permissions.",
    )

    static let extensionsInspectPopup = NSLocalizedString(
        "browser.extensions.inspect_popup",
        comment: "Context menu item for inspecting an extension popup.",
    )

    static let tabRenameAction = NSLocalizedString(
        "browser.tab.rename_action",
        comment: "Context menu title for renaming a tab.",
    )

    static let tabRenamePromptTitle = NSLocalizedString(
        "browser.tab.rename_prompt.title",
        comment: "Prompt title for renaming an icon-only tab.",
    )

    static let tabChangeIconAction = NSLocalizedString(
        "browser.tab.change_icon_action",
        comment: "Tab menu submenu that shows a symbol in place of the tab's site icon.",
    )

    static let tabSiteIconAction = NSLocalizedString(
        "browser.tab.site_icon_action",
        comment: "Change Icon submenu item that goes back to the tab's site icon.",
    )

    static let tabShareAction = NSLocalizedString(
        "browser.tab.share_action",
        comment: "Context menu title for sharing a tab.",
    )

    static let tabRenameTooltipCaption = NSLocalizedString(
        "browser.tab.rename_tooltip_caption",
        comment: "Caption shown under the tab title tooltip.",
    )

    static let settingsTemporaryTabsTitle = NSLocalizedString(
        "browser.settings.temporary_tabs.title",
        comment: "Title for the temporary tab settings section.",
    )

    static let settingsGeneralTab = NSLocalizedString(
        "browser.settings.general",
        comment: "Title for the general settings tab.",
    )

    static let settingsWindowTitle = NSLocalizedString(
        "browser.settings.window_title",
        comment: "Title for the settings window.",
    )

    static let settingsAccountsTab = NSLocalizedString(
        "browser.settings.accounts",
        comment: "Title for the accounts settings tab.",
    )

    static let settingsAccountsSignInTitle = NSLocalizedString(
        "browser.settings.accounts.sign_in_title",
        comment: "Title of the Accounts settings card when no account is signed in.",
    )
    static let settingsAccountsSignInDetail = NSLocalizedString(
        "browser.settings.accounts.sign_in_detail",
        comment: "What an account does, under the Accounts settings sign-in title.",
    )
    static let settingsAccountsOr = NSLocalizedString(
        "browser.settings.accounts.or",
        comment: "Divider between the sign-in buttons and email sign-in.",
    )
    static let settingsDefaultBrowserSection = NSLocalizedString(
        "browser.settings.default_browser_section",
        comment: "Settings section with the default browser control.",
    )
    static let settingsAccountsEmpty = NSLocalizedString(
        "browser.settings.accounts.empty",
        comment: "Empty state text for accounts.",
    )

    static let syncAccountSignOut = NSLocalizedString(
        "browser.sync.account.sign_out",
        comment: "Button title for signing out of sync.",
    )

    static let syncAccountSignedIn = NSLocalizedString(
        "browser.sync.account.signed_in",
        comment: "Fallback title for a signed-in sync account.",
    )

    static let syncAccountServerNotConfigured = NSLocalizedString(
        "browser.sync.account.server_not_configured",
        comment: "Message shown when sync is disabled because no server URL is configured.",
    )

    static let syncAccountEnable = NSLocalizedString(
        "browser.sync.account.enable",
        comment: "Enable profile sync button.",
    )
    static let syncAccountEnableDetail = NSLocalizedString(
        "browser.sync.account.enable_detail",
        comment: "Consent to sync this profile.",
    )
    static let syncAccountSyncSidebar = NSLocalizedString(
        "browser.sync.account.sync_sidebar",
        comment: "Switch that syncs the profile's Spaces and tabs with the account.",
    )
    static let syncAccountSyncing = NSLocalizedString(
        "browser.sync.account.syncing",
        comment: "Sync status before the first sync of this run.",
    )
    static let syncAccountPaused = NSLocalizedString(
        "browser.sync.account.paused",
        comment: "Sync status while the Sync Sidebar switch is off.",
    )
    static let syncAccountDifferentOwner = NSLocalizedString(
        "browser.sync.account.different_owner",
        comment: "Sync profile belongs to another account.",
    )
    static let syncAccountSignInAgain = NSLocalizedString(
        "browser.sync.account.sign_in_again",
        comment: "Credentials need fresh sign-in.",
    )
    static let syncAccountUnavailable = NSLocalizedString(
        "browser.sync.account.unavailable",
        comment: "Durable sync store unavailable.",
    )

    static let syncAccountContinueWithApple = NSLocalizedString(
        "browser.sync.account.continue_with_apple",
        comment: "Button title for signing into sync with Apple on the web.",
    )

    static let syncAccountContinueWithGoogle = NSLocalizedString(
        "browser.sync.account.continue_with_google",
        comment: "Button title for signing into sync with Google.",
    )

    static let syncAccountContinueWithGitHub = NSLocalizedString(
        "browser.sync.account.continue_with_github",
        comment: "Button title for signing into sync with GitHub.",
    )

    static let syncAccountEmailPlaceholder = NSLocalizedString(
        "browser.sync.account.email_placeholder",
        comment: "Placeholder of the email field for signing in with a code.",
    )

    static let syncAccountSendCode = NSLocalizedString(
        "browser.sync.account.send_code",
        comment: "Button title that emails a sign-in code.",
    )

    static let syncAccountCodePlaceholder = NSLocalizedString(
        "browser.sync.account.code_placeholder",
        comment: "Placeholder of the sign-in code field.",
    )

    static let syncAccountSignInWithCode = NSLocalizedString(
        "browser.sync.account.sign_in_with_code",
        comment: "Button title that signs in with the emailed code.",
    )

    static let syncAccountSendAgain = NSLocalizedString(
        "browser.sync.account.send_again",
        comment: "Button title that emails another sign-in code.",
    )

    static let syncAccountUseDifferentEmail = NSLocalizedString(
        "browser.sync.account.use_different_email",
        comment: "Button title that goes back to entering an email.",
    )

    static let syncAccountLoadProviders = NSLocalizedString(
        "browser.sync.account.load_providers",
        comment: "Button title that asks the server for its sign-in methods again.",
    )

    static let syncAccountMethodUnavailable = NSLocalizedString(
        "browser.sync.account.method_unavailable",
        comment: "Error when the server is not configured for a sign-in method.",
    )

    static let syncAccountTooManyRequests = NSLocalizedString(
        "browser.sync.account.too_many_requests",
        comment: "Error when the server rate-limits sign-in.",
    )

    static let syncAccountInvalidEmail = NSLocalizedString(
        "browser.sync.account.invalid_email",
        comment: "Error for an email the server cannot send a code to.",
    )

    static let syncAccountInvalidCode = NSLocalizedString(
        "browser.sync.account.invalid_code",
        comment: "Error for a wrong or expired emailed sign-in code.",
    )

    static let syncAccountSignInExpired = NSLocalizedString(
        "browser.sync.account.sign_in_expired",
        comment: "Error when a web sign-in took too long.",
    )

    static let syncAccountProviderFailed = NSLocalizedString(
        "browser.sync.account.provider_failed",
        comment: "Error when a sign-in provider failed.",
    )

    static let syncAccountDelete = NSLocalizedString(
        "browser.sync.account.delete",
        comment: "Button that starts deleting the sync account.",
    )

    static let syncAccountDeleteDetail = NSLocalizedString(
        "browser.sync.account.delete_detail",
        comment: "What Delete Account does, next to its button.",
    )

    static let syncAccountDeleteTitle = NSLocalizedString(
        "browser.sync.account.delete_title",
        comment: "Title of the account deletion confirmation.",
    )

    static let syncAccountDeleteMessage = NSLocalizedString(
        "browser.sync.account.delete_message",
        comment: "What account deletion removes and what stays on the Mac.",
    )

    static let syncAccountDeleteClearBrowsingData = NSLocalizedString(
        "browser.sync.account.delete_clear_browsing_data",
        comment: "Checkbox that opens Clear Browsing Data after the account is deleted.",
    )

    static let syncAccountDeleteConfirm = NSLocalizedString(
        "browser.sync.account.delete_confirm",
        comment: "Destructive button that confirms account deletion.",
    )

    static let syncAccountDeleteCancel = NSLocalizedString(
        "browser.sync.account.delete_cancel",
        comment: "Button that keeps the account.",
    )

    static let syncAccountDeleting = NSLocalizedString(
        "browser.sync.account.deleting",
        comment: "Status while the server deletes the account.",
    )

    static let syncAccountDeletedTitle = NSLocalizedString(
        "browser.sync.account.deleted_title",
        comment: "Title shown after the account is deleted.",
    )

    static let syncAccountDeletedMessage = NSLocalizedString(
        "browser.sync.account.deleted_message",
        comment: "Message shown after the account is deleted.",
    )

    static let syncAccountDeleteOffline = NSLocalizedString(
        "browser.sync.account.delete_offline",
        comment: "Error when account deletion cannot reach the server.",
    )

    static let syncAccountDeleteSignInAgain = NSLocalizedString(
        "browser.sync.account.delete_sign_in_again",
        comment: "Error when the access token is no longer valid for account deletion.",
    )

    static let syncAccountDeleteFailed = NSLocalizedString(
        "browser.sync.account.delete_failed",
        comment: "Error when the server fails to delete the account.",
    )

    static let settingsAutomaticUpdates = NSLocalizedString(
        "browser.settings.general.automatic_updates",
        comment: "Automatic updates setting title.",
    )

    static let settingsAutomaticUpdatesDetail = NSLocalizedString(
        "browser.settings.general.automatic_updates.detail",
        comment: "Automatic updates row detail.",
    )

    static let settingsUpdateChannel = NSLocalizedString(
        "browser.settings.general.update_channel",
        comment: "Update channel setting title.",
    )

    static let settingsUpdateChannelDetail = NSLocalizedString(
        "browser.settings.general.update_channel.detail",
        comment: "Update channel setting detail.",
    )

    static let updateChannelStable = NSLocalizedString(
        "browser.updates.channel.stable",
        comment: "Stable update channel title.",
    )

    static let updateChannelBeta = NSLocalizedString(
        "browser.updates.channel.beta",
        comment: "Beta update channel title.",
    )

    static let updateReadyTitle = NSLocalizedString(
        "browser.updates.ready.title",
        comment: "Title shown when an update has been downloaded.",
    )

    static let updateRestartAction = NSLocalizedString(
        "browser.updates.restart_action",
        comment: "Button title for installing a downloaded update immediately.",
    )

    static let updateFailedTitle = NSLocalizedString(
        "browser.updates.failed.title",
        comment: "Title shown when a downloaded update could not be installed.",
    )

    static let updateDownloadAction = NSLocalizedString(
        "browser.updates.download_action",
        comment: "Button title for downloading an update that could not be installed, to install it by hand.",
    )

    static let settingsAppearance = NSLocalizedString(
        "browser.settings.general.appearance",
        comment: "Appearance setting title.",
    )

    static let settingsAppearanceDetail = NSLocalizedString(
        "browser.settings.general.appearance.detail",
        comment: "Appearance setting detail.",
    )

    static let settingsAppearanceSystem = NSLocalizedString(
        "browser.settings.general.appearance.system",
        comment: "Appearance setting option that follows the system appearance.",
    )

    static let settingsAppearanceLight = NSLocalizedString(
        "browser.settings.general.appearance.light",
        comment: "Appearance setting option that forces the light appearance.",
    )

    static let settingsAppearanceDark = NSLocalizedString(
        "browser.settings.general.appearance.dark",
        comment: "Appearance setting option that forces the dark appearance.",
    )

    static let settingsWarnBeforeQuitting = NSLocalizedString(
        "browser.settings.general.warn_before_quitting",
        comment: "Warn before quitting setting title.",
    )

    static let settingsBlurredBackground = NSLocalizedString(
        "browser.settings.general.blurred_background",
        comment: "Blurred browser background setting title.",
    )

    static let settingsBatterySaver = NSLocalizedString(
        "browser.settings.general.battery_saver",
        comment: "Battery Saver setting title.",
    )

    static let settingsBatterySaverDetail = NSLocalizedString(
        "browser.settings.general.battery_saver.detail",
        comment: "Battery Saver setting description.",
    )

    static let settingsProfilesTab = NSLocalizedString(
        "browser.settings.profiles",
        comment: "Title for the profiles settings tab.",
    )

    static let settingsProfilesIntro = NSLocalizedString(
        "browser.settings.profiles.intro",
        comment: "Intro copy for profiles.",
    )

    static let settingsDefaultProfile = NSLocalizedString(
        "browser.settings.profiles.default_profile",
        comment: "Default profile title.",
    )

    static let settingsDefaultProfileDetail = NSLocalizedString(
        "browser.settings.profiles.default_profile.detail",
        comment: "Default profile detail.",
    )

    static let settingsCurrentProfile = NSLocalizedString(
        "browser.settings.profiles.current_profile",
        comment: "Label for the profile used by the current browser window.",
    )

    static let settingsOpenProfile = NSLocalizedString(
        "browser.settings.profiles.open_profile",
        comment: "Button title for opening a browser window with a profile.",
    )

    static let settingsNewProfile = NSLocalizedString(
        "browser.settings.profiles.new_profile",
        comment: "Button title for creating a new browser profile.",
    )

    static let settingsBackUpProfile = NSLocalizedString(
        "browser.settings.profiles.back_up",
        comment: "Button title for creating a backup archive of a browser profile.",
    )

    static let settingsDeleteProfile = NSLocalizedString(
        "browser.settings.profiles.delete",
        comment: "Button title for deleting a browser profile.",
    )

    static let settingsDefaultBrowserPrompt = NSLocalizedString(
        "browser.settings.default_browser.prompt",
        comment: "Settings row title prompting the user to set OpenArc as default.",
    )

    static let settingsDefaultBrowserAction = NSLocalizedString(
        "browser.settings.default_browser.action",
        comment: "Settings row button title for setting OpenArc as default.",
    )

    static let settingsSearch = NSLocalizedString(
        "browser.settings.search",
        comment: "Search settings section title.",
    )

    static let settingsSearchEngine = NSLocalizedString(
        "browser.settings.search_engine",
        comment: "Search engine setting title.",
    )

    static let settingsSearchEngineGoogle = NSLocalizedString(
        "browser.settings.search_engine.google",
        comment: "Google search engine picker title.",
    )

    static let settingsSearchEngineMicrosoftBing = NSLocalizedString(
        "browser.settings.search_engine.microsoft_bing",
        comment: "Microsoft Bing search engine picker title.",
    )

    static let settingsSearchEngineYahoo = NSLocalizedString(
        "browser.settings.search_engine.yahoo",
        comment: "Yahoo search engine picker title.",
    )

    static let settingsSearchEngineDuckDuckGo = NSLocalizedString(
        "browser.settings.search_engine.duckduckgo",
        comment: "DuckDuckGo search engine picker title.",
    )

    static let settingsSearchEngineEcosia = NSLocalizedString(
        "browser.settings.search_engine.ecosia",
        comment: "Ecosia search engine picker title.",
    )

    static let settingsSearchEngineBrave = NSLocalizedString(
        "browser.settings.search_engine.brave",
        comment: "Brave Search engine picker title.",
    )

    static let settingsSearchEngineQwant = NSLocalizedString(
        "browser.settings.search_engine.qwant",
        comment: "Qwant search engine picker title.",
    )

    static let settingsSearchEngineYandex = NSLocalizedString(
        "browser.settings.search_engine.yandex",
        comment: "Yandex search engine picker title.",
    )

    static let settingsSearchEngineBaidu = NSLocalizedString(
        "browser.settings.search_engine.baidu",
        comment: "Baidu search engine picker title.",
    )

    static let settingsManageSearch = NSLocalizedString(
        "browser.settings.manage_search",
        comment: "Manage search button title.",
    )

    static let settingsSearchSuggestions = NSLocalizedString(
        "browser.settings.search_suggestions",
        comment: "Search engine suggestions toggle title.",
    )

    static let settingsAISearchProvider = NSLocalizedString(
        "browser.settings.ai_search_provider",
        comment: "AI provider picker title.",
    )

    static let settingsAISearchProviderChatGPT = NSLocalizedString(
        "browser.settings.ai_search_provider.chatgpt",
        comment: "ChatGPT AI provider picker title.",
    )

    static let settingsAISearchProviderClaude = NSLocalizedString(
        "browser.settings.ai_search_provider.claude",
        comment: "Claude AI provider picker title.",
    )

    static let settingsAISearchProviderGemini = NSLocalizedString(
        "browser.settings.ai_search_provider.gemini",
        comment: "Gemini AI provider picker title.",
    )

    static let settingsAISearchProviderPerplexity = NSLocalizedString(
        "browser.settings.ai_search_provider.perplexity",
        comment: "Perplexity AI provider picker title.",
    )

    static let settingsAISearchProviderDeepSeek = NSLocalizedString(
        "browser.settings.ai_search_provider.deepseek",
        comment: "DeepSeek AI provider picker title.",
    )

    static let settingsPrivacyAndSecurity = NSLocalizedString(
        "browser.settings.profiles.privacy_and_security",
        comment: "Privacy and security settings link title.",
    )

    static let settingsPasswords = NSLocalizedString(
        "browser.settings.profiles.passwords",
        comment: "Passwords settings link title.",
    )

    static let settingsNotifications = NSLocalizedString(
        "browser.settings.profiles.notifications",
        comment: "Notifications settings link title.",
    )

    static let settingsClearBrowsingData = NSLocalizedString(
        "browser.settings.profiles.clear_browsing_data",
        comment: "Clear browsing data settings link title.",
    )

    static let settingsShortcutsTab = NSLocalizedString(
        "browser.settings.shortcuts",
        comment: "Title for the shortcuts settings tab.",
    )

    static let settingsShortcutsSearchPlaceholder = NSLocalizedString(
        "browser.settings.shortcuts.search_placeholder",
        comment: "Placeholder for the shortcut search field.",
    )

    static let settingsShortcutRecord = NSLocalizedString(
        "browser.settings.shortcuts.record",
        comment: "Button title for recording a shortcut.",
    )

    static let settingsShortcutReset = NSLocalizedString(
        "browser.settings.shortcuts.reset",
        comment: "Button title for resetting one shortcut.",
    )

    static let settingsShortcutResetAll = NSLocalizedString(
        "browser.settings.shortcuts.reset_all",
        comment: "Button title for resetting all shortcuts.",
    )

    static let settingsShortcutPressShortcut = NSLocalizedString(
        "browser.settings.shortcuts.press_shortcut",
        comment: "Prompt shown while recording a shortcut.",
    )

    static let settingsShortcutNotSet = NSLocalizedString(
        "browser.settings.shortcuts.not_set",
        comment: "Displayed when a command has no keyboard shortcut.",
    )

    static let settingsExtensionShortcuts = NSLocalizedString(
        "browser.settings.shortcuts.extension_shortcuts",
        comment: "Button title for opening extension shortcut settings.",
    )

    static let settingsLinksTab = NSLocalizedString(
        "browser.settings.links_tab",
        comment: "Settings pane for the small window, Peek and rules for links from other apps.",
    )

    static let settingsSmallWindowSection = NSLocalizedString(
        "browser.settings.small_window_section",
        comment: "Settings section title for the small window of its own.",
    )

    static let settingsPeekSection = NSLocalizedString(
        "browser.settings.peek_section",
        comment: "Settings section title for Peek, the floating card for links.",
    )

    static let settingsAdvancedTab = NSLocalizedString(
        "browser.settings.advanced",
        comment: "Settings pane with advanced options.",
    )

    static let settingsYourData = NSLocalizedString(
        "browser.settings.your_data",
        comment: "Settings section with links to a profile's data.",
    )

    static let settingsToolbarFullURL = NSLocalizedString(
        "browser.settings.toolbar_full_url",
        comment: "Toggle: show the full address in the toolbar.",
    )

    static let settingsShareThemeWithWebsites = NSLocalizedString(
        "browser.settings.share_theme_with_websites",
        comment: "Toggle: websites can read the Space's colors.",
    )

    static let settingsExportData = NSLocalizedString(
        "browser.settings.export_data",
        comment: "Button that saves a copy of the tabs and Spaces.",
    )

    static let settingsExportDataDetail = NSLocalizedString(
        "browser.settings.export_data.detail",
        comment: "Label beside the button that saves a copy of the tabs and Spaces.",
    )

    static let settingsHapticFeedback = NSLocalizedString(
        "browser.settings.content.haptic_feedback",
        comment: "Haptic feedback toggle title.",
    )

    static let settingsRestoreWindows = NSLocalizedString(
        "browser.settings.content.restore_windows",
        comment: "Restore windows setting title.",
    )

    static let settingsPictureInPicture = NSLocalizedString(
        "browser.settings.content.picture_in_picture",
        comment: "Picture in Picture setting title.",
    )

    static let settingsWindowDraggingFromPageTop = NSLocalizedString(
        "browser.settings.content.window_dragging_from_page_top",
        comment: "Setting that lets the top of web pages move the window when dragged.",
    )

    static let settingsShowBookmarksBar = NSLocalizedString(
        "browser.settings.content.show_bookmarks_bar",
        comment: "Show bookmarks bar setting title.",
    )

    static let settingsMoreSettings = NSLocalizedString(
        "browser.settings.content.more_settings",
        comment: "More settings button title.",
    )

    static let settingsTranslateSitePrompts = NSLocalizedString(
        "browser.settings.content.translate_site_prompts",
        comment: "Translate site prompts button title.",
    )

    static let settingsQuitWarningTitle = NSLocalizedString(
        "browser.settings.quit_warning.title",
        comment: "Quit warning alert title.",
    )

    static let settingsQuitWarningMessage = NSLocalizedString(
        "browser.settings.quit_warning.message",
        comment: "Quit warning alert message.",
    )

    static let settingsQuitWarningQuit = NSLocalizedString(
        "browser.settings.quit_warning.quit",
        comment: "Quit button title in quit warning alert.",
    )

    static let settingsQuitWarningCancel = NSLocalizedString(
        "browser.settings.quit_warning.cancel",
        comment: "Cancel button title in quit warning alert.",
    )

    static let settingsTemporaryTabsDescription = NSLocalizedString(
        "browser.settings.temporary_tabs.description",
        comment: "Description for the temporary tab settings section.",
    )

    static let settingsTemporaryTabsLifetimeLabel = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime_label",
        comment: "Label for the temporary tab archival lifetime picker.",
    )

    static let settingsLifetimeTwelveHours = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.12h",
        comment: "Option title for archiving temporary tabs after 12 hours.",
    )

    static let settingsAutomaticArchivalNever = NSLocalizedString(
        "browser.settings.automatic_archival.never",
        comment: "Temporary tab lifetime option that never archives tabs automatically.",
    )
    static let settingsAutomaticArchivalOff = NSLocalizedString(
        "browser.settings.automatic_archival.off",
        comment: "Disable automatic archiving for this synchronized profile.",
    )
    static let settingsAutomaticArchivalThirtyDays = NSLocalizedString(
        "browser.settings.automatic_archival.30d",
        comment: "Thirty days without the local-only Default label; synced profiles default to Off.",
    )
    static let settingsAutomaticArchivalSyncDescription = NSLocalizedString(
        "browser.settings.automatic_archival.sync_description",
        comment: "Synchronized automatic archive behavior and recovery entry point.",
    )
    static let settingsTemporaryTabsSyncUnavailable = NSLocalizedString(
        "browser.settings.temporary_tabs.sync_unavailable",
        comment: "Explains why automatic archiving is disabled for synchronized desktop profiles.",
    )

    static let settingsTemporaryTabsSaveFailed = NSLocalizedString(
        "browser.settings.temporary_tabs.save_failed",
        comment: "Archive timing preference could not be saved.",
    )

    static let settingsTemporaryTabsLoadFailed = NSLocalizedString(
        "browser.settings.temporary_tabs.load_failed",
        comment: "Automatic archive settings could not be read.",
    )

    static let settingsLifetimeTwentyFourHours = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.24h",
        comment: "Option title for archiving temporary tabs after 24 hours.",
    )

    static let settingsLifetimeSevenDays = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.7d",
        comment: "Option title for archiving temporary tabs after 7 days.",
    )

    static let settingsLifetimeThreeDays = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.3d",
        comment: "Option title for archiving temporary tabs after 3 days.",
    )

    static let settingsLifetimeThirtyDays = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.30d",
        comment: "Option title for archiving temporary tabs after 30 days.",
    )

    static let notificationPermissionTitle = NSLocalizedString(
        "browser.permissions.notifications.title",
        comment: "Notification permission prompt title.",
    )

    static let notificationPermissionAllow = NSLocalizedString(
        "browser.permissions.allow",
        comment: "Allow button title for notification permissions.",
    )

    static let notificationPermissionDontAllow = NSLocalizedString(
        "browser.permissions.dont_allow",
        comment: "Don't Allow button title for notification permissions.",
    )

    static let menuHideOthers = NSLocalizedString(
        "browser.menu.hide_others",
        comment: "App menu item that hides the other apps.",
    )

    static let menuShowAll = NSLocalizedString(
        "browser.menu.show_all",
        comment: "App menu item that shows every hidden app.",
    )

    static let menuServices = NSLocalizedString(
        "browser.menu.services",
        comment: "App menu title of the system Services submenu.",
    )

    static let menuWindow = NSLocalizedString(
        "browser.menu.window",
        comment: "Title of the Window menu.",
    )

    static let menuMinimize = NSLocalizedString(
        "browser.menu.minimize",
        comment: "Window menu item that minimizes the front window.",
    )

    static let menuZoom = NSLocalizedString(
        "browser.menu.zoom",
        comment: "Window menu item that zooms the front window.",
    )

    static let windowFullScreenButton = NSLocalizedString(
        "browser.window.full_screen_button",
        comment: "Accessibility name of the green window button, which enters or leaves full screen.",
    )

    static let menuBringAllToFront = NSLocalizedString(
        "browser.menu.bring_all_to_front",
        comment: "Window menu item that brings every app window to the front.",
    )

    static let onboardingProfiles = NSLocalizedString(
        "browser.onboarding.profiles",
        comment: "First-run welcome window: heads the checkboxes that pick which profiles of a browser to import.",
    )

    static let onboardingSafariExportHint = NSLocalizedString(
        "browser.onboarding.safari_export_hint",
        comment: "First-run welcome window: how to export Safari's data for import.",
    )

    static let onboardingChooseSafariExport = NSLocalizedString(
        "browser.onboarding.choose_safari_export",
        comment: "First-run welcome window: opens a file panel for Safari's exported ZIP.",
    )

    static let onboardingChooseAnother = NSLocalizedString(
        "browser.onboarding.choose_another",
        comment: "First-run welcome window: picks a different Safari export.",
    )

    static let onboardingTryAgain = NSLocalizedString(
        "browser.onboarding.try_again",
        comment: "First-run welcome window: retries an import that brought nothing.",
    )

    static let menuBoostThisSite = NSLocalizedString(
        "browser.menu.boost_this_site",
        comment: "View menu and command: open the Boost editor for the current site, which has no Boost yet.",
    )
    static let menuEditBoost = NSLocalizedString(
        "browser.menu.edit_boost",
        comment: "View menu: open the current site's Boost editor.",
    )
    static let menuViewBoosts = NSLocalizedString(
        "browser.menu.view_boosts",
        comment: "Command and menu: open the Library's Boosts.",
    )
    static let boostNewMenu = NSLocalizedString(
        "browser.boost.new_menu",
        comment: "Sidebar plus menu: open the Boost editor for the current site.",
    )
    static let boostDefaultTitle = NSLocalizedString(
        "browser.boost.default_title",
        comment: "Name of a Boost the user has not renamed.",
    )
    static let boostEditorTitle = NSLocalizedString(
        "browser.boost_editor.title",
        comment: "Accessibility title of the Boost editor panel.",
    )
    static let boostEditorClose = NSLocalizedString(
        "browser.boost_editor.close",
        comment: "Boost editor: button that closes the editor.",
    )
    static let boostEditorUndo = NSLocalizedString(
        "browser.boost_editor.undo",
        comment: "Boost editor: button that takes back the last change.",
    )
    static let boostEditorRename = NSLocalizedString(
        "browser.boost_editor.rename",
        comment: "Boost editor title menu: rename the Boost.",
    )
    static let boostEditorResetAll = NSLocalizedString(
        "browser.boost_editor.reset_all",
        comment: "Boost editor title menu: undo every change of the Boost.",
    )
    static let boostEditorDeleteMenu = NSLocalizedString(
        "browser.boost_editor.delete_menu",
        comment: "Boost editor title menu: delete the Boost.",
    )
    static let boostEditorColors = NSLocalizedString(
        "browser.boost_editor.colors",
        comment: "Boost editor: accessibility label of the color wheel.",
    )
    static let boostEditorInvert = NSLocalizedString(
        "browser.boost_editor.invert",
        comment: "Boost editor: button that turns the page's lightness around.",
    )
    static let boostEditorAdvanced = NSLocalizedString(
        "browser.boost_editor.advanced",
        comment: "Boost editor: button that shows the contrast, brightness and saturation sliders.",
    )
    static let boostEditorResetColors = NSLocalizedString(
        "browser.boost_editor.reset_colors",
        comment: "Boost editor: button that removes every color change.",
    )
    static let boostEditorContrast = NSLocalizedString(
        "browser.boost_editor.contrast",
        comment: "Boost editor: slider.",
    )
    static let boostEditorBrightness = NSLocalizedString(
        "browser.boost_editor.brightness",
        comment: "Boost editor: slider.",
    )
    static let boostEditorOriginalSaturation = NSLocalizedString(
        "browser.boost_editor.original_saturation",
        comment: "Boost editor: slider of how much of the page's own color stays under the tint.",
    )
    static let boostEditorFonts = NSLocalizedString(
        "browser.boost_editor.fonts",
        comment: "Boost editor: accessibility label of the font grid.",
    )
    static let boostEditorSize = NSLocalizedString(
        "browser.boost_editor.size",
        comment: "Boost editor: button with the page's text size.",
    )
    static let boostEditorSizeHelp = NSLocalizedString(
        "browser.boost_editor.size_help",
        comment: "Boost editor: tooltip of the Size button.",
    )
    static let boostEditorCase = NSLocalizedString(
        "browser.boost_editor.case",
        comment: "Boost editor: button with the page's text case.",
    )
    static let boostEditorCaseHelp = NSLocalizedString(
        "browser.boost_editor.case_help",
        comment: "Boost editor: tooltip of the Case button.",
    )
    static let boostEditorCaseOriginal = NSLocalizedString(
        "browser.boost_editor.case_original",
        comment: "Boost editor Case menu: keep the site's own case.",
    )
    static let boostEditorCaseCapitalize = NSLocalizedString(
        "browser.boost_editor.case_capitalize",
        comment: "Boost editor Case menu.",
    )
    static let boostEditorCaseUppercase = NSLocalizedString(
        "browser.boost_editor.case_uppercase",
        comment: "Boost editor Case menu.",
    )
    static let boostEditorCaseLowercase = NSLocalizedString(
        "browser.boost_editor.case_lowercase",
        comment: "Boost editor Case menu.",
    )
    static let boostEditorZap = NSLocalizedString(
        "browser.boost_editor.zap",
        comment: "Boost editor: button that lets the user click page elements to hide them.",
    )
    static let boostEditorZapHint = NSLocalizedString(
        "browser.boost_editor.zap_hint",
        comment: "Boost editor: shown while zapping.",
    )
    static let boostEditorRemoveHiddenElement = NSLocalizedString(
        "browser.boost_editor.remove_hidden_element",
        comment: "Boost editor: button that stops hiding a zapped element.",
    )
    static let boostEditorCode = NSLocalizedString(
        "browser.boost_editor.code",
        comment: "Boost editor: button that opens the CSS and JavaScript editor.",
    )
    static let boostEditorCSS = NSLocalizedString(
        "browser.boost_editor.css",
        comment: "Boost code editor: tab with the site's style rules.",
    )
    static let boostEditorJavaScript = NSLocalizedString(
        "browser.boost_editor.javascript",
        comment: "Boost code editor: tab with the site's script.",
    )
    static let boostEditorCSSDetail = NSLocalizedString(
        "browser.boost_editor.css_detail",
        comment: "Boost code editor: when the site's CSS applies.",
    )
    static let boostEditorJavaScriptDetail = NSLocalizedString(
        "browser.boost_editor.javascript_detail",
        comment: "Boost code editor: when the site's script runs.",
    )
    static let boostRenameTitle = NSLocalizedString(
        "browser.boost.rename_title",
        comment: "Rename dialog title.",
    )
    static let boostRenameDone = NSLocalizedString(
        "browser.boost.rename_done",
        comment: "Rename dialog button.",
    )
    static let boostDeleteTitle = NSLocalizedString(
        "browser.boost.delete_title",
        comment: "Delete confirmation title.",
    )
    static let boostDeleteDetail = NSLocalizedString(
        "browser.boost.delete_detail",
        comment: "Delete confirmation detail.",
    )
    static let boostDeleteConfirm = NSLocalizedString(
        "browser.boost.delete_confirm",
        comment: "Delete confirmation button.",
    )
    static let boostCancel = NSLocalizedString(
        "browser.boost.cancel",
        comment: "Rename and delete dialog button.",
    )
    static let boostTurnOff = NSLocalizedString(
        "browser.boost.turn_off",
        comment: "Menu item that disables a Boost.",
    )
    static let boostTurnOn = NSLocalizedString(
        "browser.boost.turn_on",
        comment: "Menu item that enables a Boost.",
    )
    static let boostRenameMenu = NSLocalizedString(
        "browser.boost.rename_menu",
        comment: "Library Boost menu item.",
    )
    static let boostDeleteMenu = NSLocalizedString(
        "browser.boost.delete_menu",
        comment: "Library Boost menu item.",
    )
    static let boostEdit = NSLocalizedString(
        "browser.boost.edit",
        comment: "Site control center: button that opens the Boost editor.",
    )
    static let boostStateOn = NSLocalizedString(
        "browser.boost.state_on",
        comment: "Site control center: a Boost that is on.",
    )
    static let boostStateOff = NSLocalizedString(
        "browser.boost.state_off",
        comment: "Site control center and Library: a Boost that is off.",
    )
    static let libraryBoosts = NSLocalizedString(
        "browser.library.boosts",
        comment: "Library section with Boosts.",
    )
    static let libraryEmptyBoosts = NSLocalizedString(
        "browser.library.empty_boosts",
        comment: "Detail of the empty Boosts section of the Library.",
    )
    static let siteControlBoosts = NSLocalizedString(
        "browser.site_control.boosts",
        comment: "Site control center section with the site's Boost.",
    )
    static let siteControlNewBoost = NSLocalizedString(
        "browser.site_control.new_boost",
        comment: "Site control center: tooltip of the button that opens the Boost editor.",
    )
    static let siteControlManageBoosts = NSLocalizedString(
        "browser.site_control.manage_boosts",
        comment: "Site control center menu: open the Library's Boosts.",
    )
    static let siteControlNewBoostMenu = NSLocalizedString(
        "browser.site_control.new_boost_menu",
        comment: "Site control center menu: open the Boost editor.",
    )
    static let settingsBoostsTitle = NSLocalizedString(
        "browser.settings.boosts",
        comment: "Settings section about Boosts.",
    )
    static let settingsBoostsEnabled = NSLocalizedString(
        "browser.settings.boosts.enabled",
        comment: "Settings switch that turns every Boost on or off.",
    )
    static let settingsBoostsDetail = NSLocalizedString(
        "browser.settings.boosts.detail",
        comment: "Settings: what Boosts are.",
    )

    static let profileMoveTabsConfirm = NSLocalizedString(
        "browser.profile_move.tabs_confirm",
        comment: "Button that moves tabs to a Space of another profile.",
    )
    static let profileMoveSpaceConfirm = NSLocalizedString(
        "browser.profile_move.space_confirm",
        comment: "Button that gives a Space another profile.",
    )
    static let settingsConfirmProfileMoves = NSLocalizedString(
        "browser.settings.confirm_profile_moves",
        comment: "Settings toggle: ask before tabs or a Space change profile.",
    )
    static let profileMoveCancel = NSLocalizedString(
        "browser.profile_move.cancel",
        comment: "Button that keeps tabs or a Space in their profile.",
    )
    static let profileMoveDontAsk = NSLocalizedString(
        "browser.profile_move.dont_ask",
        comment: "Checkbox that stops the profile change question.",
    )

    static let systemNotificationsOffOpenSettings = NSLocalizedString(
        "browser.site_permission.notifications_off.open_settings",
        comment: "Button that opens System Settings at the app's notifications.",
    )

    static let systemNotificationsOffNotNow = NSLocalizedString(
        "browser.site_permission.notifications_off.not_now",
        comment: "Button that closes the alert about notifications being off in macOS.",
    )

    static func syncAccountLastSynced(_ date: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.sync.account.last_synced",
                comment: "Sync status; the argument is a short date and time.",
            ),
            date,
        )
    }

    /// A canceled download in the sidebar's tray: "Canceled · from example.com".
    static func downloadsTrayCanceled(host: String?) -> String {
        guard let host, !host.isEmpty else { return downloadsCanceledDetail }
        return String(
            format: NSLocalizedString(
                "browser.downloads.tray_canceled_from_host",
                comment: "Tray row detail for a canceled download. %@ is the site.",
            ),
            host,
        )
    }

    static func profileMoveTabsTitle(space: String, count: Int) -> String {
        String(
            format: NSLocalizedString(
                count == 1 ? "browser.profile_move.tab_title" : "browser.profile_move.tabs_title",
                comment: "Asks before tabs move to a Space of another profile. %@ is the Space.",
            ),
            space,
        )
    }

    static func profileMoveTabsMessage(space: String, count: Int) -> String {
        String(
            format: NSLocalizedString(
                count == 1 ? "browser.profile_move.tab_message" : "browser.profile_move.tabs_message",
                comment: "Why moving tabs to a Space of another profile can lose their state. %@ is the Space.",
            ),
            space,
        )
    }

    static func profileMoveSpaceTitle(space: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.profile_move.space_title",
                comment: "Asks before a Space takes another profile. %@ is the Space.",
            ),
            space,
        )
    }

    static func profileMoveSpaceMessage(space: String, profile: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.profile_move.space_message",
                comment: "What changes when a Space takes another profile. %1$@ is the Space, %2$@ the profile.",
            ),
            space,
            profile,
        )
    }

    static func colorLight(_ name: String) -> String {
        String(format: NSLocalizedString("browser.color.light", comment: "A light shade of a spoken color name."), name)
    }

    static func colorDark(_ name: String) -> String {
        String(format: NSLocalizedString("browser.color.dark", comment: "A dark shade of a spoken color name."), name)
    }

    static func bookmarksImport(from browser: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.bookmarks.import.from",
                comment: "Menu item title for importing bookmarks from another browser. Value: the browser's name.",
            ),
            browser,
        )
    }

    static func bookmarksImported(from browser: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.bookmarks.imported_from",
                comment: "Folder title for bookmarks imported from another browser. Value: the browser's name.",
            ),
            browser,
        )
    }

    static func onboardingImportResult(_ parts: [String]) -> String {
        parts.isEmpty
            ? NSLocalizedString("browser.onboarding.import_nothing_done", comment: "Result when nothing was imported.")
            : parts.joined(separator: " · ")
    }

    static func onboardingStepCounter(_ step: Int, _ count: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.onboarding.step_counter",
                comment: "First-run welcome window: which step of how many. First value: step. Second: count.",
            ),
            step,
            count,
        )
    }

    /// "Used 5 hours ago" under a browser found on this Mac.
    static func onboardingUsedAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(
            format: NSLocalizedString(
                "browser.onboarding.used_ago",
                comment: "First-run welcome window: when a browser was last used. Value: a relative time, such as 5 hours ago.",
            ),
            formatter.localizedString(for: date, relativeTo: Date()),
        )
    }

    static func onboardingImportFrom(_ browser: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.onboarding.import_from",
                comment: "First-run welcome window: the import button. Value: browser name.",
            ),
            browser,
        )
    }

    static func onboardingImporting(_ browser: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.onboarding.importing",
                comment: "First-run welcome window: shown while importing. Value: browser name.",
            ),
            browser,
        )
    }

    static func onboardingImportCount(_ count: Int, _ item: String) -> String {
        "\(count) \(item.lowercased())"
    }

    static func agentSignInPrompt(username: String, host: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.agent.signin_prompt",
                comment: "Asks before an agent signs in with a saved password. First value: username. Second: site.",
            ),
            username,
            host,
        )
    }

    static func spaceExportAction(_ name: String) -> String {
        String(
            format: NSLocalizedString("browser.space.export_into_folder", comment: "Space submenu; the Space's name."),
            name,
        )
    }

    static func librarySearch(_ section: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.library.search_format",
                comment: "Search field placeholder in a Library section; the argument is the section's name.",
            ),
            section,
        )
    }

    static func syncAccountCodeSent(to email: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.sync.account.code_sent",
                comment: "Instruction after a sign-in code was emailed, with the email placeholder.",
            ),
            email,
        )
    }

    static func systemNotificationsOffTitle(appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.site_permission.notifications_off.title",
                comment: "Alert title after a site is allowed to notify while macOS has notifications off for the app. %@ is the app name.",
            ),
            appName,
        )
    }

    static func systemNotificationsOffMessage(origin: String, appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.site_permission.notifications_off.message",
                comment: "Alert text after a site is allowed to notify while macOS has notifications off for the app. %1$@ is the site, %2$@ the app name.",
            ),
            origin,
            appName,
        )
    }

    static func sitePermissionPromptTitle(_ origin: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.site_permission.title",
                comment: "Site permission prompt title before the list of requests. %@ is the site.",
            ),
            origin,
        )
    }

    static func settingsSitePermissionsState(camera: Bool?, microphone: Bool?) -> String {
        func state(_ format: String, _ allowed: Bool?) -> String? {
            allowed.map { String(format: format, $0 ? sitePermissionAllowedState : sitePermissionBlockedState) }
        }
        return [
            state(NSLocalizedString(
                "browser.settings.site_permissions.camera_state",
                comment: "A site's remembered camera answer in Settings. %@ is Allowed or Blocked.",
            ), camera),
            state(NSLocalizedString(
                "browser.settings.site_permissions.microphone_state",
                comment: "A site's remembered microphone answer in Settings. %@ is Allowed or Blocked.",
            ), microphone),
        ]
            .compactMap(\.self)
            .joined(separator: ", ")
    }

    static func libraryDownloadKindFromHost(kind: String, host: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.library.download_kind_from_host",
                comment: "Library download row detail. First %@ is the file kind as Finder names it, second the site.",
            ),
            kind,
            host,
        )
    }

    static func commandBarSiteSearchOffer(_ siteName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.command_bar.site_search.offer",
                comment: "Hint at the end of the command bar field, before a Tab key cap. %@ is a site name.",
            ),
            siteName,
        )
    }

    static func commandBarSiteSearchScope(_ siteName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.command_bar.site_search.scope",
                comment: "Accessibility label of the chip of the site the command bar searches. %@ is a site name.",
            ),
            siteName,
        )
    }

    static func settingsSiteSearchImportResult(_ count: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.settings.site_search.import.result",
                comment: "Alert after importing site searches. %d is how many were imported.",
            ),
            count,
        )
    }

    /// A rule's Space that this window does not have: closed in another profile or deleted.
    static func settingsLinkRouteUnavailableSpace(_ title: String?, profileName: String?) -> String {
        let space = title ?? NSLocalizedString(
            "browser.settings.link_routes.missing_space",
            comment: "Link rule destination whose Space no longer exists.",
        )
        guard let profileName else { return space }
        return String(
            format: NSLocalizedString(
                "browser.settings.link_routes.other_profile_space",
                comment: "Link rule destination in another profile. The arguments are the Space and profile names.",
            ),
            space,
            profileName,
        )
    }

    /// Shared with iOS, so it takes counts rather than the macOS import result.
    static func sidebarImportResult(spaces: Int, pinnedTabs: Int, folders: Int, favorites: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.sidebar_import.result",
                comment: "Alert after importing another browser's sidebar: Spaces, pinned tabs, folders, Favorites.",
            ),
            spaces,
            pinnedTabs,
            folders,
            favorites,
        )
    }

    static func sidebarImportMissing(from browserName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.sidebar_import.missing",
                comment: "Alert shown when a browser's sidebar files do not exist. %@ is the browser.",
            ),
            browserName,
        )
    }

    static func sidebarImportUnreadable(from browserName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.sidebar_import.unreadable",
                comment: "Alert shown when a browser's sidebar files cannot be parsed. %@ is the browser.",
            ),
            browserName,
        )
    }

    static func sidebarImportNothing(from browserName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.sidebar_import.nothing",
                comment: "Alert shown when a browser's sidebar has nothing to import. %@ is the browser.",
            ),
            browserName,
        )
    }

    static func sidebarImportAlreadyImported(from browserName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.sidebar_import.already_imported",
                comment: "Shown when every Space in a browser's sidebar is already in OpenArc. %@ is the browser.",
            ),
            browserName,
        )
    }

    static func menuGoToSidebarItem(_ number: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.go_to_sidebar_item",
                comment: "Command title that selects a sidebar tab by its position. %d is 1 to 8.",
            ),
            number,
        )
    }

    static func splitFocusPaneTitle(_ number: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.focus_split_pane",
                comment: "Command title that focuses a Split View pane by its position. %d is 1 to 4.",
            ),
            number,
        )
    }

    static func webAppErrorBundleSigningFailed(_ details: String) -> String {
        let format = NSLocalizedString(
            "browser.web_app.error.bundle_signing_failed",
            comment: "Error shown when the generated web app bundle cannot be signed.",
        )
        return String(format: format, details)
    }

    static func bookmarksOpenAllAction(count: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.bookmarks.open_all_action",
                comment: "Context menu title for opening all bookmarks in a folder. Receives the bookmark count.",
            ),
            count,
        )
    }

    static func commandBarAskAI(_ providerName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.command_bar.ask_ai",
                comment: "Command bar suggestion title for opening the query in the selected AI provider.",
            ),
            providerName,
        )
    }

    static func settingsProfileDirectory(_ directoryName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.settings.profiles.directory",
                comment: "Detail text showing the Chromium profile directory name.",
            ),
            directoryName,
        )
    }

    static func settingsProfileBackupCreated(_ filename: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.settings.profiles.backup_created",
                comment: "Message shown after a profile backup archive was created. The argument is the archive filename.",
            ),
            filename,
        )
    }

    static func settingsProfileBackupFailed(_ message: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.settings.profiles.backup_failed",
                comment: "Message shown when creating a profile backup archive fails. The argument is the error message.",
            ),
            message,
        )
    }

    static func syncAccountDevice(_ deviceID: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.sync.account.device",
                comment: "Sync account device detail with device identifier placeholder.",
            ),
            deviceID,
        )
    }

    static func defaultSpaceTitle(index: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.space.default_title",
                comment: "Default title for a newly created browser space. The argument is the 1-based space number.",
            ),
            index,
        )
    }

    static func settingsShortcutConflict(_ commandTitle: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.settings.shortcuts.conflict",
                comment: "Shortcut conflict message with conflicting command title.",
            ),
            commandTitle,
        )
    }

    static func downloadsProgressKnownTotal(received: String, total: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.downloads.progress.known_total",
                comment: "Download progress detail with received and total byte counts.",
            ),
            received,
            total,
        )
    }

    static func downloadsProgressKnownTotalWithSpeed(
        received: String,
        total: String,
        speed: String,
    ) -> String {
        String(
            format: NSLocalizedString(
                "browser.downloads.progress.known_total_with_speed",
                comment: "Download progress detail with received bytes, total bytes, and speed.",
            ),
            received,
            total,
            speed,
        )
    }

    static func downloadsProgressUnknownTotal(_ received: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.downloads.progress.unknown_total",
                comment: "Download progress detail when total size is unknown.",
            ),
            received,
        )
    }

    static func downloadsProgressUnknownTotalWithSpeed(received: String, speed: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.downloads.progress.unknown_total_with_speed",
                comment: "Download progress detail with received bytes and speed when total size is unknown.",
            ),
            received,
            speed,
        )
    }

    static func hideMenuItem(appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.hide",
                comment: "Hide menu item title with the app name placeholder.",
            ),
            appName,
        )
    }

    static func quitMenuItem(appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.quit",
                comment: "Quit menu item title with the app name placeholder.",
            ),
            appName,
        )
    }

    static func aboutMenuItem(appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.about",
                comment: "About menu item title with the app name placeholder.",
            ),
            appName,
        )
    }

    static func webAppUninstallAction(_ appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.web_app.uninstall_action",
                comment: "Menu item for uninstalling a web app, with its name as the placeholder.",
            ),
            appName,
        )
    }

    static func webAppZoomMenu(_ percent: Int) -> String {
        String(
            format: NSLocalizedString(
                "browser.web_app.zoom_menu",
                comment: "Web app zoom submenu title with the current percentage.",
            ),
            percent,
        )
    }

    static func webAppUninstallPromptMessage(_ appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.web_app.uninstall_prompt.message",
                comment: "Uninstall confirmation message with the web app name.",
            ),
            appName,
        )
    }

    static func aboutWindowTitle(appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.about.window_title",
                comment: "About window title with the app name placeholder.",
            ),
            appName,
        )
    }

    static func aboutApplicationVersion(marketingVersion: String, buildVersion: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.about.application_version",
                comment: "Application version text with marketing version and build number placeholders.",
            ),
            marketingVersion,
            buildVersion,
        )
    }

    static func aboutChromiumVersion(_ chromiumVersion: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.about.chromium_version",
                comment: "Chromium version text with the Chromium version placeholder.",
            ),
            chromiumVersion,
        )
    }

    static func notificationPermissionMessage(origin: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.permissions.notifications.message",
                comment: "Notification permission prompt body with the site origin placeholder.",
            ),
            origin,
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

// MARK: - Content blocking

extension BrowserStrings {
    static let settingsPrivacySection = NSLocalizedString(
        "browser.settings.privacy",
        comment: "Settings: the section with the built-in ad, tracker and cookie banner blocker.",
    )
    static let settingsBlockAds = NSLocalizedString(
        "browser.settings.privacy.block_ads",
        comment: "Settings: the built-in ad blocker.",
    )
    static let settingsBlockAdsDetail = NSLocalizedString(
        "browser.settings.privacy.block_ads.detail",
        comment: "Settings: what the ad blocker does.",
    )
    static let settingsBlockTrackers = NSLocalizedString(
        "browser.settings.privacy.block_trackers",
        comment: "Settings: the built-in tracker blocker.",
    )
    static let settingsBlockTrackersDetail = NSLocalizedString(
        "browser.settings.privacy.block_trackers.detail",
        comment: "Settings: what the tracker blocker does.",
    )
    static let settingsBlockCookieBanners = NSLocalizedString(
        "browser.settings.privacy.block_cookie_banners",
        comment: "Settings: the built-in cookie banner blocker.",
    )
    static let settingsBlockCookieBannersDetail = NSLocalizedString(
        "browser.settings.privacy.block_cookie_banners.detail",
        comment: "Settings: what the cookie banner blocker does.",
    )
    static let settingsFilterLists = NSLocalizedString(
        "browser.settings.privacy.filter_lists",
        comment: "Settings: the filter lists behind the blocker.",
    )
    static let settingsFilterListsBundled = NSLocalizedString(
        "browser.settings.privacy.filter_lists.bundled",
        comment: "Settings: the blocker still uses the filter lists that came with the app.",
    )
    static let settingsFilterListsUpdating = NSLocalizedString(
        "browser.settings.privacy.filter_lists.updating",
        comment: "Settings: the filter lists are downloading.",
    )
    static let settingsFilterListsUpdateNow = NSLocalizedString(
        "browser.settings.privacy.filter_lists.update_now",
        comment: "Settings: button that downloads the filter lists now.",
    )
    static let settingsAllowedSites = NSLocalizedString(
        "browser.settings.privacy.allowed_sites",
        comment: "Settings: sites where ads are allowed.",
    )
    static let settingsAllowedSitesDetail = NSLocalizedString(
        "browser.settings.privacy.allowed_sites.detail",
        comment: "Settings: how to allow ads on a site.",
    )
    static let settingsAllowedSitesEmpty = NSLocalizedString(
        "browser.settings.privacy.allowed_sites.empty",
        comment: "Settings: no site is allowed to show ads.",
    )
    static let settingsAllowedSitesRemove = NSLocalizedString(
        "browser.settings.privacy.allowed_sites.remove",
        comment: "Settings: button that blocks ads on an allowed site again.",
    )
    static let siteSettingContentBlocking = NSLocalizedString(
        "browser.site_setting.content_blocking",
        comment: "Site setting: the built-in blocker on this site.",
    )
    static let siteSettingContentBlockingBlock = NSLocalizedString(
        "browser.site_setting.content_blocking.block",
        comment: "Site setting's menu item: block ads and trackers on the site.",
    )
    static let siteSettingContentBlockingAllow = NSLocalizedString(
        "browser.site_setting.content_blocking.allow",
        comment: "Site setting's menu item: allow ads on the site.",
    )

    /// "Updated 2 days ago" under the filter lists.
    static func settingsFilterListsUpdated(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(
            format: NSLocalizedString(
                "browser.settings.privacy.filter_lists.updated",
                comment: "Settings: when the filter lists were last downloaded. Value: a relative time, such as 2 days ago.",
            ),
            formatter.localizedString(for: date, relativeTo: Date()),
        )
    }
}

// MARK: - BrowserStrings + Sharing

extension BrowserStrings {
    static let shareSpaceAction = NSLocalizedString(
        "browser.share.space",
        comment: "Space menu item; publishes the Space's pinned tabs as a link.",
    )
    static let shareFolderAction = NSLocalizedString(
        "browser.share.folder",
        comment: "Folder menu item; publishes the folder's tabs as a link.",
    )
    static let shareSignInTitle = NSLocalizedString(
        "browser.share.sign_in.title",
        comment: "Alert title when sharing while signed out.",
    )
    static let shareSignInDetail = NSLocalizedString(
        "browser.share.sign_in.detail",
        comment: "Alert detail when sharing while signed out.",
    )
    static let shareOpenSettings = NSLocalizedString(
        "browser.share.open_settings",
        comment: "Button opening the account settings.",
    )
    static let shareNothingTitle = NSLocalizedString(
        "browser.share.nothing.title",
        comment: "Alert title when a Space or folder has no web pages.",
    )
    static let shareNothingSpace = NSLocalizedString(
        "browser.share.nothing.space",
        comment: "Alert detail for a Space without pinned web pages.",
    )
    static let shareNothingFolder = NSLocalizedString(
        "browser.share.nothing.folder",
        comment: "Alert detail for a folder without web pages.",
    )
    static let shareConfirmTitleFormat = NSLocalizedString(
        "browser.share.confirm.title",
        comment: "Alert title before publishing; the Space or folder name.",
    )
    static let shareConfirmSpaceFormat = NSLocalizedString(
        "browser.share.confirm.space",
        comment: "What a Space link shows; a tab count.",
    )
    static let shareConfirmFolderFormat = NSLocalizedString(
        "browser.share.confirm.folder",
        comment: "What a folder link shows; a tab count.",
    )
    static let shareConfirmUpdateFormat = NSLocalizedString(
        "browser.share.confirm.update",
        comment: "Sharing again; the date of the earlier share.",
    )
    static let shareConfirmStop = NSLocalizedString(
        "browser.share.confirm.stop",
        comment: "Where shared links are managed.",
    )
    static let shareConfirmAction = NSLocalizedString(
        "browser.share.confirm.action",
        comment: "Button that publishes and copies the link.",
    )
    static let shareCancel = NSLocalizedString("browser.share.cancel", comment: "Cancel button.")
    static let shareCopiedTitleFormat = NSLocalizedString(
        "browser.share.copied.title",
        comment: "Alert after publishing; the Space or folder name.",
    )
    static let shareDone = NSLocalizedString("browser.share.done", comment: "Button closing the alert.")
    static let shareOpenLink = NSLocalizedString(
        "browser.share.open_link",
        comment: "Button opening the shared page in a new tab.",
    )
    static let shareFailed = NSLocalizedString("browser.share.failed", comment: "Alert title when publishing fails.")
    static let shareFailedDetail = NSLocalizedString(
        "browser.share.failed.detail",
        comment: "Fallback error text for sharing.",
    )
    static let shareSignedOut = NSLocalizedString(
        "browser.share.signed_out",
        comment: "Error when the account session ended.",
    )
    static let shareNotFound = NSLocalizedString("browser.share.not_found", comment: "Error for a missing shared link.")
    static let shareAddUnavailable = NSLocalizedString(
        "browser.share.add.unavailable",
        comment: "Alert when the window cannot take a shared Space.",
    )
    static let shareRemovedTitle = NSLocalizedString(
        "browser.share.removed.title",
        comment: "Alert title for a link that no longer exists.",
    )
    static let shareRemovedDetail = NSLocalizedString(
        "browser.share.removed.detail",
        comment: "Alert detail for a link that no longer exists.",
    )
    static let shareAddFailed = NSLocalizedString(
        "browser.share.add.failed",
        comment: "Alert title when reading or adding a shared link fails.",
    )
    static let shareAddTitleFormat = NSLocalizedString(
        "browser.share.add.title",
        comment: "Alert title before adding a shared Space or folder.",
    )
    static let shareAddSpaceFormat = NSLocalizedString(
        "browser.share.add.space",
        comment: "Adding a shared Space; tab and folder counts.",
    )
    static let shareAddFolderFormat = NSLocalizedString(
        "browser.share.add.folder",
        comment: "Adding a shared folder; counts and the current Space.",
    )
    static let shareAddSpaceAction = NSLocalizedString(
        "browser.share.add.space_action",
        comment: "Button adding a shared Space.",
    )
    static let shareAddFolderAction = NSLocalizedString(
        "browser.share.add.folder_action",
        comment: "Button adding a shared folder.",
    )
    static let shareAlreadyAdded = NSLocalizedString(
        "browser.share.already_added",
        comment: "Alert when the shared Space was added before.",
    )
    static let shareOneTab = NSLocalizedString("browser.share.count.tab", comment: "Count of one tab.")
    static let shareTabsFormat = NSLocalizedString("browser.share.count.tabs", comment: "Count of several tabs.")
    static let shareOneFolder = NSLocalizedString("browser.share.count.folder", comment: "Count of one folder.")
    static let shareFoldersFormat = NSLocalizedString(
        "browser.share.count.folders",
        comment: "Count of several folders.",
    )
    static let shareTabsInFoldersFormat = NSLocalizedString(
        "browser.share.count.tabs_in_folders",
        comment: "Tabs in folders, such as 7 tabs in 2 folders.",
    )
    static let shareKindSpace = NSLocalizedString("browser.share.kind.space", comment: "Kind of a shared link.")
    static let shareKindFolder = NSLocalizedString("browser.share.kind.folder", comment: "Kind of a shared link.")
    static let shareKindQuote = NSLocalizedString("browser.share.kind.quote", comment: "Kind of a shared link.")
    static let settingsSharedLinksSection = NSLocalizedString(
        "browser.settings.shared_links",
        comment: "Settings section listing the account's links.",
    )
    static let settingsSharedLinksEmpty = NSLocalizedString(
        "browser.settings.shared_links.empty",
        comment: "Empty list of shared links.",
    )
    static let settingsSharedLinksLoading = NSLocalizedString(
        "browser.settings.shared_links.loading",
        comment: "Shared links are loading.",
    )
    static let settingsSharedLinksRetry = NSLocalizedString(
        "browser.settings.shared_links.retry",
        comment: "Button reloading the shared links.",
    )
    static let settingsSharedLinksCopy = NSLocalizedString(
        "browser.settings.shared_links.copy",
        comment: "Button copying a shared link.",
    )
    static let settingsSharedLinksStop = NSLocalizedString(
        "browser.settings.shared_links.stop",
        comment: "Button removing a shared link.",
    )
    static let settingsSharedLinksStopTitleFormat = NSLocalizedString(
        "browser.settings.shared_links.stop.title",
        comment: "Alert title before removing a link.",
    )
    static let settingsSharedLinksStopDetail = NSLocalizedString(
        "browser.settings.shared_links.stop.detail",
        comment: "Alert detail before removing a link.",
    )

    static func shareTabCount(_ count: Int) -> String {
        count == 1 ? shareOneTab : String(format: shareTabsFormat, count)
    }

    static func shareFolderCount(_ count: Int) -> String {
        count == 1 ? shareOneFolder : String(format: shareFoldersFormat, count)
    }

    /// "7 tabs", or "7 tabs in 2 folders".
    static func shareContents(tabs: Int, folders: Int) -> String {
        folders == 0
            ? shareTabCount(tabs)
            : String(format: shareTabsInFoldersFormat, shareTabCount(tabs), shareFolderCount(folders))
    }

    static func shareKindName(_ kind: BrowserShareKind) -> String {
        switch kind {
        case .space: shareKindSpace
        case .folder: shareKindFolder
        case .quote: shareKindQuote
        }
    }

    static func shareNothingDetail(_ kind: BrowserShareKind) -> String {
        kind == .folder ? shareNothingFolder : shareNothingSpace
    }

    static func shareConfirmTitle(_ title: String) -> String { String(format: shareConfirmTitleFormat, title) }

    static func shareConfirmDetail(kind: BrowserShareKind, tabs: Int, sharedOn: Date?) -> String {
        let format = kind == .folder ? shareConfirmFolderFormat : shareConfirmSpaceFormat
        var lines = [String(format: format, shareTabCount(tabs))]
        if let sharedOn {
            lines.append(String(
                format: shareConfirmUpdateFormat,
                sharedOn.formatted(date: .abbreviated, time: .omitted),
            ))
        }
        lines.append(shareConfirmStop)
        return lines.joined(separator: " ")
    }

    static func shareCopiedTitle(_ title: String) -> String { String(format: shareCopiedTitleFormat, title) }

    static func shareCopiedDetail(_ url: String) -> String { url + "\n\n" + shareConfirmStop }

    static func shareAddTitle(_ title: String) -> String { String(format: shareAddTitleFormat, title) }

    static func shareAddDetail(kind: BrowserShareKind, tabs: Int, folders: Int, into spaceTitle: String?) -> String {
        let contents = shareContents(tabs: tabs, folders: folders)
        return kind == .folder
            ? String(format: shareAddFolderFormat, contents, spaceTitle ?? shareKindSpace)
            : String(format: shareAddSpaceFormat, contents)
    }

    static func settingsSharedLinksStopTitle(_ title: String) -> String {
        String(format: settingsSharedLinksStopTitleFormat, title)
    }
}
