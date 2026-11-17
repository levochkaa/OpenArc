// BrowserChromeModel.swift

import AppKit
import Combine
import Foundation
import OSLog

// MARK: - BrowserInternalPageRouting

enum BrowserInternalPageRouting {
    static let settingsURL = URL(string: "openarc://settings/")!
    static let historyURL = URL(string: "openarc://history")!
    static let bookmarksURL = URL(string: "openarc://bookmarks/")!
}

// MARK: - BrowserWindowMode

enum BrowserWindowMode: Equatable {
    case normal
    case incognito
    /// A window of the profile with its own tabs, outside its Spaces and not saved.
    case blank
    case webApp(BrowserWebAppConfiguration)

    // MARK: Internal

    var isIncognito: Bool {
        self == .incognito
    }

    var isWebApp: Bool {
        guard case .webApp = self else {
            return false
        }

        return true
    }

    var persistsSession: Bool {
        self == .normal
    }

    /// Whether the window lists only its own tabs.
    var isSpaceless: Bool {
        self != .normal
    }

    var telemetryValue: String {
        switch self {
        case .normal:
            "normal"
        case .blank:
            "blank"
        case .incognito:
            "incognito"
        case .webApp:
            "web_app"
        }
    }
}

// MARK: - BrowserChromeModel

@MainActor final class BrowserChromeModel: NSObject, ObservableObject, BrowserSyncSnapshotApplying {
    // MARK: Internal

    enum TabCloseReason {
        case manual
        case automaticExpiry
        case structuralRemoval
        case remoteProjection
        case undoRedo
    }

    // MARK: Private

    private struct LocalAutomaticArchiveCandidate {
        let id: String
        let syncID: String
        let spaceID: String
        let lastActivityAt: Date
    }

    private struct PendingTabCloseRequest {
        let requestID: String
        let syncID: String
        let registersUndo: Bool
        let undoActionName: String
        let createsArchive: Bool
        let preservesPersistentTab: Bool
        let unloadsPersistentTab: Bool
        let historyKind: TabHistoryKind
        let localAutomaticCandidate: LocalAutomaticArchiveCandidate?
        var invalidatedAutomaticClose = false
        let completion: ((HistoryCloseResult) -> Void)?
    }

    private enum HistoryCloseResult {
        case closed(TabUndoSnapshot, archiveID: String?)
        case cancelled
        case removed
    }

    private enum TabHistoryKind: Equatable {
        case creation
        case archive
        case logicalRemoval
    }

    private struct PendingSessionCompletion {
        let write: BrowserSessionWrite
        let completion: () -> Void
    }

    private struct PendingHistoryRestore {
        let archiveID: String?
        let syncID: String
        let snapshot: TabUndoSnapshot
        let kind: TabHistoryKind
        let actionName: String
        let completion: (BrowserTabUndoManager.Outcome) -> Void
    }

    private struct PendingReopenedTabCreation {
        let previousID: String
        let titleAtRequest: String
    }

    private struct PendingCreatedTabContext {
        let spaceID: String
        let placement: BrowserTabPlacement
        let undoSnapshot: TabUndoSnapshot?
        /// A new Today tab goes to the top of Today.
        var placesAtTop = false
    }

    private final class TabCreationUndoReference {
        // MARK: Internal

        var currentTabID: String?

        init(tabID: String) {
            self.currentTabID = tabID
        }
    }

    private struct TabUndoSnapshot {
        let tab: Tab
        let insertionIndex: Int
        let wasSelectedTab: Bool
        let wasSelectedInSpace: Bool
        let creationUndoReference: TabCreationUndoReference?
    }

    private struct RemoteTabCreation {
        let snapshot: BrowserTabSessionSnapshotTab
        let generation: Int
    }

    private enum AutomaticArchivalSettingsRetry {
        case reload
        case synchronized(BrowserTemporaryTabLifetime?)
        case localLifetime(BrowserTemporaryTabLifetime)
    }

    nonisolated static let defaultSidebarWidth: CGFloat = 228
    nonisolated static let minSidebarWidth: CGFloat = defaultSidebarWidth
    /// The sidebar is capped at 500 pt. The minimum stays at the default,
    /// because the sidebar header has no compact layout.
    nonisolated static let maxSidebarWidth: CGFloat = 500
    nonisolated static let defaultExtensionSidePanelWidth: CGFloat = 360
    nonisolated static let minExtensionSidePanelWidth: CGFloat = 280
    nonisolated static let maxExtensionSidePanelWidth: CGFloat = 560
    nonisolated static let defaultNewTabURLString = "https://www.google.com"
    nonisolated static let automaticArchivalCheckInterval: TimeInterval = 60 * 60
    nonisolated static let appTabCapacity = 8
    nonisolated static let defaultSpaceID = BrowserSessionDefaults.defaultSpaceID
    nonisolated static let defaultSpaceIconName = BrowserSessionDefaults.defaultSpaceIconName
    nonisolated static let tabSwitcherMaximumEntries = 5
    nonisolated static let tabSwitcherPresentationDelayNanoseconds: UInt64 = 50_000_000
    nonisolated static let zoomPercentages = [
        25,
        33,
        50,
        67,
        75,
        80,
        90,
        100,
        110,
        125,
        150,
        175,
        200,
        250,
        300,
        400,
        500,
    ]

    static let findPasteboardDelay: TimeInterval = 0.12

    /// A busy page may answer late; give up after about a second.
    static let findPasteboardAttempts = 8

    /// How long a tab switch waits before it is saved.
    nonisolated static let selectionPersistDelay: TimeInterval = 0.15

    private static let automaticArchivalLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.OpenArc", category: "AutomaticArchival",
    )

    private static let selectionHistoryLimit = 64

    @Published private(set) var tabs = [Tab]() {
        didSet { validatedSplitGroupsCache = nil }
    }

    /// `validatedSplitGroups()` for the current tabs and groups; every row asks for it.
    var validatedSplitGroupsCache: [SplitGroup]?
    @Published private(set) var isCustomizingToolbar = false
    /// Tabs whose close the engine is still confirming. Their rows go at once, and the model
    /// keeps them until the engine answers, so a page that refuses loses nothing.
    @Published private(set) var tabsLeavingSidebar = Set<String>()
    /// The address of the link under the pointer in the shown tab.
    @Published private(set) var linkStatus: String?
    @Published private(set) var spaces = [Space]()
    @Published private(set) var pinnedTabFolders = [PinnedTabFolder]()
    @Published private(set) var selectedSpaceID: String? {
        didSet {
            tabDriver.profileCachePathForNewTabs = profileCachePath(forSpaceID: selectedSpaceID)
        }
    }

    @Published private(set) var tabSwitcherState: TabSwitcherState?
    @Published var isSidebarVisible = true
    /// Published as a change of the model, except while a live resize drags it: then
    /// `onLiveSidebarWidthChange` only moves the layout, and the resize's end publishes.
    private(set) var sidebarWidth = BrowserChromeModel.defaultSidebarWidth {
        willSet {
            if !isSidebarResizing, newValue != sidebarWidth {
                objectWillChange.send()
            }
        }
    }

    /// A pointer drags the sidebar's edge.
    var isSidebarResizing = false {
        willSet {
            if isSidebarResizing, !newValue {
                objectWillChange.send()
            }
        }
    }

    /// Each width a live resize passes through, for the window's layout.
    var onLiveSidebarWidthChange: (() -> Void)?
    @Published private(set) var temporaryTabLifetime: BrowserTemporaryTabLifetime
    @Published private(set) var automaticTabArchivalEnabled = false
    /// Never in Settings without sync: temporary tabs stay until closed.
    @Published private(set) var localAutomaticArchivalOff = false
    @Published private(set) var automaticArchivalSettingsError: String?
    @Published private(set) var archiveRevision = 0
    @Published private(set) var archiveError: String?
    @Published private(set) var isArchiveOperationInFlight = false
    @Published private(set) var isFindBarPresented = false
    @Published private(set) var findBarFocusRequest = 0
    @Published private(set) var findResultMatchCount: Int? {
        didSet {
            if findResultMatchCount == nil {
                findResultActiveOrdinal = nil
            }
        }
    }

    /// The match the page shows selected, counted from 1.
    @Published private(set) var findResultActiveOrdinal: Int?
    @Published private(set) var browserExtensions = [BrowserExtension]()
    @Published private(set) var extensionSidePanel: BrowserExtensionSidePanel?
    @Published private(set) var extensionSidePanelWidth = BrowserChromeModel.defaultExtensionSidePanelWidth
    @Published private(set) var pinnedExtensionIDs = [String]()
    @Published private(set) var selectedTabWebAppInstallMetadata: BrowserWebAppInstallMetadata?
    @Published private(set) var profileDisplayName: String
    @Published private(set) var availableProfileCount: Int
    @Published private(set) var zoomPercent = 100
    @Published private(set) var sessionPersistenceFailure: BrowserSessionPersistenceFailure?
    let hostView: NSView
    let userPreferencesStore: BrowserUserPreferencesStore
    /// The text Use Selection to Find reads; tests replace the system pasteboard.
    var findPasteboardText: () -> String? = { NSPasteboard(name: .find).string(forType: .string) }
    var findPasteboardChangeCount: () -> Int = { NSPasteboard(name: .find).changeCount }
    let shortcutStore: BrowserShortcutStore
    let bookmarksModel: BrowserBookmarksModel
    let downloadsModel: BrowserDownloadsModel
    let windowMode: BrowserWindowMode
    let profile: BrowserProfile
    let undoManager = BrowserTabUndoManager()
    /// Nesting of arrangement edits; only the outermost registers Undo.
    var arrangementUndoDepth = 0
    /// Tabs Clear is closing, each with that Clear's Undo batch.
    var tabCloseUndoBatches = [String: UUID]()
    var isApplyingArrangementUndo = false
    lazy var commandBarModel: BrowserCommandBarModel = {
        let model = makeCommandBarModel { [weak self] resolvedURLString in
            self?.openResolvedSelectionInNewTab(resolvedURLString)
        }
        // Command-Return opens the page behind, at the top of Today.
        model.backgroundSubmitHandler = { [weak self] resolvedURLString in
            self?.createTab(withURLString: resolvedURLString, makeActive: false, placesAtTop: true)
        }
        // Option-Return opens the page beside the one on screen.
        model.splitSubmitHandler = { [weak self] resolvedURLString in
            guard let self else { return }
            if pendingSplitAnchorTabID == nil, let url = URL(string: resolvedURLString), openURLInSplitView(url) {
                return
            }
            openResolvedSelectionInNewTab(resolvedURLString)
        }
        return model
    }()

    /// The address bar shows centered on the page, as from Command-L.
    private(set) var isCurrentPageCommandBarCentered = false

    lazy var currentPageCommandBarModel = makeCommandBarModel { [weak self] resolvedURLString in
        self?.navigateSelectedTab(toURLString: resolvedURLString)
    }

    /// The bar New Small Window shows first: what it opens goes to a small window.
    lazy var littleWindowCommandBarModel = makeCommandBarModel(forLittleWindow: true) { [weak self] resolvedURLString in
        if let url = URL(string: resolvedURLString) {
            self?.openInLittleWindow(url)
        }
    }

    private(set) var isContextReady = false
    var isShuttingDown = false

    /// Last Split View layout sent to the engine. Only `syncSplitLayout()`
    /// changes it, so repeated selection inside one split sends nothing.
    var appliedSplitLayout: BrowserTabVisibleLayout?

    /// Tab that the next command bar result joins as a new Split View pane.
    /// `presentSplitViewCommandBar()` sets it; any other presentation or
    /// dismissal through the model clears it.
    var pendingSplitAnchorTabID: String?
    /// Where the pending pane goes relative to its anchor (Add Left/Right Split).
    var pendingSplitInsertion = SplitInsertion.end
    var pendingSplitOrientation = BrowserTabSplitOrientation.horizontal
    /// UI-only: the visible split's pane frames in the engine host view, in pane
    /// order, as the engine last laid them out. Not published: it changes on
    /// every frame of a divider drag, and pane bars listen through
    /// `onSplitPaneLayoutChange` instead. Only `handleSplitPaneLayout` sets them.
    var splitPaneLayoutTabIDs = [String]()
    var splitPaneLayoutFrames = [CGRect]()
    var onSplitPaneLayoutChange: (() -> Void)?
    /// UI-only: the window's downloads list, toggled by View Downloads.
    var onToggleDownloads: (() -> Void)?
    /// UI-only mirror of the sidebar's tabs that stay visible in collapsed
    /// folders, so keyboard navigation counts the rows the sidebar shows.
    var sidebarRevealedPinnedTabIDsByFolderID = [String: Set<String>]()
    /// Tabs picked together in the sidebar with Command- or Shift-click.
    var sidebarMultiSelection = Set<String>()
    /// Muted tabs by sync ID, for this run only; a reopened dormant tab keeps it.
    /// Only `setTabMuted(_:id:)` writes it.
    @Published var mutedTabSyncIDs = Set<String>()
    /// Tabs whose pages play media, by runtime ID, with the order they began
    /// and the mini players closed since. Only `BrowserTabMedia.swift` writes them.
    @Published var tabMediaStates = [String: BrowserTabMediaState]()
    /// Tabs using the camera, the microphone or screen capture.
    @Published var capturingTabIDs = Set<String>()
    /// Tabs with a Peek card, open or put away, and the address in it.
    @Published var peekPagesByTabID = [String: String]()
    var tabMediaStartOrder = [String: Int]()
    var nextTabMediaStartOrder = 0
    @Published var dismissedMiniPlayerTabIDs = Set<String>()
    /// Tabs on screen whose renderer crashed, with Chromium's error code, and
    /// tabs whose renderer went away in the background, which reload when
    /// shown. Only `BrowserChromeModel+CrashedTabs.swift` writes them.
    @Published var crashedTabErrorCodes = [String: Int]()
    /// Tabs this window showed when another window of the profile took their page, and
    /// pictures of those pages once taken. The window shows the picture, faded, until
    /// the page comes back on a click.
    /// The tab whose page is in fullscreen through the Fullscreen API; the window shows it
    /// alone, edge to edge, in full screen.
    @Published private(set) var pageFullscreenTabID: String?
    @Published private(set) var movedPageTabIDs = Set<String>()
    @Published private(set) var movedPagePictures = [String: NSImage]()
    var tabsNeedingReloadAfterCrash = Set<String>()
    /// An incognito window's camera and microphone answers, kept until it
    /// closes. Only `sitePermissionDecisions` writes it.
    var incognitoSitePermissionDecisions = [BrowserSitePermissionDecision]()
    /// Asks macOS to let OpenArc show notifications; tests replace it.
    var requestSystemNotificationAuthorization: (@escaping @Sendable (Bool) -> Void) -> Void =
        BrowserNotificationAuthorization.request
    /// Asks macOS to let OpenArc use the location; tests replace it.
    var requestSystemLocationAuthorization: @MainActor (@escaping @MainActor (Bool) -> Void) -> Void =
        BrowserLocationAuthorization.request
    /// Asks macOS to let OpenArc use the camera or microphone; tests replace it.
    var requestSystemMediaCaptureAuthorization: @MainActor (
        [BrowserSitePermissionKind],
        @escaping @MainActor (Bool) -> Void,
    ) -> Void = BrowserMediaCaptureAuthorization.request
    /// UI-only: the window's site control center, opened by Open Extensions.
    var onOpenExtensions: (() -> Void)?
    /// UI-only: shows a hidden sidebar over the page for Reveal Current Tab.
    var onRevealSidebar: (() -> Void)?
    /// Called when a tab's row comes or goes, so the rows move ahead of the work that follows.
    var onTabRowsChanged: (() -> Void)?
    /// Called before a Space is selected, so its motion can start ahead of the tab switch.
    var onSpaceWillSelect: ((String) -> Void)?
    /// UI-only: bumped by `renameSelectedTab()`, the only writer, so the
    /// sidebar starts renaming the selected row.
    @Published var sidebarRenameRequestID = 0
    @Published var sidebarSpaceRenameRequestID = 0
    @Published var passwordPrompt: BrowserPasswordPrompt?
    var passwordStore: BrowserPasswordStoring?
    var addressStore: BrowserAddressStoring?
    var mailPreviewFetcher: BrowserMailPreviewFetcher?
    var mailPreviews = [String: BrowserMailPreview]()
    var mailPreviewDates = [String: Date]()
    var onMailPreviewChanged: (() -> Void)?
    var restorePoints: BrowserSessionSnapshots?
    /// The latest download to start: the window shows it flying to the archive button.
    @Published private(set) var downloadLaunch: BrowserDownloadLaunch?
    /// A folder just made from the menu: the sidebar opens its name for editing.
    @Published var folderToRename: String?
    var cardStore: BrowserCardStoring?
    /// Asks the Mac's owner before a card goes into a page.
    var authenticateCardUse: @MainActor (String) async -> Bool = BrowserCardAuthentication.ask
    var liveFolderFetcher: BrowserGitHubLiveFolderFetcher?
    @Published var tabMediaVolumes = [String: Double]()
    /// Asks the window's controls to open an extension, anchored to the address row.
    var onOpenExtensionRequest: ((String) -> Void)?
    /// UI-only: bumped by `revealSelectedTabInSidebar()`, the only writer, so the
    /// sidebar scrolls the selected row into view.
    @Published var sidebarRevealRequestID = 0
    /// Browser profile directories by Space ID, for Spaces that do not use the
    /// window's own profile. Local.
    @Published private(set) var spaceProfilesByID = [String: String]()
    /// The application's profiles and where they keep their data.
    var profileDirectories: BrowserSpaceProfileDirectories?
    /// Space themes by Space ID. Local.
    @Published private(set) var spaceThemesByID = [String: BrowserSpaceTheme]()
    /// Save As from a page's menu; the application owns the save panel.
    var onSavePageRequest: (() -> Void)?
    /// UI-only: shows the share sheet in the window.
    var onShareURL: ((URL) -> Void)?
    var onOpenLinkInIncognito: ((URL) -> Void)?
    /// Shows the bar for a new small window; false when no window can show it.
    var onPresentLittleWindowLauncher: (() -> Bool)?
    /// Opens pages in a new window of their own, its top left corner near a screen point.
    var onMoveTabsToNewWindow: (([URL], [BrowserTabPageHandoff?], CGPoint) -> Void)?
    /// Opens a link in a new window of this profile, as a new tab there; false when
    /// there is no such window.
    var onOpenLinkInNewWindow: ((URL) -> Bool)?
    /// Import Passwords from a text field's menu: the import of another browser's data.
    var onImportFromBrowser: (() -> Void)?
    /// UI-only: Copy URL from the menu or its shortcut copied this address.
    var onCopiedCurrentURL: ((URL) -> Void)?
    /// The page's zoom changed through a command; the window shows the new value.
    var onZoomChanged: ((Int) -> Void)?
    /// Hands tabs dropped on another window of this app to that window; false when it takes none.
    var onMoveTabsToWindow: ((Set<String>, NSWindow) -> Bool)?
    /// Pages a new window opens after its first one, in the background.
    var additionalTabURLStrings = [String]()
    /// UI-only: opens the window's theme editor for a Space.
    var onEditSpaceTheme: ((String) -> Void)?
    /// UI-only: opens the theme editor for the Space being created, beside this view.
    var onEditSpaceCreationTheme: ((NSView) -> Void)?
    /// The Library's section while it replaces the sidebar, nil when closed.
    @Published var librarySection: BrowserLibrarySection? {
        didSet {
            if let librarySection {
                lastLibrarySection = librarySection
            }
        }
    }

    /// A Space being set up in the sidebar. Its theme shows on the window at once.
    @Published private(set) var spaceCreationDraft: BrowserSpaceCreationDraft?
    /// Change Icon: the symbol shown instead of a tab's favicon, by sync
    /// ID so it survives a dormant tab reopening under a new runtime ID. Local.
    private(set) var tabIconsBySyncID = [String: String]()
    /// Set by the window's content view, which outlines the area to capture.
    var onBeginAreaCapture: (() -> Bool)?
    /// Pages' pending permission requests in arrival order. Only the methods
    /// in `BrowserChromeModel+SitePermissions.swift` write it.
    @Published var sitePermissionRequests = [BrowserSitePermissionRequest]() {
        didSet {
            // Peek cards and small windows show their own prompt.
            let peek = sitePermissionRequests.filter { $0.peekSessionID != nil }
            if peek != oldValue.filter({ $0.peekSessionID != nil }) {
                tabDriver.showPeekSitePermissionRequests(peek)
            }
        }
    }

    /// Expand Current Split: this pane alone fills the window until focus
    /// moves. UI-only, never persisted.
    var expandedSplitPaneTabID: String? {
        didSet {
            if oldValue != expandedSplitPaneTabID {
                syncSplitLayout()
            }
        }
    }

    /// Raw local Split View state. Only `BrowserChromeModel+SplitGroups.swift`
    /// mutates it; readers use `splitGroup(containingTabID:)`, which validates
    /// members against the current tabs.
    @Published var splitGroups = [SplitGroup]() {
        didSet {
            validatedSplitGroupsCache = nil
            syncSplitLayout()
        }
    }

    @Published private(set) var selectedTabID: String? {
        willSet {
            guard selectedTabID != newValue, canRecordViewingActivity else { return }
            // Every pane of a split is on screen while one member is focused.
            let ids = [selectedTabID, newValue].compactMap(\.self).flatMap { splitPaneTabIDs(forTabID: $0) }
            for id in Set(ids) {
                guard tabs.first(where: { $0.id == id })?.creationState == .ready else { continue }
                touchTab(id: id)
            }
        }
        didSet {
            if let selectedTabID, selectedTabID != oldValue {
                selectionHistory.removeAll { $0 == selectedTabID }
                selectionHistory.append(selectedTabID)
                if selectionHistory.count > Self.selectionHistoryLimit {
                    selectionHistory.removeFirst(selectionHistory.count - Self.selectionHistoryLimit)
                }
            }
            recordSplitFocus(tabID: selectedTabID)
            syncSplitLayout()
            refreshZoomFromEngine()
            updatePictureInPicture(leaving: oldValue, entering: selectedTabID)
            revealCrashedTabs()
        }
    }

    /// Tabs in the order they were last selected, the latest last; closing the
    /// selected tab goes back to the one before it.
    private(set) var selectionHistory = [String]()

    @Published var findQuery = "" {
        didSet {
            guard findQuery != oldValue else {
                return
            }

            handleFindQueryChange()
        }
    }

    /// The page a window with nothing to restore opens first, instead of the new tab page.
    var firstTabURLString: String?
    /// Live pages for the first and additional tabs, by position; a missing one loads its address.
    var initialTabPages = [BrowserTabPageHandoff?]()

    /// The profile's other windows, once it has more than one.
    var windowGroup: BrowserProfileWindowGroup?
    /// Opens beside another window of the profile: its tabs start without pages, and
    /// the first window keeps expiring them.
    var isAdditionalWindow = false
    /// The Space an additional window starts on.
    var firstSpaceID: String?

    /// Capture in Portrait Mode: the window shows its options once it has the picture.
    var onPortraitCapture: ((Data) -> Void)?
    /// The button the options hang from; without one they sit over the page's middle.
    weak var portraitCaptureAnchor: NSView?

    /// The section the Library opens on again, however it was closed.
    private(set) var lastLibrarySection = BrowserLibrarySection.archive

    private var tabRowChangeBatchDepth = 0
    private var tabRowsChangedInBatch = false

    /// Tabs a link opened, with the tab it came from, to keep them together below it.
    private var tabOpenerIDs = [String: String]()

    /// Answers this window's waiting requests that another window's answer covers.
    private var sitePermissionDecisionsObservation: AnyCancellable?
    private var extensionTabsObservation: AnyCancellable?
    private let extensionWindowKey = UUID().uuidString

    /// Spaces colored in this session; a stored projection never overrides them.
    private var locallyColoredSpaceIDs = Set<String>()

    /// Tabs whose video was sent to Picture in Picture on leaving them.
    private var pictureInPictureTabIDs = Set<String>()

    private let tabDriver: BrowserTabDriving
    private let sessionSnapshotStore: BrowserTabSessionSnapshotStoring
    private let sessionPreferencesStore: BrowserSessionPreferencesStoring
    private let newTabURLString: String
    private let commandBarSuggestionProvider: BrowserSuggestionProviding
    private let navigationResolver: BrowserNavigationResolver
    private let historyStore: BrowserHistorySearching
    private let extensionManager: any BrowserExtensionManaging
    private let extensionSidePanelDriver: (any BrowserExtensionSidePanelDriving)?
    private let extensionActionPopupDriver: (any BrowserExtensionActionPopupDriving)?
    private let syncCoordinator: BrowserSyncCoordinating?
    private let windowTitleHandler: (String) -> Void
    private let allTabsClosedHandler: () -> Void
    private let dateProvider: () -> Date
    private let spaceIDProvider: () -> String
    private let tabSyncIDProvider: () -> String
    private let commandHandler: (BrowserCommandID, BrowserChromeModel) -> Void

    private var hasCreatedInitialTab = false
    private var closingTabIDs = Set<String>()
    private var pendingTabCloseRequests = [String: PendingTabCloseRequest]()
    private var isCompletingTabClose = false
    private var localAutomaticArchiveCandidates = [LocalAutomaticArchiveCandidate]()
    private var isProcessingLocalAutomaticArchiveCandidates = false
    private var pendingSessionCompletions = [PendingSessionCompletion]()
    private var pendingHistoryRestore: PendingHistoryRestore?
    private var historyRestoreFailure: BrowserSessionPersistenceFailure?
    /// Where each open page keeps its data, nil for the window's own profile.
    private var engineProfilePathsByID = [String: String?]()
    private var isApplyingPeerSnapshot = false
    private var closedAppTabIDs = Set<String>()
    private var closedPinnedTabIDs = Set<String>()
    /// Unloaded pinned tabs restored at launch; they reopen at the page they
    /// showed last. Tabs the user unloaded reopen at their pinned URL.
    private var lastPageRestoreTabIDs = Set<String>()
    private var pendingReopenedAppTabCreations = [String: PendingReopenedTabCreation]()
    private var pendingReopenedPinnedTabCreations = [String: PendingReopenedTabCreation]()
    private var isPersistenceEnabled = true
    private var sessionWriteBuffer = BrowserSessionWriteBuffer()
    private var hasDiscardedSessionForClosure = false
    private var isSessionClosurePrepared = false
    /// A tab switch waiting to be saved.
    private var pendingSelectionPersist: Timer?
    private var isRestoringSession = false
    private var isApplyingRemoteSync = false
    private var deferredRemoteSyncSnapshot: BrowserTabSessionSnapshot?
    private var remoteProjectionSnapshot: BrowserTabSessionSnapshot?
    private var remoteProjectionGeneration = 0
    private var isReconcilingRemoteProjection = false
    private var hasLocalChangesDuringRemoteProjection = false
    private var needsRemoteFallbackPublication = false
    private var pendingRemoteTabCreations = [String: RemoteTabCreation]()
    private var discardedRemoteTabCreationIDs = Set<String>()
    private var pendingRestoredSelectedTabIndex: Int?
    private var restoredTabCreationIDs = Set<String>()
    private var pendingRestoredSpaces = [BrowserSpaceSessionSnapshot]()
    private var pendingCreatedTabContexts = [String: PendingCreatedTabContext]()
    private var pendingHydratedTabCreationIDs = Set<String>()
    private var tabCreationUndoReferences = [String: TabCreationUndoReference]()
    private var automaticArchivalTimer: Timer?
    private var automaticArchivalSettingsLoaded = false
    private var pendingAutomaticArchivalSettingsRetry: AutomaticArchivalSettingsRetry?

    private var isViewingActivityActive = true
    private var recentlySelectedTabIDs = [String]()
    private var tabPreviewImagesByID = [String: NSImage]()
    private var tabSwitcherPresentationTask: Task<Void, Never>?
    private var tabSwitcherSessionID = UUID()
    private var webAppManifestLoadTask: Task<Void, Never>?

    /// Opens a link in an incognito window; the application owns those windows.
    /// The session store, shared with the profile's other windows.
    var sharedSessionStore: BrowserTabSessionSnapshotStoring { sessionSnapshotStore }

    var hasUncommittedSessionWrites: Bool {
        !hasDiscardedSessionForClosure && (!sessionWriteBuffer.writes.isEmpty || sessionPersistenceFailure != nil)
    }

    var extensionSidePanelHostView: NSView? {
        extensionSidePanelDriver?.hostView
    }

    var extensionActionPopupHostView: NSView? {
        extensionActionPopupDriver?.hostView
    }

    var canCreateTab: Bool {
        isContextReady && !isShuttingDown
    }

    var canReload: Bool {
        canCreateTab && selectedTabID != nil
    }

    var selectedTabCreationState: BrowserTabCreationState? {
        selectedTab?.creationState
    }

    var canStopLoading: Bool {
        canCreateTab && (selectedTab?.isLoading ?? false)
    }

    var canSavePage: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canPasteAndMatchStyle: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canFindInPage: Bool {
        canCreateTab && selectedTab != nil
    }

    var canPresentFindInPage: Bool {
        canFindInPage
    }

    var canStepThroughFindMatches: Bool {
        canFindInPage && isFindBarPresented && !findQuery.isEmpty && findResultMatchCount != 0
    }

    var canPrintPage: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canCastPage: Bool {
        canCreateTab && selectedTabID != nil
    }

    var canCopySelectedTabLink: Bool {
        selectedTab != nil
    }

    /// A web page can be quoted; whether text is selected is known only on copying.
    var canCopySelectedTextAsQuoteLink: Bool {
        selectedTab.flatMap { URLComponents(string: $0.urlString)?.scheme?.lowercased() }
            .map { ["http", "https"].contains($0) } ?? false
    }

    var canInstallSelectedSiteAsApp: Bool {
        guard
            !windowMode.isIncognito,
            !windowMode.isWebApp,
            let pageURL = selectedTab?.pageURL,
            let selectedTabWebAppInstallMetadata,
            selectedTabWebAppInstallMetadata.manifestURL != nil
        else {
            return false
        }

        return selectedTabWebAppInstallMetadata.sourcePageURL == pageURL
    }

    var canLoadRemoteSearchSuggestions: Bool {
        userPreferencesStore.searchEngineSuggestionsEnabled && userPreferencesStore.searchEngine == .google
    }

    var selectedTabUsesWindowedBrowser: Bool {
        guard let selectedTab else {
            return false
        }

        return Self.usesWindowedBrowser(for: selectedTab.urlString)
    }

    var selectedTabInternalPage: BrowserInternalPage? {
        selectedTab.flatMap { Self.internalPage(for: $0.urlString) }
    }

    var canArchiveSelectedTab: Bool {
        selectedTab != nil && !isShuttingDown
    }

    var canClearTemporaryTabs: Bool {
        hasTemporaryTabs && !isShuttingDown
    }

    var canGoBack: Bool {
        selectedTab?.canGoBack ?? false
    }

    var canGoForward: Bool {
        selectedTab?.canGoForward ?? false
    }

    var hasTabs: Bool {
        !tabs.isEmpty
    }

    var isIncognito: Bool {
        windowMode.isIncognito
    }

    var isWebApp: Bool {
        windowMode.isWebApp
    }

    var currentTab: Tab? {
        selectedTab
    }

    /// The selected tab's page is in another window of this profile.
    var showsMovedPage: Bool {
        selectedTabID.map { movedPageTabIDs.contains($0) && hasNoPage($0) } ?? false
    }

    var movedPagePicture: NSImage? {
        showsMovedPage ? selectedTabID.flatMap { movedPagePictures[$0] } : nil
    }

    var showsProfileIndicator: Bool {
        windowMode == .normal && availableProfileCount > 1 && !profile.isDefault
    }

    var supportsSpaces: Bool {
        windowMode == .normal
    }

    var supportsAppTabs: Bool {
        windowMode == .normal
    }

    var appTabs: [Tab] {
        guard supportsAppTabs else {
            return []
        }

        return tabs.filter { $0.placement == .app }
    }

    var activeSpace: Space? {
        guard let selectedSpaceID else {
            return nil
        }

        return spaces.first { $0.id == selectedSpaceID }
    }

    var activeSpaceTabs: [Tab] {
        guard let selectedSpaceID else {
            return []
        }

        return tabs.filter { $0.spaceID == selectedSpaceID }
    }

    var pinnedTabs: [Tab] {
        spacePinnedTabs
    }

    var spacePinnedTabs: [Tab] {
        activeSpaceTabs.filter { $0.placement == .spacePinned }
    }

    var temporaryTabs: [Tab] {
        activeSpaceTabs.filter { $0.placement == .temporary }
    }

    var hasTemporaryTabs: Bool {
        !temporaryTabs.isEmpty
    }

    var isActiveSpacePinnedSectionCollapsed: Bool {
        activeSpace?.isPinnedSectionCollapsed ?? false
    }

    var usesSynchronizedAutomaticArchival: Bool {
        guard let ownership = sessionSnapshotStore as? any BrowserSyncOwnershipReading else { return false }
        do {
            return try ownership.syncOwner() != nil
        } catch {
            return true
        }
    }

    var canConfigureAutomaticTabArchival: Bool {
        guard canBrowseArchive, sessionPreferencesStore is BrowserSQLiteSessionStore,
              let ownership = sessionSnapshotStore as? any BrowserSyncOwnershipReading
        else { return false }
        return (try? ownership.syncOwner()) != nil
    }

    var canRetryAutomaticTabArchivalSettings: Bool {
        windowMode.persistsSession && !isShuttingDown && !hasDiscardedSessionForClosure &&
            pendingAutomaticArchivalSettingsRetry != nil
    }

    /// Arc's sidebar can only join a persistent window that is not busy with
    /// restore or sync.
    var canImportArcSidebar: Bool {
        supportsSpaces && windowMode.persistsSession && !isShuttingDown && !isRestoringSession
            && !isApplyingRemoteSync && !isReconcilingRemoteProjection
    }

    /// Open Location edits the selected tab's URL, which is the focused pane in a split.
    var canOpenLocation: Bool { canCreateTab && selectedTab != nil && !isWebApp }

    /// The small window for links from other apps, when turned on in Settings.
    var opensExternalLinksInLittleWindow: Bool {
        userPreferencesStore.littleArcEnabled && canOpenLittleWindow
    }

    /// The small window can open from this window, for a link rule or the setting.
    var canOpenLittleWindow: Bool { canCreateTab && !isWebApp && !isIncognito }

    var canShowDeveloperTools: Bool { canCreateTab && selectedTabID != nil && !isWebApp }

    var canZoomIn: Bool { canCreateTab && selectedTabID != nil && zoomPercent < (Self.zoomPercentages.last ?? 100) }
    var canZoomOut: Bool { canCreateTab && selectedTabID != nil && zoomPercent > (Self.zoomPercentages.first ?? 100) }
    var canResetZoom: Bool { canCreateTab && selectedTabID != nil && zoomPercent != 100 }

    /// The selected web page's HTML, as Chromium's view-source page.
    var canViewSource: Bool {
        guard canShowDeveloperTools, let url = selectedTab.flatMap({ URL(string: $0.urlString) }) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    var canCaptureArea: Bool { canCreateTab && selectedTab?.creationState == .ready && onBeginAreaCapture != nil }

    /// The theme of the selected Space, or nil for the neutral window.
    var selectedSpaceTheme: BrowserSpaceTheme? {
        if let spaceCreationDraft { return spaceCreationDraft.theme }
        guard supportsSpaces, let selectedSpaceID else { return nil }
        return spaceThemesByID[selectedSpaceID]
    }

    var canShareSelectedTab: Bool { selectedTab.flatMap { URL(string: $0.urlString) } != nil && onShareURL != nil }

    var canShowDeveloperToolsForCommand: Bool { selectedTabID != nil }

    /// The tab on screen, for bringing an additional window back at launch.
    var selectedTabSyncID: String? { tabs.first { $0.id == selectedTabID }?.syncID }

    var canTogglePictureInPicture: Bool {
        canCreateTab && selectedTabID.flatMap { tabMediaStates[$0]?.video } == true
    }

    /// The tab the sidebar shows as selected: the one that takes over while the selected tab's
    /// row has already gone.
    var sidebarSelectedTabID: String? {
        guard let selectedTabID, tabsLeavingSidebar.contains(selectedTabID),
              let closing = tabs.first(where: { $0.id == selectedTabID })
        else { return selectedTabID }
        return fallbackTabID(afterClosingDormantTab: closing, excluding: tabsLeavingSidebar)
    }

    /// The menu says what the command will do now.
    var pictureInPictureMenuTitle: String {
        selectedTabID.map(isInPictureInPicture) == true
            ? BrowserStrings.menuClosePictureInPicture
            : BrowserStrings.menuOpenPictureInPicture
    }

    /// The bar's "Add Page" starts from the page on screen.
    var pageForNewBookmark: (title: String, urlString: String) {
        (currentTab?.title ?? "", currentTab?.urlString ?? "")
    }

    /// The Library sections this window offers. Incognito and blank windows keep
    /// Media and Downloads; they have no Spaces or Archive of their own.
    var librarySections: [BrowserLibrarySection] {
        switch windowMode {
        case .normal: BrowserLibrarySection.allCases
        case .blank, .incognito: [.media, .downloads]
        case .webApp: []
        }
    }

    var hasLibrary: Bool { !librarySections.isEmpty }

    var canRegisterTabUndo: Bool {
        isContextReady && isPersistenceEnabled && !isRestoringSession && !isShuttingDown
    }

    private var canAdmitLocalAutomaticArchive: Bool {
        isContextReady && windowMode.persistsSession && isPersistenceEnabled && !isShuttingDown &&
            !hasDiscardedSessionForClosure && !hasUncommittedSessionWrites && !isRestoringSession &&
            !isApplyingRemoteSync && !isReconcilingRemoteProjection && !isArchiveOperationInFlight &&
            !isCompletingTabClose && !undoManager.isTabTransitionPending && pendingTabCloseRequests.isEmpty
    }

    private var selectedTab: Tab? {
        guard let selectedTabID else {
            return nil
        }

        return tabs.first(where: { $0.id == selectedTabID })
    }

    private var selectedTabIndex: Int? {
        guard let selectedTabID else {
            return nil
        }

        return tabs.firstIndex(where: { $0.id == selectedTabID })
    }

    private var selectedSpaceIndex: Int? {
        guard let selectedSpaceID else {
            return nil
        }

        return spaces.firstIndex(where: { $0.id == selectedSpaceID })
    }

    private var telemetryProperties: [String: String] {
        [
            "profile": profile.isDefault ? "default" : "custom",
            "window_mode": windowMode.telemetryValue,
            "space_count": "\(spaces.count)",
            "tab_count": "\(tabs.count)",
        ]
    }

    init(
        tabDriver: BrowserTabDriving,
        sessionSnapshotStore: BrowserTabSessionSnapshotStoring,
        sessionPreferencesStore: BrowserSessionPreferencesStoring,
        newTabURLString: String = BrowserChromeModel.defaultNewTabURLString,
        commandBarSuggestionProvider: BrowserSuggestionProviding = BrowserGoogleSuggestionService(),
        navigationResolver: BrowserNavigationResolver? = nil,
        userPreferencesStore: BrowserUserPreferencesStore = BrowserUserPreferencesStore(),
        shortcutStore: BrowserShortcutStore = BrowserShortcutStore(),
        bookmarksModel: BrowserBookmarksModel? = nil,
        historyStore: BrowserHistorySearching = BrowserEmptyHistoryStore(),
        downloadsModel: BrowserDownloadsModel? = nil,
        extensionManager: any BrowserExtensionManaging,
        extensionSidePanelDriver: (any BrowserExtensionSidePanelDriving)? = nil,
        extensionActionPopupDriver: (any BrowserExtensionActionPopupDriving)? = nil,
        syncCoordinator: BrowserSyncCoordinating? = nil,
        windowMode: BrowserWindowMode = .normal,
        profile: BrowserProfile = .defaultProfile,
        availableProfileCount: Int = 1,
        dateProvider: @escaping () -> Date = Date.init,
        spaceIDProvider: @escaping () -> String = { UUID().uuidString },
        tabSyncIDProvider: @escaping () -> String = { UUID().uuidString },
        commandHandler: @escaping (BrowserCommandID, BrowserChromeModel) -> Void = { _, _ in },
        windowTitleHandler: @escaping (String) -> Void,
        allTabsClosedHandler: @escaping () -> Void,
    ) {
        self.tabDriver = tabDriver
        self.sessionSnapshotStore = sessionSnapshotStore
        self.sessionPreferencesStore = sessionPreferencesStore
        self.newTabURLString = newTabURLString
        self.commandBarSuggestionProvider = commandBarSuggestionProvider
        self.userPreferencesStore = userPreferencesStore
        self.shortcutStore = shortcutStore
        self.bookmarksModel = bookmarksModel ?? BrowserBookmarksModel()
        self.historyStore = historyStore
        self.downloadsModel = downloadsModel ?? BrowserDownloadsModel()
        self.navigationResolver = navigationResolver ?? BrowserNavigationResolver(
            searchEngineProvider: { userPreferencesStore.searchEngine },
        )
        self.extensionManager = extensionManager
        self.extensionSidePanelDriver = extensionSidePanelDriver
        self.extensionActionPopupDriver = extensionActionPopupDriver
        self.syncCoordinator = syncCoordinator
        self.windowMode = windowMode
        self.profile = profile
        self.profileDisplayName = profile.displayName
        self.availableProfileCount = availableProfileCount
        self.isPersistenceEnabled = windowMode.persistsSession
        self.temporaryTabLifetime = sessionPreferencesStore.loadTemporaryTabLifetime()
        self.localAutomaticArchivalOff = sessionPreferencesStore.loadLocalAutomaticArchivalOff()
        self.pinnedExtensionIDs = userPreferencesStore.pinnedExtensionIDs
        self.dateProvider = dateProvider
        self.spaceIDProvider = spaceIDProvider
        self.tabSyncIDProvider = tabSyncIDProvider
        self.commandHandler = commandHandler
        self.windowTitleHandler = windowTitleHandler
        self.allTabsClosedHandler = allTabsClosedHandler
        self.hostView = tabDriver.hostView

        super.init()
        undoManager.groupsByEvent = false
        undoManager.canPerformTabAction = { [weak self] in
            guard let self else { return false }
            return canRegisterTabUndo && !isCompletingTabClose && !hasUncommittedSessionWrites &&
                !isApplyingRemoteSync &&
                !isArchiveOperationInFlight && pendingRemoteTabCreations.isEmpty
        }
        tabDriver.onTabCreated = { [weak self] tabID, title, urlString, isActive in
            self?.handleCreatedTab(id: tabID, title: title, urlString: urlString, isActive: isActive)
        }
        tabDriver.onTabCreationStateChanged = { [weak self] tabID, state in
            self?.handleTabCreationStateChange(id: tabID, state: state)
        }
        tabDriver.onTabUpdated = { [weak self] tabID, title, urlString, faviconURLString in
            self?.handleUpdatedTab(
                id: tabID,
                title: title,
                urlString: urlString,
                faviconURLString: faviconURLString,
            )
        }
        tabDriver.onStatusChanged = { [weak self] tabID, status in
            guard let self, tabID == selectedTabID else { return }
            self.linkStatus = status.isEmpty ? nil : status
        }
        tabDriver.onTabCloseConfirmationPresented = { [weak self] tabID in
            // The page asks the user, so its row stays while the question is open.
            self?.tabsLeavingSidebar.remove(tabID)
        }
        tabDriver.onTabCloseRequestFinished = { [weak self] tabID, requestID, outcome in
            self?.handleTabCloseRequestFinished(id: tabID, requestID: requestID, outcome: outcome)
        }
        tabDriver.onTabClosed = { [weak self] tabID in
            self?.handleClosedTab(id: tabID)
        }
        tabDriver.onDownloadWithoutPage = { [weak self] tabID in
            self?.closeTabThatOnlyDownloaded(id: tabID)
        }
        tabDriver.searchEngineName = { [weak self] in self?.userPreferencesStore.searchEngine.title }
        tabDriver.onTabOpenedFromTab = { [weak self] tabID, openerTabID in
            self?.placeTabOpened(id: tabID, fromTabID: openerTabID)
        }
        tabDriver.onPageFullscreenChanged = { [weak self] tabID, fullscreen in
            guard let self else { return }
            if fullscreen {
                self.pageFullscreenTabID = tabID
            } else if pageFullscreenTabID == tabID {
                self.pageFullscreenTabID = nil
            }
        }
        tabDriver.onTabFocused = { [weak self] tabID in
            self?.handleSplitPaneFocused(tabID)
        }
        tabDriver.onSplitResized = { [weak self] tabIDs, fractions in
            self?.handleSplitResize(tabIDs: tabIDs, fractions: fractions)
        }
        tabDriver.onSplitPaneLayout = { [weak self] tabIDs, frames in
            self?.handleSplitPaneLayout(tabIDs: tabIDs, frames: frames)
        }
        tabDriver.shouldPeekNavigation = { [weak self] tabID, urlString in
            self?.peeksNavigation(fromTabWithID: tabID, toURLString: urlString) ?? false
        }
        tabDriver.peekSpaces = { [weak self] in
            guard let self, supportsSpaces, canCreateTab else { return [] }
            return spaces.map {
                BrowserPeekSpace(
                    id: $0.id,
                    title: $0.title,
                    systemImageName: $0.systemImageName,
                    isSelected: $0.id == selectedSpaceID,
                    tint: spaceThemesByID[$0.id]?.palette?.key.nsColor(alpha: 1),
                )
            }
        }
        tabDriver.onPeekClosedByUser = { [weak self] urlString, standalone in
            self?.registerPeekReopenUndo(urlString: urlString, standalone: standalone)
        }
        tabDriver.onOpenPeekInSplitView = { [weak self] urlString in
            guard let self, let url = URL(string: urlString), !openURLInSplitView(url) else { return }
            openURLInNewTab(url)
        }
        tabDriver.onPageContextCommand = { [weak self] command, argument in
            self?.handlePageContextCommand(command, argument: argument)
        }
        tabDriver.onSitePermissionRequested = { [weak self] request in
            self?.handleSitePermissionRequest(request)
        }
        tabDriver.onSitePermissionRequestDismissed = { [weak self] id in
            self?.handleSitePermissionRequestDismissed(id: id)
        }
        tabDriver.onAddressFormFound = { [weak self] tabID, frameID, urlString in
            self?.handleAddressFormFound(tabID: tabID, frameID: frameID, urlString: urlString)
        }
        tabDriver.onCardFormFound = { [weak self] tabID, frameID, urlString in
            self?.handleCardFormFound(tabID: tabID, frameID: frameID, urlString: urlString)
        }
        tabDriver.onAddressSubmitted = { [weak self] tabID, urlString, json in
            self?.handleAddressSubmitted(tabID: tabID, urlString: urlString, json: json)
        }
        tabDriver.onPasswordFormFound = { [weak self] tabID, frameID, urlString in
            self?.handlePasswordFormFound(tabID: tabID, frameID: frameID, urlString: urlString)
        }
        tabDriver.onPasswordSubmitted = { [weak self] tabID, urlString, username, password in
            self?.handlePasswordSubmitted(tabID: tabID, urlString: urlString, username: username, password: password)
        }
        tabDriver.onMediaStateChanged = { [weak self] tabID, state in
            self?.handleMediaStateChange(tabID: tabID, state: state)
        }
        tabDriver.onCaptureChanged = { [weak self] tabID, capturing in
            self?.handleCaptureChange(tabID: tabID, capturing: capturing)
        }
        tabDriver.onPeekPagesChanged = { [weak self] pages in
            self?.peekPagesByTabID = pages
        }
        tabDriver.onRenderProcessTerminated = { [weak self] tabID, errorCode in
            self?.handleRenderProcessTerminated(tabID: tabID, errorCode: errorCode)
        }
        tabDriver.onPeekSitePermissionAnswered = { [weak self] id, allowed in
            if let allowed {
                self?.answerSitePermissionRequest(id: id, allowed: allowed)
            } else {
                self?.dismissSitePermissionRequest(id: id)
            }
        }
        self.sitePermissionDecisionsObservation = userPreferencesStore.$sitePermissionDecisions
            .dropFirst()
            .sink { [weak self] decisions in
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard !windowMode.isIncognito else { return }
                    resolveSitePermissionRequests(coveredBy: decisions)
                }
            }
        let center = NotificationCenter.default
        self.extensionTabsObservation = $tabs.map { _ in () }
            .merge(
                with: $selectedTabID.map { _ in () },
                $spaces.map { _ in () },
                center.publisher(for: NSWindow.didBecomeKeyNotification).map { _ in () },
                center.publisher(for: NSWindow.didResignKeyNotification).map { _ in () },
            )
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reportExtensionTabs() }
            }
        tabDriver.onOpenPeekInSpace = { [weak self] urlString, spaceID in
            guard let self, let url = URL(string: urlString), !openURL(url, inSpaceWithID: spaceID) else { return }
            openURLInNewTab(url)
        }
        tabDriver.onNavigationStateChanged = { [weak self] tabID, canGoBack, canGoForward in
            self?.handleNavigationStateChange(
                id: tabID,
                canGoBack: canGoBack,
                canGoForward: canGoForward,
            )
        }
        tabDriver.onLoadingStateChanged = { [weak self] tabID, isLoading in
            self?.handleLoadingStateChange(id: tabID, isLoading: isLoading)
        }
        tabDriver.onFindResultChanged = { [weak self] tabID, matchCount, activeMatchOrdinal, finalUpdate in
            self?.handleFindResult(
                id: tabID,
                matchCount: matchCount,
                activeMatchOrdinal: activeMatchOrdinal,
                finalUpdate: finalUpdate,
            )
        }
        tabDriver.onDownloadUpdated = { [weak self] update in
            self?.handleDownloadUpdate(update)
        }
        self.downloadsModel.onCancel = { [weak self] id in
            self?.tabDriver.cancelDownload(id: id)
        }
        extensionSidePanelDriver?.onPanelClosed = { [weak self] panelID in
            self?.handleExtensionSidePanelClosed(panelID: panelID)
        }
        reloadAutomaticTabArchivalSettings()
        syncCoordinator?.setExpiryScheduler(self)
        updateWindowTitle()
    }

    /// For pages the engine cannot translate: they open in Google's, in the system language.
    static func translatedPageURL(for urlString: String, language: String) -> URL? {
        guard let scheme = URLComponents(string: urlString)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        var components = URLComponents(string: "https://translate.google.com/translate")
        components?.queryItems = [
            .init(name: "sl", value: "auto"),
            .init(name: "tl", value: language),
            .init(name: "u", value: urlString),
        ]
        return components?.url
    }

    /// Chromium names only Chinese with a region.
    nonisolated static func translationLanguage(forPreferredLanguage language: String?) -> String {
        guard let language, !language.isEmpty else { return "en" }
        if language.hasPrefix("zh") {
            return language.contains("Hant") || language.contains("TW") || language.contains("HK") ? "zh-TW" : "zh-CN"
        }
        return String(language.prefix(2))
    }

    /// Finished pages of this window, in sidebar order. Pages still being
    /// created have nothing for an extension to reach.
    nonisolated static func extensionTabReports(tabs: [Tab], selectedTabID: String?) -> [BrowserExtensionTabReport] {
        tabs.filter { $0.creationState == .ready }.enumerated().map { index, tab in
            BrowserExtensionTabReport(
                tabID: tab.id,
                index: index,
                isActive: tab.id == selectedTabID,
                isPinned: tab.placement != .temporary,
            )
        }
    }

    /// The shown tab of each other Space, most recently used first, up to four.
    nonisolated static func warmTabIDs(
        spaces: [Space],
        selectedSpaceID: String?,
        tabs: [Tab],
    ) -> [String] {
        let ready = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return spaces
            .filter { $0.id != selectedSpaceID }
            .compactMap { space in space.selectedTabID.flatMap { ready[$0] } }
            .filter { $0.creationState == .ready }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(4)
            .map(\.id)
    }

    /// An open tab as a page to open, with its icon and without its Space.
    static func pageSuggestion(forTabSuggestion suggestion: BrowserCommandSuggestion) -> BrowserCommandSuggestion {
        guard suggestion.kind == .openTab else { return suggestion }
        var page = BrowserCommandSuggestion(
            kind: .history,
            displayText: suggestion.displayText,
            detailText: BrowserURLDisplayFormatter.displayString(for: suggestion.resolvedURLString),
            resolvedURLString: suggestion.resolvedURLString,
        )
        page.faviconURL = suggestion.faviconURL
        return page
    }

    /// Use Selection to Find: the page copies its selection to the find
    /// pasteboard, read after a short round trip because Chromium writes it
    /// asynchronously and reports nothing when the text is unchanged.
    @discardableResult func useSelectionForFind() -> Bool {
        let before = findPasteboardChangeCount()
        guard canPresentFindInPage, let tabID = selectedTabID,
              tabDriver.sendActionToActivePage(Selector(("copyToFindPboard:")))
        else { return false }
        awaitSelectionForFind(changedFrom: before, tabID: tabID, attempts: Self.findPasteboardAttempts)
        return true
    }

    /// Format › Font: the page's own editing command on its selection.
    func applyTextStyle(_ style: BrowserTextStyle) {
        guard canFindInPage, let tabID = selectedTabID else { return }
        tabDriver.evaluateJavaScript(
            "document.execCommand('\(style.rawValue)'); undefined",
            inTabWithID: tabID,
            completion: { _ in },
        )
    }

    /// Scrolls the page's selection into view, even with focus in the find field.
    @discardableResult func jumpToSelection() -> Bool {
        guard canFindInPage else { return false }
        return tabDriver.sendActionToActivePage(#selector(NSResponder.centerSelectionInVisibleArea(_:)))
    }

    /// Peek for pinned tabs and Favorites, when turned on in Settings: a
    /// clicked link, or its redirect, to another site opens in Peek and the tab
    /// keeps its page. The site shown and the pinned site both count as the
    /// tab's own, so a link back home stays in the tab.
    func peeksNavigation(fromTabWithID tabID: String, toURLString urlString: String) -> Bool {
        guard userPreferencesStore.peeksLinksToOtherSites, !isWebApp,
              let tab = tabs.first(where: { $0.id == tabID }), tab.placement != .temporary,
              let current = URL(string: tab.urlString), let target = URL(string: urlString),
              [current, target].allSatisfy({ ["http", "https"].contains($0.scheme?.lowercased() ?? "") })
        else { return false }
        let home = tab.pinnedURLString.flatMap(URL.init(string:))
        return !BrowserSite.isSameSite(current, target) && !(home.map { BrowserSite.isSameSite($0, target) } ?? false)
    }

    @discardableResult func retrySessionPersistence() -> Bool {
        guard !hasDiscardedSessionForClosure, !sessionWriteBuffer.isTerminal else { return false }
        if !sessionWriteBuffer.writes.isEmpty {
            let hasLocalWrite = sessionWriteBuffer.writes.contains {
                if case .local = $0.origin {
                    return true
                }
                return false
            }
            guard commitSessionWrites(sessionWriteBuffer.writes, schedulesPush: hasLocalWrite) else { return false }
        }
        if pendingHistoryRestore != nil {
            return retryHistoryRestore()
        }
        return sessionPersistenceFailure == nil
    }

    /// Closure preflight is reversible. Teardown must only run after it succeeds
    /// or the user explicitly chooses to discard the volatile session changes.
    @discardableResult func prepareSessionForClosure() -> Bool {
        guard !hasDiscardedSessionForClosure, isPersistenceEnabled else { return true }
        guard !sessionWriteBuffer.isTerminal else { return false }
        // Close/quit Retry uses this same preflight. A failed commit-first Undo
        // has no buffered snapshot, so ordinary snapshot persistence alone
        // cannot finish it or clear its failure.
        if pendingHistoryRestore != nil, !retrySessionPersistence() {
            return false
        }
        recordCurrentViewingActivity()
        persistCurrentSessionIfAllowed()
        isSessionClosurePrepared = !hasUncommittedSessionWrites
        return isSessionClosurePrepared
    }

    func discardUnsavedSessionForClosure() {
        hasDiscardedSessionForClosure = true
        pendingSessionCompletions.removeAll()
        pendingHistoryRestore = nil
        historyRestoreFailure = nil
        undoManager.removeAllActions()
        isPersistenceEnabled = false
        deferredRemoteSyncSnapshot = nil
        syncCoordinator?.setLocalPersistenceBlocked(true)
    }

    func sessionRecoverySnapshot() -> BrowserTabSessionSnapshot {
        isApplyingRemoteSync ? snapshotPreservingPendingRemoteCreations() : currentSessionSnapshot()
    }

    func webAppInstallMetadata(for tab: Tab) -> BrowserWebAppInstallMetadata? {
        guard
            tab.id == selectedTabID,
            let pageURL = tab.pageURL,
            let selectedTabWebAppInstallMetadata,
            selectedTabWebAppInstallMetadata.sourcePageURL == pageURL,
            selectedTabWebAppInstallMetadata.manifestURL != nil
        else {
            return nil
        }

        return selectedTabWebAppInstallMetadata
    }

    func waitForPendingWebAppManifestLoad() async {
        await webAppManifestLoadTask?.value
    }

    func handleContextReady() {
        guard !isContextReady else {
            return
        }

        historyStore.prepareSearchIndex()
        isContextReady = true
        extensionManager.enableDefaultExtensionsOnce()
        restoreSidebarWidthIfNeeded()
        bookmarksModel.reload()
        refreshBrowserExtensions()
        startAutomaticArchivalTimerIfNeeded()

        if drainDeferredRemoteSyncSnapshot() {
            syncCoordinator?.schedulePull()
            return
        }

        if restoreSessionIfAvailable() {
            syncCoordinator?.schedulePull()
            return
        }

        ensureDefaultSpace()
        ensureInitialTab()
        archiveExpiredTemporaryTabs()
        syncCoordinator?.schedulePull()
    }

    func prepareForTermination() {
        guard !isShuttingDown else {
            return
        }

        // Close/quit already performed a reversible preflight. Do not introduce
        // an unguarded second write after the controller approved destruction.
        if !isSessionClosurePrepared, !hasDiscardedSessionForClosure {
            recordCurrentViewingActivity()
            persistCurrentSessionIfAllowed()
        }
        guard !hasUncommittedSessionWrites else { return }
        automaticArchivalTimer?.invalidate()
        automaticArchivalTimer = nil
        webAppManifestLoadTask?.cancel()
        webAppManifestLoadTask = nil
        undoManager.removeAllActions()
        extensionSidePanelDriver?.closeAllPanels()
        extensionActionPopupDriver?.closeAllPopups()
        extensionSidePanel = nil
        tabDriver.closePeeks()
        persistSidebarWidthPreferenceIfAllowed()
        isShuttingDown = true
        isPersistenceEnabled = false
        syncCoordinator?.setRuntimeActive(false)
        syncCoordinator?.setExpiryScheduler(nil)
    }

    func prepareForCefShutdown() {
        prepareForTermination()
        tabDriver.prepareForCefShutdown()
    }

    func createNewTab() {
        createTab(withURLString: newTabURLString, placesAtTop: true)
    }

    /// A new Today tab; `atTop` puts it at the top of Today, with the other
    /// tabs a person opens.
    func openURLInNewTab(_ url: URL, atTop: Bool = false) {
        createTab(withURLString: url.absoluteString, placesAtTop: atTop)
    }

    /// A new temporary tab that loads without becoming the selected one.
    @discardableResult func openURLInBackgroundTab(_ url: URL) -> String? {
        createTab(withURLString: url.absoluteString, makeActive: false)
    }

    /// Runs what a page's context menu asked for.
    func handlePageContextCommand(_ command: BrowserPageContextCommand, argument: String) {
        switch command {
        case .openInSplitView:
            guard let url = URL(string: argument), !openURLInSplitView(url) else { return }
            openURLInNewTab(url)
        case .openInIncognito:
            if let url = URL(string: argument) { onOpenLinkInIncognito?(url) }
        case .openInNewWindow:
            guard let url = URL(string: argument) else { return }
            if onOpenLinkInNewWindow?(url) != true {
                openURLInNewTab(url)
            }
        case .cast:
            castCurrentPage()
        case .translatePage:
            _ = translateCurrentPage()
        case .copyLinkToHighlight:
            Task { [weak self] in _ = await self?.copySelectedTextAsQuoteLink() }
        case .searchForSelection:
            let search = userPreferencesStore.searchEngine.searchURLString(for: argument)
            if let url = URL(string: search) { openURLInNewTab(url) }
        case .savePage:
            if canSavePage { onSavePageRequest?() }
        case .viewSource:
            _ = viewSourceOfSelectedTab()
        case .importPasswords:
            onImportFromBrowser?()
        }
    }

    /// Link drop on the sidebar: each link opens as a background tab at
    /// the drop's place in the selected Space, pinned in a pinned section or
    /// folder. Favorites take no links.
    @discardableResult func openURLs(_ urls: [URL], at destination: BrowserSidebarDropDestination) -> Bool {
        guard canCreateTab, !urls.isEmpty, destination.container.section != .app,
              destination.container.spaceID == selectedSpaceID
        else { return false }
        let ids = urls.compactMap { url in createTab(withURLString: url.absoluteString, makeActive: false) }
        guard let first = ids.first else { return false }
        // The tabs are open even if their place went away during the drag;
        // they stay at the end of Today then.
        commitSidebarDrop(payload: .init(primary: .tab(first), tabIDs: Set(ids)), destination: destination)
        return true
    }

    /// Link route: shows the Space and opens the link as its tab.
    /// False when the Space is gone, so the link can open as usual.
    @discardableResult func openURL(_ url: URL, inSpaceWithID spaceID: String) -> Bool {
        guard canCreateTab, supportsSpaces, spaces.contains(where: { $0.id == spaceID }) else { return false }
        selectSpace(id: spaceID)
        openURLInNewTab(url)
        return true
    }

    func openBookmark(urlString: String) {
        BrowserTelemetry.captureUsage(.bookmarkOpened, properties: telemetryProperties)
        navigateSelectedTabOrOpenNewTab(toURLString: urlString)
    }

    @discardableResult func addSelectedTabBookmark() -> Bool {
        guard let selectedTab, !selectedTab.urlString.isEmpty else {
            return false
        }

        return bookmarksModel.addBookmark(
            title: selectedTab.displayTitle,
            urlString: selectedTab.urlString,
        )
    }

    @discardableResult func toggleSelectedTabBookmark() -> Bool {
        guard let selectedTab, !selectedTab.urlString.isEmpty else {
            return false
        }

        return bookmarksModel.toggleBookmark(
            title: selectedTab.displayTitle,
            urlString: selectedTab.urlString,
        )
    }

    @discardableResult func renameBookmark(id: String, title: String) -> Bool {
        bookmarksModel.renameBookmark(id: id, title: title)
    }

    @discardableResult func updateBookmarkAddress(id: String, urlString: String) -> Bool {
        bookmarksModel.updateBookmarkAddress(id: id, urlString: urlString)
    }

    @discardableResult func moveBookmark(id: String, toFolderID: String?) -> Bool {
        bookmarksModel.moveBookmark(id: id, toFolderID: toFolderID)
    }

    @discardableResult func createBookmarkFolder(title: String) -> String? {
        bookmarksModel.createFolder(title: title)
    }

    @discardableResult func createBookmarkFolderAndMoveBookmark(title: String, bookmarkID: String) -> Bool {
        bookmarksModel.createFolderAndMoveBookmark(title: title, bookmarkID: bookmarkID)
    }

    /// The toolbar shows while it is being customized.
    func beginToolbarCustomization() {
        userPreferencesStore.siteURLToolbarEnabled = true
        isCustomizingToolbar = true
    }

    func endToolbarCustomization() { isCustomizingToolbar = false }

    func executeDevTools(
        method: String,
        paramsJSON: String,
        tabID: String,
        completion: @escaping @MainActor (String?) -> Void,
    ) {
        tabDriver.executeDevTools(method: method, paramsJSON: paramsJSON, tabID: tabID, completion: completion)
    }

    func fillPasswordInMainFrame(username: String, password: String, origin: String, tabID: String) -> Bool {
        tabDriver.fillPasswordInMainFrame(username: username, password: password, origin: origin, tabID: tabID)
    }

    /// Copies what the person chose from another browser, and reports it in one line.
    func importProfile(
        _ profile: BrowserProfileImporter,
        items: Set<BrowserOnboardingImportItem>,
    ) async -> String {
        var parts = [String]()
        if items.contains(.spaces), profile.source == .arc {
            parts.append(importArcSidebarFromDisk())
        }
        if items.contains(.bookmarks) {
            let result = importBookmarks(from: profile.source)
            if result.importedCount > 0 {
                parts.append(BrowserStrings.onboardingImportCount(
                    result.importedCount,
                    BrowserStrings.onboardingItemBookmarks,
                ))
            }
        }
        if items.contains(.siteSearches), let imported = BrowserSiteSearchImport.load(from: profile.source) {
            userPreferencesStore.siteSearches = BrowserSiteSearchImport.merge(
                imported,
                into: userPreferencesStore.siteSearches,
            )
            if !imported.isEmpty {
                parts.append(BrowserStrings.onboardingImportCount(
                    imported.count,
                    BrowserStrings.onboardingItemSiteSearches,
                ))
            }
        }
        if items.contains(.history) {
            let documents = await Task.detached(priority: .userInitiated) { profile.history() }.value
            historyStore.importDocuments(documents)
            if !documents.isEmpty {
                parts.append(BrowserStrings.onboardingImportCount(
                    documents.count,
                    BrowserStrings.onboardingItemHistory,
                ))
            }
        }
        if items.contains(.passwords) || items.contains(.signIns), let key = try? profile.encryptionKey() {
            if items.contains(.passwords), let passwordStore {
                let logins = await Task.detached(priority: .userInitiated) { profile.logins(key: key) }.value
                let saved = logins.filter { passwordStore.save($0.password, for: $0.login) }.count
                if saved > 0 {
                    parts.append(BrowserStrings.onboardingImportCount(saved, BrowserStrings.onboardingItemPasswords))
                }
            }
            if items.contains(.signIns) {
                let cookies = await Task.detached(priority: .userInitiated) { profile.cookies(key: key) }.value
                let set = tabDriver.importCookies(cookies)
                if set > 0 {
                    parts.append(BrowserStrings.onboardingImportCount(set, BrowserStrings.onboardingItemSignIns))
                }
            }
        }
        if items.contains(.extensions) {
            let urls = profile.extensionStoreURLs()
            for url in urls {
                openURLInNewTab(url)
            }
            if !urls.isEmpty {
                parts.append(BrowserStrings.onboardingImportCount(urls.count, BrowserStrings.onboardingItemExtensions))
            }
        }
        return BrowserStrings.onboardingImportResult(parts)
    }

    /// A toolbar button runs its command as the command bar would.
    func performToolbarCommand(_ id: BrowserCommandID) { commandHandler(id, self) }

    @discardableResult func deleteBookmark(id: String) -> Bool {
        bookmarksModel.deleteBookmark(id: id)
    }

    @discardableResult func moveBookmark(id: String, toFolderID: String?, atIndex index: Int) -> Bool {
        bookmarksModel.moveBookmark(id: id, toFolderID: toFolderID, atIndex: index)
    }

    @discardableResult func insertBookmark(
        title: String,
        urlString: String,
        toFolderID: String?,
        atIndex index: Int? = nil,
    ) -> Bool {
        bookmarksModel.insertBookmark(title: title, urlString: urlString, toFolderID: toFolderID, atIndex: index) != nil
    }

    @discardableResult func insertBookmarkFolder(
        title: String,
        toFolderID: String?,
        atIndex index: Int? = nil,
    ) -> Bool {
        bookmarksModel.insertFolder(title: title, toFolderID: toFolderID, atIndex: index) != nil
    }

    func openBookmarkInLittleWindow(urlString: String) {
        if let url = URL(string: urlString) { openInLittleWindow(url) }
    }

    func openBookmarkInIncognito(urlString: String) {
        if let url = URL(string: urlString) { onOpenLinkInIncognito?(url) }
    }

    func openBookmarkInSplitView(urlString: String) {
        if let url = URL(string: urlString) { _ = openURLInSplitView(url) }
    }

    func openBookmarks(_ urlStrings: [String]) {
        for urlString in urlStrings where !urlString.isEmpty {
            createTab(withURLString: urlString)
        }
    }

    func openBookmarksManager() {
        openURLInNewTab(BrowserInternalPageRouting.bookmarksURL, atTop: true)
    }

    @discardableResult func importBookmarks(from source: BrowserBookmarkImportSource) -> BrowserBookmarkImportResult {
        bookmarksModel.importBookmarks(from: source)
    }

    func isBookmarked(urlString: String) -> Bool {
        bookmarksModel.containsBookmark(urlString: urlString)
    }

    /// Adds Arc's Spaces with their pinned tabs and folders, and its Favorites
    /// up to the app tile capacity. Imported tabs are dormant, like pinned tabs
    /// closed earlier: their pages load when first selected. The current Space
    /// and selection stay as they are.
    /// Imports Arc's sidebar from its file on this Mac and says what came of
    /// it, including why nothing did.
    func importArcSidebarFromDisk(at url: URL? = BrowserArcSidebar.defaultFileURL) -> String {
        guard canImportArcSidebar else { return BrowserStrings.arcImportUnavailable }
        guard let url else { return BrowserStrings.arcImportMissing }
        let sidebar: BrowserArcSidebar
        do {
            sidebar = try BrowserArcSidebar.load(from: url)
        } catch BrowserArcSidebar.ImportError.missing {
            return BrowserStrings.arcImportMissing
        } catch {
            return BrowserStrings.arcImportUnreadable
        }
        let result = importArcSidebar(sidebar)
        guard result.isEmpty else {
            return BrowserStrings.arcImportResult(
                spaces: result.spaceCount,
                pinnedTabs: result.pinnedTabCount,
                folders: result.folderCount,
                favorites: result.favoriteCount,
            )
        }
        // Spaces skipped as already imported, not an empty sidebar.
        return sidebar.spaces.isEmpty ? BrowserStrings.arcImportNothing : BrowserStrings.arcImportAlreadyImported
    }

    @discardableResult func importArcSidebar(_ sidebar: BrowserArcSidebar) -> BrowserArcSidebarImportResult {
        guard canImportArcSidebar else { return .init() }
        var result = BrowserArcSidebarImportResult()
        let now = dateProvider()

        func dormantTab(
            _ node: BrowserArcSidebar.Node,
            spaceID: String,
            folderID: String?,
            placement: BrowserTabPlacement,
        )
            -> Tab?
        {
            guard case .tab(let title, let savedTitle, let urlString) = node else { return nil }
            let id = UUID().uuidString
            restoredTabCreationIDs.insert(id)
            return Tab(
                id: id,
                syncID: tabSyncIDProvider(),
                spaceID: spaceID,
                title: savedTitle ?? "",
                userTitleOverride: sanitizedUserTitleOverride(from: title),
                urlString: urlString,
                pinnedURLString: placement.keepsPinnedURL ? normalizedPinnedURLString(from: urlString) : nil,
                placement: placement,
                pinnedFolderID: folderID,
                lastActivityAt: now,
            )
        }

        func pinnedURLs(_ urls: [String]) -> Set<String> {
            Set(urls.map { comparablePinnedURLString(normalizedPinnedURLString(from: $0) ?? $0) })
        }
        // A Space imported before, with the same title and pinned pages, is skipped.
        let existing = spaces.map { space in
            (title: space.title, urls: pinnedURLs(tabs.filter { $0.spaceID == space.id && $0.placement == .spacePinned }
                    .map { $0.pinnedURLString ?? $0.urlString }))
        }
        for arcSpace in sidebar.spaces {
            let title = sanitizedSpaceTitle(from: arcSpace.title)
            let arcURLs = pinnedURLs(arcSpace.pinned.flatMap(\.tabs).compactMap { node in
                if case .tab(_, _, let url) = node {
                    url
                } else {
                    nil
                }
            })
            if let title, existing.contains(where: { $0.title == title && arcURLs.isSubset(of: $0.urls) }) {
                continue
            }
            var space = makeSpace()
            spaceThemesByID[space.id] = arcSpace.theme
            if let title {
                space.title = title
            }
            if let icon = arcSpace.icon, BrowserIconImage.isValid(icon) {
                space.systemImageName = icon
            }
            spaces.append(space)
            var folderChildren = [String: [BrowserSidebarItemID]]()
            func add(_ nodes: [BrowserArcSidebar.Node], folderID: String?) -> [BrowserSidebarItemID] {
                nodes.compactMap { node in
                    switch node {
                    case .tab:
                        guard let tab = dormantTab(node, spaceID: space.id, folderID: folderID, placement: .spacePinned)
                        else { return nil }
                        tabs.append(tab)
                        closedPinnedTabIDs.insert(tab.id)
                        result.pinnedTabCount += 1
                        return .tab(tab.id)
                    case .folder(let title, let icon, let children):
                        let id = uniquePinnedTabFolderID()
                        pinnedTabFolders.append(PinnedTabFolder(
                            id: id,
                            spaceID: space.id,
                            parentFolderID: folderID,
                            title: sanitizedPinnedTabFolderTitle(from: title) ?? BrowserStrings
                                .pinnedTabFolderDefaultTitle,
                            systemImageName: icon.flatMap { NSImage(
                                systemSymbolName: $0,
                                accessibilityDescription: nil,
                            ) == nil
                                ? nil
                                : $0
                            },
                            isExpanded: false,
                        ))
                        result.folderCount += 1
                        folderChildren[id] = add(children, folderID: id)
                        return .folder(id)
                    }
                }
            }
            let roots = add(arcSpace.pinned, folderID: nil)
            var tree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
            tree.children[.pinned(space.id)] = roots
            for (folderID, children) in folderChildren {
                tree.children[.pinned(space.id, folderID: folderID)] = children
            }
            applyPinnedTree(tree)
            result.spaceCount += 1
        }

        if supportsAppTabs, let spaceID = selectedSpaceID ?? spaces.first?.id {
            var known = Set(appTabs.map { comparablePinnedURLString($0.urlString) })
            for node in sidebar.favorites where appTabs.count < Self.appTabCapacity {
                guard case .tab(_, _, let urlString) = node,
                      known.insert(comparablePinnedURLString(urlString)).inserted,
                      let tab = dormantTab(node, spaceID: spaceID, folderID: nil, placement: .app)
                else { continue }
                tabs.insert(tab, at: tabs.lastIndex { $0.placement == .app }.map { $0 + 1 } ?? 0)
                closedAppTabIDs.insert(tab.id)
                result.favoriteCount += 1
            }
        }

        if !result.isEmpty {
            persistCurrentSessionIfAllowed()
        }
        return result
    }

    func createNewSpace() {
        guard supportsSpaces else {
            return
        }

        let space = makeSpace()
        spaces.append(space)
        selectSpace(id: space.id)
        BrowserTelemetry.captureUsage(.spaceCreated, properties: telemetryProperties)
        persistCurrentSessionIfAllowed()
    }

    /// Saved icons of pages that are not open, as the Library's archive lists them.
    func pageIcons(for urlStrings: [String]) -> [String: Data] {
        historyStore.pageIcons(for: urlStrings)
    }

    func openLibrary(section: BrowserLibrarySection = .archive) {
        guard librarySections.contains(section) else { return }
        librarySection = section
    }

    func closeLibrary() {
        librarySection = nil
    }

    /// Opens the Library on the section used last, or closes it.
    func toggleLibrary() {
        if librarySection == nil {
            openLibrary(section: librarySections.contains(lastLibrarySection) ? lastLibrarySection : .downloads)
        } else {
            closeLibrary()
        }
    }

    /// The profile a Space's pages use, by directory name.
    func profileDirectory(forSpaceID spaceID: String) -> String? {
        spaceProfilesByID[spaceID] ?? profileDirectories?.windowProfile
    }

    /// Moves a Space to another profile. Its open pages reload there, since a page
    /// cannot change the place it keeps its data.
    @discardableResult func setProfile(_ directory: String?, forSpaceID spaceID: String) -> Bool {
        guard spaces.contains(where: { $0.id == spaceID }) else { return false }
        let next = directory == profileDirectories?.windowProfile ? nil : directory
        guard spaceProfilesByID[spaceID] != next else { return false }
        spaceProfilesByID[spaceID] = next
        tabDriver.profileCachePathForNewTabs = profileCachePath(forSpaceID: selectedSpaceID)
        reopenTabsInTheirProfiles()
        persistCurrentSessionIfAllowed()
        return true
    }

    /// Opens the sidebar page that sets up a Space. Nothing changes until it is created.
    func beginCreatingSpace() {
        guard supportsSpaces, !isShuttingDown, spaceCreationDraft == nil else { return }
        spaceCreationDraft = BrowserSpaceCreationDraft()
    }

    func updateSpaceCreationDraft(_ change: (inout BrowserSpaceCreationDraft) -> Void) {
        guard var draft = spaceCreationDraft else { return }
        change(&draft)
        spaceCreationDraft = draft
    }

    func cancelCreatingSpace() {
        spaceCreationDraft = nil
    }

    /// Makes the Space from the page's choices and moves to it.
    @discardableResult func commitCreatingSpace() -> Bool {
        guard let draft = spaceCreationDraft,
              let title = sanitizedSpaceTitle(from: draft.title)
        else { return false }
        spaceCreationDraft = nil
        var space = makeSpace()
        space.title = title
        if let icon = draft.icon {
            space.systemImageName = icon
        }
        spaces.append(space)
        spaceThemesByID[space.id] = draft.theme
        if draft.profileDirectory != profileDirectories?.windowProfile {
            spaceProfilesByID[space.id] = draft.profileDirectory
        }
        selectSpace(id: space.id)
        BrowserTelemetry.captureUsage(.spaceCreated, properties: telemetryProperties)
        persistCurrentSessionIfAllowed()
        return true
    }

    func canDeleteSpace(id spaceID: String) -> Bool {
        supportsSpaces && spaces.count > 1 && spaces.contains { $0.id == spaceID }
    }

    @discardableResult func deleteSpace(id spaceID: String) -> Bool {
        guard
            canDeleteSpace(id: spaceID),
            let spaceIndex = spaces.firstIndex(where: { $0.id == spaceID })
        else {
            return false
        }

        let fallbackSpaceID = fallbackSpaceID(afterDeletingSpaceAt: spaceIndex)
        if selectedSpaceID == spaceID {
            selectedSpaceID = fallbackSpaceID
            if selectedTab?.placement != .app {
                selectActiveTabForSelectedSpace()
            }
        }

        let wasPersistenceEnabled = isPersistenceEnabled
        isPersistenceEnabled = false
        changingTabRowsTogether {
            for tabID in tabs.filter({ $0.spaceID == spaceID && $0.placement != .app }).map(\.id) {
                closeTab(id: tabID, registersUndo: false, reason: .structuralRemoval)
            }
        }
        for (engineID, binding) in pendingRemoteTabCreations
            where binding.snapshot.spaceID == spaceID && binding.snapshot.placement != .app
        {
            pendingRemoteTabCreations.removeValue(forKey: engineID)
            discardedRemoteTabCreationIDs.insert(engineID)
            tabDriver.closeTab(withID: engineID, forceClose: true)
        }
        isPersistenceEnabled = wasPersistenceEnabled

        if let fallbackSpaceID {
            for index in tabs.indices where tabs[index].placement == .app && tabs[index].spaceID == spaceID {
                // Favorites are global. Their remembered Space only provides a
                // valid selection/restore context; it does not own their lifetime.
                tabs[index].spaceID = fallbackSpaceID
            }
        }
        spaces.removeAll { $0.id == spaceID }
        pinnedTabFolders.removeAll { $0.spaceID == spaceID }
        if selectedSpaceID == spaceID || selectedSpaceID == nil {
            selectedSpaceID = spaces.first?.id
            selectActiveTabForSelectedSpace()
        }
        if let selectedTab, selectedTab.placement == .app {
            setSelectedTabID(selectedTab.id, forSpaceID: selectedSpaceID)
        }

        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        finishRemoteSyncProjectionIfReady()
        return true
    }

    func selectSpace(id spaceID: String) {
        guard supportsSpaces,
              spaces.contains(where: { $0.id == spaceID }),
              selectedSpaceID != spaceID
        else {
            return
        }

        onSpaceWillSelect?(spaceID)
        captureSelectedTabPreviewIfNeeded()
        dismissCommandBar()
        recordExplicitViewingActivity(ids: [selectedTabID])
        selectedSpaceID = spaceID
        selectActiveTabForSelectedSpace()
        recordExplicitViewingActivity(ids: [selectedTabID])
        updateWindowTitle()
        BrowserTelemetry.captureUsage(.spaceSelected, properties: telemetryProperties)
        persistCurrentSessionIfAllowed()
    }

    func selectNextSpace() {
        guard supportsSpaces else {
            return
        }

        selectAdjacentSpace(offset: 1)
    }

    func selectPreviousSpace() {
        guard supportsSpaces else {
            return
        }

        selectAdjacentSpace(offset: -1)
    }

    func toggleActiveSpacePinnedSectionCollapsed() {
        guard supportsSpaces, let index = selectedSpaceIndex else {
            return
        }

        spaces[index].isPinnedSectionCollapsed.toggle()
        persistCurrentSessionIfAllowed()
    }

    func setTitle(_ title: String?, forSpaceID spaceID: String) {
        withArrangementUndo(BrowserStrings.undoRenameAction) {
            guard supportsSpaces, let index = spaces.firstIndex(where: { $0.id == spaceID }) else {
                return
            }

            let sanitizedTitle = sanitizedSpaceTitle(from: title) ?? defaultSpaceTitle(forDisplayIndex: index + 1)
            guard spaces[index].title != sanitizedTitle else {
                return
            }

            spaces[index].title = sanitizedTitle
            persistCurrentSessionIfAllowed()
        }
    }

    func setIcon(_ systemImageName: String, forSpaceID spaceID: String) {
        guard supportsSpaces,
              let index = spaces.firstIndex(where: { $0.id == spaceID }),
              spaces[index].systemImageName != systemImageName
        else {
            return
        }

        spaces[index].systemImageName = systemImageName
        persistCurrentSessionIfAllowed()
    }

    /// Dock reorder: the Space takes `index` among the Spaces. Sync
    /// sends the move from the new order.
    @discardableResult func moveSpace(id: String, toIndex index: Int) -> Bool {
        withArrangementUndo(BrowserStrings.undoMoveAction) {
            guard supportsSpaces, let from = spaces.firstIndex(where: { $0.id == id }) else { return false }
            let target = min(max(index, 0), spaces.count - 1)
            guard from != target else { return false }
            let space = spaces.remove(at: from)
            spaces.insert(space, at: target)
            persistCurrentSessionIfAllowed()
            return true
        }
    }

    @discardableResult func createPinnedTabFolder(containingTabIDs tabIDs: Set<String>) -> String? {
        guard let selectedSpaceID else {
            return nil
        }

        let selectedTabIDs = Set(tabIDs)
        let orderedTabs = (spacePinnedTabs + temporaryTabs).filter { selectedTabIDs.contains($0.id) }
        guard !orderedTabs.isEmpty else {
            return nil
        }
        let originalTree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
        let rootContainer = BrowserSidebarDropContainer.pinned(selectedSpaceID)
        let originalRoots = originalTree.items(in: rootContainer)
        let insertion = originalRoots.firstIndex { item in
            switch item {
            case .tab(let id): selectedTabIDs.contains(id)
            case .folder(let id): !selectedTabIDs.isDisjoint(with: originalTree.tabIDs(in: .pinned(
                    selectedSpaceID,
                    folderID: id,
                )))
            }
        } ?? originalRoots.count

        let folderID = uniquePinnedTabFolderID()
        let folder = PinnedTabFolder(
            id: folderID,
            spaceID: selectedSpaceID,
            parentFolderID: nil,
            title: BrowserStrings.pinnedTabFolderDefaultTitle,
            systemImageName: nil,
            isExpanded: true,
        )

        var updatedPinnedTabs = spacePinnedTabs.filter { !selectedTabIDs.contains($0.id) }
        let firstSelectedIndex = spacePinnedTabs.firstIndex { selectedTabIDs.contains($0.id) } ?? updatedPinnedTabs
            .count
        let folderTabs = orderedTabs.map { tab in
            var updatedTab = tab
            updatedTab.spaceID = selectedSpaceID
            updatedTab.placement = .spacePinned
            updatedTab.pinnedURLString = effectivePinnedURLString(forPinnedTab: updatedTab)
            updatedTab.pinnedFolderID = folderID
            return updatedTab
        }
        updatedPinnedTabs.insert(contentsOf: folderTabs, at: min(firstSelectedIndex, updatedPinnedTabs.count))

        pinnedTabFolders.append(folder)
        tabs = tabsByReplacingTabs(
            spacePinnedTabsBySpaceID: tabsBySpaceID(
                replacing: updatedPinnedTabs,
                for: .spacePinned,
                inSpaceID: selectedSpaceID,
            ),
            temporaryTabsBySpaceID: tabsBySpaceID(for: .temporary, removingTabIDs: selectedTabIDs),
            appTabs: appTabs,
        )
        reopenTabsInTheirProfiles()
        var tree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
        let moving = Set(selectedTabIDs.map(BrowserSidebarItemID.tab))
        var roots = originalRoots.filter { !moving.contains($0) }
        let rootIndex = originalRoots.prefix(insertion).count(where: { !moving.contains($0) })
        roots.insert(.folder(folderID), at: min(rootIndex, roots.count))
        tree.children[rootContainer] = roots
        tree.children[.pinned(selectedSpaceID, folderID: folderID)] = orderedTabs.map { .tab($0.id) }
        applyPinnedTree(tree)
        persistCurrentSessionIfAllowed(syncMove: syncMoveIntent(forTabIDs: Set(orderedTabs.map(\.id))))
        return folderID
    }

    /// Turns a Space into a folder at the top of another Space: its pinned rows and
    /// folders and its temporary tabs move in together, and the Space goes away.
    @discardableResult func exportSpace(id spaceID: String, intoFolderInSpaceID targetSpaceID: String) -> Bool {
        guard spaceID != targetSpaceID, canDeleteSpace(id: spaceID),
              let space = spaces.first(where: { $0.id == spaceID }),
              spaces.contains(where: { $0.id == targetSpaceID })
        else { return false }
        if selectedSpaceID != spaceID {
            selectSpace(id: spaceID)
        }
        let folders = pinnedTabFolders.filter { $0.spaceID == spaceID && $0.parentFolderID == nil }
        var tabIDs = Set(tabs.filter {
            $0.spaceID == spaceID && $0.placement != .app && ($0.placement == .temporary || $0.pinnedFolderID == nil)
        }
        .map(\.id))
        if tabIDs.isEmpty, let nested = tabs.first(where: { $0.spaceID == spaceID && $0.placement == .spacePinned }) {
            tabIDs = [nested.id]
        }
        guard let folderID = createPinnedTabFolder(containingTabIDs: tabIDs) else { return false }
        setTitle(space.title, forPinnedTabFolderID: folderID)
        setIcon(space.systemImageName, forPinnedTabFolderID: folderID)
        for (index, folder) in folders.enumerated() where folder.id != folderID {
            movePinnedTabFolder(withID: folder.id, toRootSectionIndex: index, targetParentFolderID: folderID)
        }
        movePinnedTabFolder(withID: folderID, toRootSectionIndex: 0, targetSpaceID: targetSpaceID)
        // It arrives closed, a single row at the top of the other Space.
        if let index = pinnedTabFolders.firstIndex(where: { $0.id == folderID }) {
            pinnedTabFolders[index].isExpanded = false
        }
        selectSpace(id: targetSpaceID)
        return deleteSpace(id: spaceID)
    }

    /// An empty folder at the top of a Space's pinned rows.
    func createEmptyPinnedFolder(title: String, inSpaceID spaceID: String) -> String? {
        guard spaces.contains(where: { $0.id == spaceID }) else { return nil }
        let folderID = uniquePinnedTabFolderID()
        pinnedTabFolders.append(PinnedTabFolder(
            id: folderID,
            spaceID: spaceID,
            parentFolderID: nil,
            title: title,
            systemImageName: nil,
            isExpanded: true,
        ))
        var tree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
        let root = BrowserSidebarDropContainer.pinned(spaceID)
        tree.children[root] = [.folder(folderID)] + tree.items(in: root).filter { $0 != .folder(folderID) }
        tree.children[.pinned(spaceID, folderID: folderID)] = []
        applyPinnedTree(tree)
        persistCurrentSessionIfAllowed()
        return folderID
    }

    // MARK: Folder menu

    /// New Nested Folder: an empty folder at the top of this one.
    func createNestedFolder(inFolderID parentID: String) -> String? {
        guard let parent = pinnedTabFolders.first(where: { $0.id == parentID }),
              let folderID = createEmptyPinnedFolder(
                  title: BrowserStrings.pinnedTabFolderDefaultTitle,
                  inSpaceID: parent.spaceID,
              )
        else { return nil }
        movePinnedTabFolder(withID: folderID, toRootSectionIndex: 0, targetParentFolderID: parentID)
        if let index = pinnedTabFolders.firstIndex(where: { $0.id == parentID }) {
            pinnedTabFolders[index].isExpanded = true
        }
        persistCurrentSessionIfAllowed()
        return folderID
    }

    /// Spaces a folder can go to.
    func spacesForMovingFolder(id folderID: String) -> [Space] {
        guard supportsSpaces, let folder = pinnedTabFolders.first(where: { $0.id == folderID }) else { return [] }
        return spaces.filter { $0.id != folder.spaceID }
    }

    /// Duplicate: a copy right below the folder. Its pages come in unloaded.
    @discardableResult func duplicateFolder(id folderID: String) -> String? {
        guard let source = pinnedTabFolders.first(where: { $0.id == folderID }) else { return nil }
        let container = BrowserSidebarDropContainer.pinned(source.spaceID, folderID: source.parentFolderID)
        let siblings = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot()).items(in: container)
        guard let position = siblings.firstIndex(of: .folder(folderID)),
              let copyID = copyFolder(source)
        else { return nil }
        movePinnedTabFolder(
            withID: copyID,
            toRootSectionIndex: position + 1,
            targetSpaceID: source.spaceID,
            targetParentFolderID: source.parentFolderID,
        )
        persistCurrentSessionIfAllowed()
        return copyID
    }

    /// Move to: an empty folder has no pages for the sidebar's move plan to carry.
    func moveFolder(id folderID: String, toSpaceID spaceID: String) {
        withArrangementUndo(BrowserStrings.undoMoveAction) {
            guard spaces.contains(where: { $0.id == spaceID }) else { return }
            let descendants = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
                .descendantFolderIDs(including: folderID)
            movePinnedTabFolder(withID: folderID, toRootSectionIndex: 0, targetSpaceID: spaceID)
            guard pinnedTabFolders.first(where: { $0.id == folderID })?.spaceID != spaceID else { return }
            for index in pinnedTabFolders.indices where descendants.contains(pinnedTabFolders[index].id) {
                pinnedTabFolders[index].spaceID = spaceID
            }
            if let index = pinnedTabFolders.firstIndex(where: { $0.id == folderID }) {
                pinnedTabFolders[index].parentFolderID = nil
            }
            var tree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
            let root = BrowserSidebarDropContainer.pinned(spaceID)
            tree.children[root] = [.folder(folderID)] + tree.items(in: root).filter { $0 != .folder(folderID) }
            applyPinnedTree(tree)
            persistCurrentSessionIfAllowed()
        }
    }

    /// Turn into Space: a new Space with the folder's name and icon, whose pinned rows are
    /// what the folder held. The folder itself is gone.
    @discardableResult func turnFolderIntoSpace(id folderID: String) -> Bool {
        guard supportsSpaces, !isShuttingDown,
              let folder = pinnedTabFolders.first(where: { $0.id == folderID })
        else { return false }
        let order = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
            .items(in: .pinned(folder.spaceID, folderID: folderID))
        var space = makeSpace()
        if let title = sanitizedSpaceTitle(from: folder.title) {
            space.title = title
        }
        if let icon = folder.systemImageName {
            space.systemImageName = icon
        }
        spaces.append(space)
        spaceThemesByID[space.id] = spaceThemesByID[folder.spaceID]
        spaceProfilesByID[space.id] = spaceProfilesByID[folder.spaceID]
        moveFolder(id: folderID, toSpaceID: space.id)
        for (index, item) in order.enumerated() {
            switch item {
            case .tab(let id):
                moveTab(withID: id, toPlacement: .spacePinned, atSectionIndex: index, targetSpaceID: space.id)
            case .folder(let id):
                if let folderIndex = pinnedTabFolders.firstIndex(where: { $0.id == id }) {
                    pinnedTabFolders[folderIndex].parentFolderID = nil
                }
            }
        }
        pinnedTabFolders.removeAll { $0.id == folderID }
        var tree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
        tree.children[.pinned(space.id)] = order
        applyPinnedTree(tree)
        selectSpace(id: space.id)
        BrowserTelemetry.captureUsage(.spaceCreated, properties: telemetryProperties)
        persistCurrentSessionIfAllowed()
        return true
    }

    /// Makes a live folder list exactly these pages: a new one comes in unloaded, and
    /// one that left goes away unless it is open in front of the user.
    func syncLiveFolder(id folderID: String, pages: [BrowserLivePage]) {
        guard let folder = pinnedTabFolders.first(where: { $0.id == folderID }) else { return }
        let wanted = Set(pages.map(\.url))
        changingTabRowsTogether {
            for tab in tabs
                where tab.pinnedFolderID == folderID && !wanted.contains(tab.pinnedURLString ?? tab.urlString)
            {
                if tab.id != selectedTabID {
                    closeTab(id: tab.id, registersUndo: false, reason: .structuralRemoval)
                }
            }
        }
        let existing = Set(tabs.filter { $0.pinnedFolderID == folderID }.map { $0.pinnedURLString ?? $0.urlString })
        var added = false
        for page in pages where !existing.contains(page.url) {
            let tabID = UUID().uuidString
            restoredTabCreationIDs.insert(tabID)
            tabs.append(Tab(
                id: tabID,
                syncID: tabSyncIDProvider(),
                spaceID: folder.spaceID,
                title: page.title,
                userTitleOverride: nil,
                urlString: page.url,
                pinnedURLString: page.url,
                placement: .spacePinned,
                pinnedFolderID: folderID,
                lastActivityAt: dateProvider(),
            ))
            added = true
        }
        guard added else { return }
        var tree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
        let order = pages.compactMap { page in
            tabs.first { $0.pinnedFolderID == folderID && ($0.pinnedURLString ?? $0.urlString) == page.url }?.id
        }
        tree.children[.pinned(folder.spaceID, folderID: folderID)] = order.map(BrowserSidebarItemID.tab)
        applyPinnedTree(tree)
        persistCurrentSessionIfAllowed()
    }

    /// Explicit deletion removes the folder's current subtree. Empty folders
    /// otherwise keep their identity when their last tab is moved or archived.
    @discardableResult func deletePinnedTabFolder(id folderID: String) -> Bool {
        guard pinnedTabFolders.contains(where: { $0.id == folderID }) else { return false }
        let removed = descendantPinnedTabFolderIDs(including: folderID)
        let wasPersistenceEnabled = isPersistenceEnabled
        isPersistenceEnabled = false
        changingTabRowsTogether {
            for tabID in tabs
                .filter({ $0.placement == .spacePinned && $0.pinnedFolderID.map(removed.contains) == true })
                .map(\.id)
            {
                closeTab(id: tabID, registersUndo: false, reason: .structuralRemoval)
            }
        }
        for (engineID, binding) in pendingRemoteTabCreations
            where binding.snapshot.placement == .spacePinned && binding.snapshot
            .pinnedFolderID
            .map(removed.contains) == true
        {
            pendingRemoteTabCreations.removeValue(forKey: engineID)
            discardedRemoteTabCreationIDs.insert(engineID)
            tabDriver.closeTab(withID: engineID, forceClose: true)
        }
        pinnedTabFolders.removeAll { removed.contains($0.id) }
        isPersistenceEnabled = wasPersistenceEnabled
        persistCurrentSessionIfAllowed()
        finishRemoteSyncProjectionIfReady()
        return true
    }

    func togglePinnedTabFolderExpanded(id folderID: String) {
        guard let index = pinnedTabFolders.firstIndex(where: { $0.id == folderID }) else {
            return
        }

        pinnedTabFolders[index].isExpanded.toggle()
        persistSessionSoon()
    }

    func setTitle(_ title: String?, forPinnedTabFolderID folderID: String) {
        withArrangementUndo(BrowserStrings.undoRenameAction) {
            guard let index = pinnedTabFolders.firstIndex(where: { $0.id == folderID }) else {
                return
            }

            let sanitizedTitle = sanitizedPinnedTabFolderTitle(from: title) ?? BrowserStrings
                .pinnedTabFolderDefaultTitle
            guard pinnedTabFolders[index].title != sanitizedTitle else {
                return
            }

            pinnedTabFolders[index].title = sanitizedTitle
            persistCurrentSessionIfAllowed()
        }
    }

    func setIcon(_ systemImageName: String?, forPinnedTabFolderID folderID: String) {
        guard
            let index = pinnedTabFolders.firstIndex(where: { $0.id == folderID }),
            pinnedTabFolders[index].systemImageName != systemImageName
        else {
            return
        }

        pinnedTabFolders[index].systemImageName = systemImageName
        persistCurrentSessionIfAllowed()
    }

    func togglePinned(forTabID tabID: String) {
        guard
            let tab = tabs.first(where: { $0.id == tabID }),
            tab.spaceID == selectedSpaceID
        else {
            return
        }

        let targetPlacement: BrowserTabPlacement = tab.placement == .spacePinned ? .temporary : .spacePinned
        let targetSectionIndex = tabCount(for: targetPlacement)
        withArrangementUndo(targetPlacement == .spacePinned ? BrowserStrings.menuPinTab : BrowserStrings.menuUnpinTab) {
            moveTab(withID: tabID, toPlacement: targetPlacement, atSectionIndex: targetSectionIndex)
        }
    }

    @discardableResult func resetPinnedTabToPinnedURL(id tabID: String) -> Bool {
        guard
            let tab = tabs.first(where: { $0.id == tabID }),
            tab.placement == .spacePinned,
            let pinnedURLString = effectivePinnedURLString(forPinnedTab: tab)
        else {
            return false
        }

        if closedPinnedTabIDs.contains(tabID) {
            lastPageRestoreTabIDs.remove(tabID)
            selectTab(id: tabID)
            return true
        }

        if selectedTabID != tabID {
            selectTab(id: tabID)
        }

        guard selectedTabID == tabID else {
            return false
        }

        guard !areEquivalentPinnedURLStrings(tab.urlString, pinnedURLString) else {
            return true
        }

        return navigateSelectedTab(toURLString: pinnedURLString)
    }

    /// Reset all tabs in this Space: whether a pinned tab of the Space has
    /// left its pinned page.
    func canResetSpaceTabs(spaceID: String? = nil) -> Bool {
        guard let spaceID = spaceID ?? selectedSpaceID else { return false }
        return tabs.contains { $0.spaceID == spaceID && $0.canResetToPinnedURL }
    }

    /// Every pinned tab of the Space goes back to its pinned page. The shown tab
    /// reloads there; the others unload, so they open there next time.
    @discardableResult func resetSpaceTabs(spaceID: String? = nil) -> Bool {
        guard let spaceID = spaceID ?? selectedSpaceID, canResetSpaceTabs(spaceID: spaceID) else { return false }
        let shown = Set(selectedTabID.map(splitPaneTabIDs(forTabID:)) ?? [])
        var changed = false
        for tab in tabs where tab.spaceID == spaceID && tab.placement == .spacePinned {
            guard tab.canResetToPinnedURL else { continue }
            if closedPinnedTabIDs.contains(tab.id) {
                // An unloaded tab restored at its last page opens at the pinned one.
                lastPageRestoreTabIDs.remove(tab.id)
                guard let pinned = effectivePinnedURLString(forPinnedTab: tab),
                      let index = tabs.firstIndex(where: { $0.id == tab.id })
                else { continue }
                tabs[index].title = ""
                tabs[index].urlString = pinned
                tabs[index].faviconURLString = nil
                changed = true
            } else {
                // A shown page, or a pane of the shown split, reloads in place.
                // Split panes stay loaded, as at launch, so their split shows whole.
                if tab.id == selectedTabID {
                    resetPinnedTabToPinnedURL(id: tab.id)
                } else if shown.contains(tab.id) || splitGroup(containingTabID: tab.id) != nil,
                          let pinned = effectivePinnedURLString(forPinnedTab: tab)
                {
                    tabDriver.navigateTab(withID: tab.id, toURLString: pinned)
                } else {
                    closePinnedTabProcessOrReset(id: tab.id)
                }
                changed = true
            }
        }
        if changed {
            persistCurrentSessionIfAllowed()
        }
        return changed
    }

    /// Space theme; nil keeps the window neutral. `persist` is false during a
    /// gesture in the theme editor, whose final change saves.
    @discardableResult func setTheme(
        _ theme: BrowserSpaceTheme?,
        forSpaceID spaceID: String,
        persist: Bool = true,
    ) -> Bool {
        guard spaces.contains(where: { $0.id == spaceID }) else { return false }
        let next = theme?.colors.isEmpty == true ? nil : theme
        let changed = spaceThemesByID[spaceID] != next
        guard changed || persist else { return false }
        if changed {
            spaceThemesByID[spaceID] = next
            locallyColoredSpaceIDs.insert(spaceID)
        }
        if persist { persistCurrentSessionIfAllowed() }
        return changed
    }

    func icon(forTabID tabID: String) -> String? {
        tabs.first { $0.id == tabID }.flatMap { tabIconsBySyncID[$0.syncID] }
    }

    /// Change Icon for a tab; nil goes back to the site's icon.
    @discardableResult func setIcon(_ systemImageName: String?, forTabID tabID: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }), tabIconsBySyncID[tab.syncID] != systemImageName
        else { return false }
        tabIconsBySyncID[tab.syncID] = systemImageName
        objectWillChange.send()
        persistCurrentSessionIfAllowed()
        return true
    }

    @discardableResult func replacePinnedURLWithCurrent(forTabID tabID: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return false
        }

        return setPinnedURLString(tab.urlString, forTabID: tabID)
    }

    @discardableResult func setPinnedURLString(_ urlString: String?, forTabID tabID: String) -> Bool {
        guard
            let index = tabs.firstIndex(where: { $0.id == tabID }),
            tabs[index].placement.keepsPinnedURL,
            let normalizedURLString = normalizedPinnedURLString(from: urlString),
            tabs[index].pinnedURLString != normalizedURLString
        else {
            return false
        }

        tabs[index].pinnedURLString = normalizedURLString
        persistCurrentSessionIfAllowed()
        return true
    }

    func sidebarMovePlan(
        payload: BrowserSidebarDragPayload,
        destination: BrowserSidebarDropDestination,
    ) -> BrowserSidebarMovePlan? {
        guard supportsAppTabs || destination.container.section != .app else { return nil }
        let snapshot = sidebarPlanningSnapshot()
        var payload = payload
        if case .folder(let id) = payload.primary {
            let visibleTree = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
            let logicalTree = BrowserSidebarTabTree(snapshot: snapshot)
            guard let folder = logicalTree.folders[id] else { return nil }
            let container = BrowserSidebarDropContainer.pinned(folder.spaceID, folderID: id)
            let visibleIDs = Set(visibleTree.tabIDs(in: container))
            let logicalIDs = Set(logicalTree.tabIDs(in: container))
            // Native drags name visible descendants. Direct move plans can
            // already contain the pending identities from this same tree.
            guard payload.tabIDs == visibleIDs || payload.tabIDs == logicalIDs else { return nil }
            payload = .init(primary: payload.primary, tabIDs: logicalIDs)
        }
        return BrowserSidebarMovePlan
            .make(snapshot: snapshot, payload: payload, destination: destination) { tab, target in
                guard self.canMoveTab(tab, to: target.section.placement) else { return nil }
                var moved = tab
                moved.placement = target.section.placement
                if let spaceID = target.spaceID {
                    moved.spaceID = spaceID
                }
                moved.pinnedFolderID = target.folderID
                moved.pinnedURLString = self.pinnedURLString(for: tab, movingTo: target.section.placement)
                return moved
            }
    }

    /// Revalidate by stable IDs at release, then publish one final order.
    @discardableResult func commitSidebarDrop(
        payload: BrowserSidebarDragPayload,
        destination: BrowserSidebarDropDestination,
    ) -> Bool {
        guard let plan = sidebarMovePlan(payload: payload, destination: destination) else { return false }
        let oldTabs = tabs
        let activeMovedID = selectedTabID.flatMap { payload.tabIDs.contains($0) ? $0 : nil }
        let updatesActivity =
            if case .tab = payload.primary {
                true
            } else {
                false
            }
        let plannedTabs = plan.tabs.map { tab in
            var tab = tab
            if updatesActivity, payload.tabIDs.contains(tab.id) {
                tab.lastActivityAt = advancedActivityDate(after: tab.lastActivityAt)
            }
            return tab
        }
        let unloadedIDs = payload.tabIDs.filter { closedPinnedTabIDs.contains($0) || closedAppTabIDs.contains($0) }
        publishPlannedTabs(plannedTabs)
        pinnedTabFolders = plan.folders
        var tabsToLoad = [String]()
        for id in payload.tabIDs {
            guard let moved = tabs.first(where: { $0.id == id }) else { continue }
            if moved.placement != .app {
                closedAppTabIDs.remove(id)
            }
            if moved.placement != .spacePinned {
                closedPinnedTabIDs.remove(id)
            }
            // An unloaded tab stays unloaded among pinned tabs and Favorites;
            // anywhere else it needs a page.
            if unloadedIDs.contains(id) {
                switch moved.placement {
                case .app: closedAppTabIDs.insert(id)
                case .spacePinned: closedPinnedTabIDs.insert(id)
                case .temporary where windowGroup != nil: markWithoutPage(id, placement: .temporary)
                case .temporary: tabsToLoad.append(id)
                }
            }
            if moved.placement != .app, let old = oldTabs.first(where: { $0.id == id }) {
                let wasSourceSelection = spaces.first(where: { $0.id == old.spaceID })?.selectedTabID == id
                if old.spaceID != moved.spaceID, wasSourceSelection {
                    clearSelectedTab(id, forSpaceID: old.spaceID)
                }
                if activeMovedID == id || (wasSourceSelection && moved.spaceID != selectedSpaceID) {
                    setSelectedTabID(id, forSpaceID: moved.spaceID)
                }
            }
        }
        if activeMovedID != nil {
            selectActiveTabForSelectedSpace()
        }
        updateWindowTitle()
        // The move intent names tabs before loading gives them new runtime IDs;
        // one write carries both.
        let syncMove = syncMoveIntent(for: payload)
        for id in tabsToLoad {
            loadUnloadedTabInPlace(id: id, persists: false)
        }
        reopenTabsInTheirProfiles()
        persistCurrentSessionIfAllowed(syncMove: syncMove)
        return true
    }

    func canMoveTab(
        withID tabID: String, toPlacement placement: BrowserTabPlacement, atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil, targetPinnedFolderID: String? = nil,
    ) -> Bool {
        indexedTabMovePlan(
            tabIDs: [tabID],
            placement: placement,
            sectionIndex: sectionIndex,
            targetSpaceID: targetSpaceID,
            targetPinnedFolderID: targetPinnedFolderID,
        ) != nil
    }

    func canMoveTabs(
        withIDs tabIDs: Set<String>, toPlacement placement: BrowserTabPlacement, atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil, targetPinnedFolderID: String? = nil,
    ) -> Bool {
        tabIDs.count > 1 && indexedTabMovePlan(
            tabIDs: tabIDs,
            placement: placement,
            sectionIndex: sectionIndex,
            targetSpaceID: targetSpaceID,
            targetPinnedFolderID: targetPinnedFolderID,
        ) != nil
    }

    func moveTab(
        withID tabID: String, toPlacement placement: BrowserTabPlacement, atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil, targetPinnedFolderID: String? = nil,
    ) {
        guard let plan = indexedTabMovePlan(
            tabIDs: [tabID],
            placement: placement,
            sectionIndex: sectionIndex,
            targetSpaceID: targetSpaceID,
            targetPinnedFolderID: targetPinnedFolderID,
        )
        else { return }
        commitSidebarDrop(payload: plan.payload, destination: plan.destination)
    }

    func moveTabs(
        withIDs tabIDs: Set<String>, toPlacement placement: BrowserTabPlacement, atSectionIndex sectionIndex: Int,
        targetSpaceID: String? = nil, targetPinnedFolderID: String? = nil,
    ) {
        guard tabIDs.count > 1,
              let plan = indexedTabMovePlan(
                  tabIDs: tabIDs,
                  placement: placement,
                  sectionIndex: sectionIndex,
                  targetSpaceID: targetSpaceID,
                  targetPinnedFolderID: targetPinnedFolderID,
              )
        else { return }
        commitSidebarDrop(payload: plan.payload, destination: plan.destination)
    }

    func canMovePinnedTabFolder(
        withID folderID: String, toRootSectionIndex rootSectionIndex: Int,
        targetSpaceID: String? = nil, targetParentFolderID: String? = nil,
    ) -> Bool {
        indexedFolderMovePlan(
            folderID: folderID,
            index: rootSectionIndex,
            targetSpaceID: targetSpaceID,
            parentFolderID: targetParentFolderID,
        ) != nil
    }

    func movePinnedTabFolder(
        withID folderID: String, toRootSectionIndex rootSectionIndex: Int,
        targetSpaceID: String? = nil, targetParentFolderID: String? = nil,
    ) {
        guard let plan = indexedFolderMovePlan(
            folderID: folderID,
            index: rootSectionIndex,
            targetSpaceID: targetSpaceID,
            parentFolderID: targetParentFolderID,
        )
        else { return }
        commitSidebarDrop(payload: plan.payload, destination: plan.destination)
    }

    func clearTemporaryTabs(includingActiveTab: Bool = true) {
        let activeTemporaryTabID = includingActiveTab || selectedTab?.placement != .temporary
            ? nil
            : selectedTabID
        let temporaryTabIDs = temporaryTabs
            .map(\.id)
            .filter { $0 != activeTemporaryTabID }
        // One Undo brings back every tab this Clear closes.
        let batch = UUID()
        changingTabRowsTogether {
            for tabID in temporaryTabIDs {
                tabCloseUndoBatches[tabID] = batch
                if !closeTab(id: tabID, undoActionName: BrowserStrings.sidebarClearTemporaryTabs) {
                    tabCloseUndoBatches.removeValue(forKey: tabID)
                }
            }
        }
    }

    func setTemporaryTabLifetime(_ lifetime: BrowserTemporaryTabLifetime) {
        guard temporaryTabLifetime != lifetime else {
            return
        }

        if let sqlite = sessionPreferencesStore as? BrowserSQLiteSessionStore {
            do {
                try sqlite.saveTemporaryTabLifetimeStrict(lifetime)
            } catch {
                pendingAutomaticArchivalSettingsRetry = .localLifetime(lifetime)
                automaticArchivalSettingsError = BrowserStrings.settingsTemporaryTabsSaveFailed
                return
            }
        } else {
            sessionPreferencesStore.saveTemporaryTabLifetime(lifetime)
        }
        temporaryTabLifetime = lifetime
        if sessionPreferencesStore is BrowserSQLiteSessionStore {
            // A legacy lifetime change may repair a previously invalid value.
            // Validate the enabled flag as well before clearing its Retry state.
            reloadAutomaticTabArchivalSettings()
        } else {
            automaticArchivalSettingsError = nil
            pendingAutomaticArchivalSettingsRetry = nil
        }
        archiveExpiredTemporaryTabs()
    }

    /// Without sync: Never keeps temporary tabs until they are closed; a
    /// lifetime turns archival back on with that interval.
    func setLocalAutomaticArchival(lifetime: BrowserTemporaryTabLifetime?) {
        let off = lifetime == nil
        if localAutomaticArchivalOff != off {
            sessionPreferencesStore.saveLocalAutomaticArchivalOff(off)
            localAutomaticArchivalOff = off
        }
        if let lifetime {
            setTemporaryTabLifetime(lifetime)
            archiveExpiredTemporaryTabs()
        }
    }

    /// The synced-profile picker expresses both enabled state and interval.
    /// Off remains editable while a session write or engine creation is pending.
    @discardableResult func setAutomaticTabArchival(lifetime: BrowserTemporaryTabLifetime?) -> Bool {
        guard canConfigureAutomaticTabArchival,
              let sqlite = sessionPreferencesStore as? BrowserSQLiteSessionStore else { return false }
        let chosen = lifetime ?? temporaryTabLifetime
        do {
            try sqlite.saveAutomaticTabArchival(enabled: lifetime != nil, lifetime: chosen)
            automaticTabArchivalEnabled = lifetime != nil
            temporaryTabLifetime = chosen
            automaticArchivalSettingsLoaded = true
            pendingAutomaticArchivalSettingsRetry = nil
            automaticArchivalSettingsError = nil
            syncCoordinator?.requestExpirySweep()
            return true
        } catch {
            pendingAutomaticArchivalSettingsRetry = .synchronized(lifetime)
            automaticArchivalSettingsError = BrowserStrings.settingsTemporaryTabsSaveFailed
            return false
        }
    }

    @discardableResult func reloadAutomaticTabArchivalSettings() -> Bool {
        guard windowMode.persistsSession, !isShuttingDown, !hasDiscardedSessionForClosure,
              let sqlite = sessionPreferencesStore as? BrowserSQLiteSessionStore else { return false }
        do {
            let settings = try sqlite.loadAutomaticTabArchivalSettings()
            automaticTabArchivalEnabled = settings.enabled
            temporaryTabLifetime = settings.lifetime
            automaticArchivalSettingsLoaded = true
            pendingAutomaticArchivalSettingsRetry = nil
            automaticArchivalSettingsError = nil
            syncCoordinator?.requestExpirySweep()
            return true
        } catch {
            automaticArchivalSettingsLoaded = false
            pendingAutomaticArchivalSettingsRetry = .reload
            automaticArchivalSettingsError = BrowserStrings.settingsTemporaryTabsLoadFailed
            return false
        }
    }

    @discardableResult func retryAutomaticTabArchivalSettings() -> Bool {
        guard canRetryAutomaticTabArchivalSettings, let pendingAutomaticArchivalSettingsRetry else { return false }
        switch pendingAutomaticArchivalSettingsRetry {
        case .reload: return reloadAutomaticTabArchivalSettings()
        case .synchronized(let lifetime): return setAutomaticTabArchival(lifetime: lifetime)
        case .localLifetime(let lifetime):
            setTemporaryTabLifetime(lifetime)
            return automaticArchivalSettingsError == nil
        }
    }

    func handleApplicationDidBecomeActive() {
        guard !isShuttingDown else { return }
        let becameActive = !isViewingActivityActive
        isViewingActivityActive = true
        syncCoordinator?.setRuntimeActive(true)
        if becameActive {
            persistCurrentViewingActivity()
        }
        archiveExpiredTemporaryTabs()
        bookmarksModel.reload()
        refreshBrowserExtensions()
        syncCoordinator?.schedulePull()
    }

    func handleApplicationWillResignActive() {
        guard isViewingActivityActive, !isShuttingDown else { return }
        persistCurrentViewingActivity()
        isViewingActivityActive = false
        syncCoordinator?.setRuntimeActive(false)
    }

    func updateProfilePresentation(profile: BrowserProfile, availableProfileCount: Int) {
        profileDisplayName = profile.displayName
        self.availableProfileCount = availableProfileCount
    }

    func archiveExpiredTemporaryTabs() {
        guard !isAdditionalWindow, !localAutomaticArchivalOff, canAdmitLocalAutomaticArchive,
              localAutomaticArchiveCandidates.isEmpty,
              localAutomaticArchivalOwnershipAllowsClose() else { return }
        localAutomaticArchiveCandidates = Array(tabs.lazy
            .filter { self.isLocalAutomaticArchiveEligible($0) }
            .prefix(100)
            .map {
                LocalAutomaticArchiveCandidate(
                    id: $0.id, syncID: $0.syncID, spaceID: $0.spaceID, lastActivityAt: $0.lastActivityAt,
                )
            })
        continueLocalAutomaticArchiveSweep()
    }

    func presentCommandBar() {
        historyStore.prepareSearchIndex()
        guard canCreateTab else {
            return
        }

        pendingSplitAnchorTabID = nil
        bookmarksModel.reload()
        dismissFindBar()
        currentPageCommandBarModel.dismiss()
        commandBarModel.present()
        BrowserTelemetry.captureUsage(.commandBarPresented, properties: telemetryProperties)
    }

    func toggleCommandBar() {
        guard canCreateTab else {
            return
        }

        pendingSplitAnchorTabID = nil
        if commandBarModel.isPresented {
            commandBarModel.dismiss()
        } else {
            bookmarksModel.reload()
            dismissFindBar()
            currentPageCommandBarModel.dismiss()
            commandBarModel.present()
            BrowserTelemetry.captureUsage(.commandBarPresented, properties: telemetryProperties)
        }
    }

    func dismissCommandBar() {
        pendingSplitAnchorTabID = nil
        commandBarModel.dismiss()
        currentPageCommandBarModel.dismiss()
    }

    /// Command-L centers the address bar on the page like New Tab; a click on
    /// the address opens it at the address.
    func presentCurrentPageCommandBar(centered: Bool = false) {
        guard
            canCreateTab,
            let selectedTab
        else {
            return
        }
        isCurrentPageCommandBarCentered = centered

        bookmarksModel.reload()
        dismissFindBar()
        commandBarModel.dismiss()
        currentPageCommandBarModel.present(initialQuery: selectedTab.urlString, pageTitle: selectedTab.displayTitle)
        BrowserTelemetry.captureUsage(.currentPageCommandBarPresented, properties: telemetryProperties)
    }

    func presentFindBar() {
        guard canFindInPage else {
            return
        }

        commandBarModel.dismiss()
        currentPageCommandBarModel.dismiss()
        isFindBarPresented = true
        findBarFocusRequest += 1
        findResultMatchCount = nil
        BrowserTelemetry.captureUsage(.findPresented, properties: telemetryProperties)
        runFind(forward: true, findNext: false)
    }

    func presentFindInPage() -> Bool {
        guard canPresentFindInPage else {
            return false
        }

        presentFindBar()
        return isFindBarPresented
    }

    func dismissFindBar() {
        guard isFindBarPresented else {
            return
        }

        isFindBarPresented = false
        findResultMatchCount = nil
        tabDriver.stopFindingInActiveTab(clearSelection: true)
    }

    func findNextInPage() {
        guard canStepThroughFindMatches else {
            return
        }

        runFind(forward: true, findNext: true)
    }

    func findPreviousInPage() {
        guard canStepThroughFindMatches else {
            return
        }

        runFind(forward: false, findNext: true)
    }

    func reloadCurrentTab() {
        guard canReload else {
            return
        }
        if selectedTabCreationState == .failed {
            retrySelectedTabCreation()
            return
        }

        tabDriver.reloadActiveTab()
        BrowserTelemetry.captureUsage(.tabReloaded, properties: telemetryProperties)
    }

    @discardableResult func retrySelectedTabCreation() -> Bool {
        guard canCreateTab, let index = selectedTabIndex,
              tabs[index].creationState == .failed,
              !closedAppTabIDs.contains(tabs[index].id),
              !closedPinnedTabIDs.contains(tabs[index].id),
              !closingTabIDs.contains(tabs[index].id)
        else { return false }

        let tab = tabs[index]
        // Retry only the runtime allocation. The logical tab and its durable
        // snapshot/outbox remain unchanged, including selection and undo IDs.
        tabs[index].creationState = .creating
        guard tabDriver.retryTabCreation(withID: tab.id, urlString: resolvedBrowserURLString(tab.urlString)) else {
            tabs[index].creationState = .failed
            return false
        }
        return true
    }

    func forceReloadCurrentTab() {
        guard canReload else {
            return
        }
        if selectedTabCreationState == .failed {
            retrySelectedTabCreation()
            return
        }

        tabDriver.reloadActiveTabIgnoringCache()
        BrowserTelemetry.captureUsage(
            .tabReloaded,
            properties: telemetryProperties.merging(["force": "true"]) { _, new in new },
        )
    }

    func clearCacheAndRefreshCurrentTab() {
        guard canReload else {
            return
        }

        tabDriver.clearCacheAndReloadActiveTab()
        BrowserTelemetry.captureUsage(
            .tabReloaded,
            properties: telemetryProperties.merging(["clear_cache": "true"]) { _, new in new },
        )
    }

    func clearCookiesAndRefreshCurrentTab() {
        guard canReload else {
            return
        }

        tabDriver.clearCookiesAndReloadActiveTab()
        BrowserTelemetry.captureUsage(
            .tabReloaded,
            properties: telemetryProperties.merging(["clear_cookies": "true"]) { _, new in new },
        )
    }

    func stopLoadingCurrentTab() {
        guard canStopLoading else {
            return
        }

        tabDriver.stopLoadingActiveTab()
    }

    func saveCurrentPage() {
        guard canSavePage, let selectedTab else {
            return
        }

        tabDriver.saveActiveTab(withSuggestedName: selectedTab.pageTitle)
    }

    @discardableResult func pasteAndMatchStyleCurrentTab() -> Bool {
        guard canPasteAndMatchStyle else {
            return false
        }

        tabDriver.pasteAndMatchStyleActiveTab()
        return true
    }

    func printCurrentPage() {
        guard canPrintPage else {
            return
        }

        tabDriver.printActiveTab()
    }

    @discardableResult func copySelectedTabLink() -> Bool {
        guard let selectedTabID else {
            return false
        }

        return copyTabLink(forTabID: selectedTabID)
    }

    /// Copy URL, or Copy URL as Markdown, from the menu or its shortcut: the window
    /// confirms it with the same note.
    @discardableResult func copyCurrentURLWithNote(asMarkdown: Bool = false) -> Bool {
        guard asMarkdown ? copySelectedTabLinkAsMarkdown() : copySelectedTabLink(),
              let url = selectedTab.flatMap({ URL(string: $0.urlString) })
        else { return false }
        onCopiedCurrentURL?(url)
        return true
    }

    /// Capture…: the user outlines part of the page, which is copied as an image.
    @discardableResult func beginAreaCapture() -> Bool {
        guard canCaptureArea else { return false }
        return onBeginAreaCapture?() ?? false
    }

    /// `tabID` is the tab the outline was drawn over; another selected tab refuses.
    @discardableResult func captureArea(fraction: CGRect, tabID: String? = nil) -> Bool {
        guard canCreateTab, let selectedTabID, tabID == nil || tabID == selectedTabID,
              fraction.width > 0, fraction.height > 0
        else { return false }
        tabDriver.captureActiveTabRegionToPasteboard(fraction: fraction)
        return true
    }

    /// After Capture Area closes, the keys go back to the page.
    func focusSelectedPage() {
        tabDriver.focusActivePage()
    }

    /// A small picture of the page on screen, for a tab dragged out of the window.
    func captureSelectedPageThumbnail(maximumPixelSize: CGFloat, completion: @escaping @MainActor (NSImage?) -> Void) {
        guard selectedTabID != nil else {
            completion(nil)
            return
        }
        tabDriver.captureActiveTabPicture { png in
            completion(png.flatMap { BrowserImageThumbnailer.image(data: $0, maximumPixelSize: maximumPixelSize) })
        }
    }

    @discardableResult func beginPortraitCapture() -> Bool {
        guard canCaptureArea else { return false }
        tabDriver.captureActiveTabPicture { [weak self] png in
            if let png {
                self?.onPortraitCapture?(png)
            }
        }
        return true
    }

    @discardableResult func captureFullPageSelectedTabToPasteboard() -> Bool {
        guard selectedTabID != nil else {
            return false
        }

        tabDriver.captureFullPageActiveTabToPasteboard()
        return true
    }

    /// The engine side of an answer to a site permission request.
    func resolveSitePermissionInEngine(_ id: Int, allowed: Bool?) {
        tabDriver.resolveSitePermissionRequest(id, allowed: allowed)
    }

    /// Chromium's settings for a page that differ from the profile default.
    func siteSettingsInEngine(forURLString urlString: String) -> [BrowserSiteSettingKind: BrowserSiteSettingValue] {
        tabDriver.siteSettings(forURLString: urlString)
    }

    func setSiteSettingInEngine(
        _ kind: BrowserSiteSettingKind,
        value: BrowserSiteSettingValue,
        forURLString urlString: String,
    ) {
        tabDriver.setSiteSetting(kind, value: value, forURLString: urlString)
    }

    /// Mutes or brings back the sound of every open tab.
    @discardableResult func setAllTabsMuted(_ muted: Bool) -> Bool {
        guard canCreateTab else { return false }
        for tab in tabs {
            setTabMuted(muted, id: tab.id)
        }
        return true
    }

    func setTabMuted(_ muted: Bool, id: String) {
        guard let tab = tabs.first(where: { $0.id == id }),
              mutedTabSyncIDs.contains(tab.syncID) != muted else { return }
        if muted {
            mutedTabSyncIDs.insert(tab.syncID)
        } else {
            mutedTabSyncIDs.remove(tab.syncID)
        }
        tabDriver.setAudioMuted(muted, forTabWithID: id)
    }

    /// Copy URL as Markdown: `[title](url)` for the selected tab.
    @discardableResult func copySelectedTabLinkAsMarkdown() -> Bool {
        guard let selectedTab, !selectedTab.urlString.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(
            BrowserMarkdownLink.text(title: selectedTab.displayTitle, urlString: selectedTab.urlString),
            forType: .string,
        )
    }

    /// Copy URL as Quote with no server: a link that opens the page at
    /// the selected text and highlights it, as a text fragment Chromium and
    /// Safari follow.
    @discardableResult func copySelectedTextAsQuoteLink() async -> Bool {
        guard let tab = selectedTab else { return false }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let text = await tabDriver.requestActiveTabSelectedText() ?? ""
        // A late answer must not replace what was copied or selected since.
        guard selectedTabID == tab.id, pasteboard.changeCount == changeCount,
              let link = BrowserQuoteLink.urlString(pageURLString: tab.urlString, quote: text)
        else { return false }
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .URL)
        return pasteboard.setString(link, forType: .string)
    }

    /// Copy All Links: the addresses of a folder's tabs, its subfolders' too,
    /// in sidebar order, one per line.
    @discardableResult func copyAllLinks(inFolderID folderID: String) -> Bool {
        let snapshot = sidebarSnapshot
        guard let folder = snapshot.pinnedTabFolder(withID: folderID) else { return false }
        let links = BrowserSidebarTabTree(snapshot: snapshot)
            .tabIDs(in: .pinned(folder.spaceID, folderID: folderID))
            .compactMap { tabURLString(forTabID: $0) }
            .filter { !$0.isEmpty }
        guard !links.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(links.joined(separator: "\n"), forType: .string)
    }

    @discardableResult func copyTabLink(forTabID tabID: String) -> Bool {
        guard
            let urlString = tabURLString(forTabID: tabID),
            !urlString.isEmpty
        else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(urlString, forType: .string)
    }

    func refreshBrowserExtensions() {
        browserExtensions = extensionManager.installedExtensions()
        removeUnavailablePinnedExtensionsIfNeeded()
        closeExtensionSidePanelIfNeeded()
    }

    func openExtensionsManager() {
        openURLInNewTab(URL(string: BrowserExtensionRouting.extensionsURLString)!, atTop: true)
    }

    @discardableResult func openExtension(id: String) -> BrowserExtensionActionPopup? {
        guard
            isContextReady,
            let browserExtension = browserExtensions.first(where: { $0.id == id }),
            browserExtension.isEnabled
        else {
            return nil
        }

        switch extensionManager.runAction(id: id) {
        case .popup(let urlString):
            guard let extensionActionPopupDriver else {
                return nil
            }

            let popupID = extensionActionPopupDriver.openPopup(
                urlString: urlString,
                activeTab: currentTab.map { .init(urlString: $0.urlString, title: $0.displayTitle) },
            )
            let popup = BrowserExtensionActionPopup(
                id: popupID,
                extensionID: browserExtension.id,
                title: browserExtension.name,
                hostView: extensionActionPopupDriver.hostView,
                closeHandler: { [weak extensionActionPopupDriver] in
                    extensionActionPopupDriver?.closePopup(id: popupID)
                },
            )
            extensionActionPopupDriver.onContentSizeChange = { [weak popup] size in
                popup?.onContentSizeChange?(size)
            }
            return popup
        case .sidePanel:
            openExtensionSidePanel(id: id)
            return nil
        case .handled:
            if browserExtension.sidePanelURLString != nil {
                openExtensionSidePanel(id: id)
            }
            return nil
        case .failed:
            if browserExtension.sidePanelURLString != nil {
                openExtensionSidePanel(id: id)
            }
            return nil
        }
    }

    func openExtensionDetails(id: String) {
        openURLInNewTab(URL(string: BrowserExtensionRouting.detailsURLString(forExtensionID: id))!)
    }

    func openExtensionStore() {
        openURLInNewTab(URL(string: BrowserExtensionRouting.chromeWebStoreURLString)!)
    }

    func openExtensionStore(id: String) {
        openURLInNewTab(URL(string: BrowserExtensionRouting.chromeWebStoreURLString(forExtensionID: id))!)
    }

    @discardableResult func setExtension(id: String, isEnabled: Bool) -> Bool {
        guard extensionManager.setExtension(id: id, isEnabled: isEnabled) else {
            return false
        }

        refreshBrowserExtensions()
        return true
    }

    @discardableResult func openExtensionSidePanel(id: String) -> Bool {
        guard
            isContextReady,
            let extensionSidePanelDriver,
            let browserExtension = browserExtensions.first(where: { $0.id == id }),
            browserExtension.isEnabled,
            let urlString = browserExtension.sidePanelURLString
        else {
            return false
        }

        let panelID = extensionSidePanelDriver.openPanel(urlString: urlString)
        extensionSidePanel = BrowserExtensionSidePanel(
            panelID: panelID,
            extensionID: browserExtension.id,
            title: browserExtension.name,
            urlString: urlString,
            iconData: browserExtension.iconData,
        )
        return true
    }

    func closeExtensionSidePanel() {
        guard let sidePanel = extensionSidePanel else {
            return
        }

        extensionSidePanel = nil
        extensionSidePanelDriver?.closePanel(id: sidePanel.panelID)
    }

    @discardableResult func removeExtension(id: String) -> Bool {
        guard extensionManager.removeExtension(id: id) else {
            return false
        }

        setExtension(id: id, isPinned: false)
        refreshBrowserExtensions()
        return true
    }

    func isExtensionPinned(id: String) -> Bool {
        pinnedExtensionIDs.contains(id)
    }

    @discardableResult func setExtension(id: String, isPinned: Bool) -> Bool {
        let isCurrentlyPinned = pinnedExtensionIDs.contains(id)
        guard isCurrentlyPinned != isPinned else {
            return false
        }

        var updatedIDs = pinnedExtensionIDs.filter { $0 != id }
        if isPinned {
            updatedIDs.append(id)
        }
        setPinnedExtensionIDs(updatedIDs)
        return true
    }

    @discardableResult func toggleExtensionPinned(id: String) -> Bool {
        setExtension(id: id, isPinned: !isExtensionPinned(id: id))
    }

    func evaluateJavaScript(
        _ code: String,
        inTabWithID tabID: String,
        completion: @escaping @MainActor (String?) -> Void,
    ) {
        tabDriver.evaluateJavaScript(code, inTabWithID: tabID, completion: completion)
    }

    /// Sends a tab somewhere from a script. The selected tab keeps the durable path.
    func navigateTab(id: String, toURLString urlString: String) {
        if id == selectedTabID {
            navigateSelectedTab(toURLString: urlString)
            return
        }
        if !tabDriver.navigateTab(withID: id, toURLString: resolvedBrowserURLString(urlString)) {
            selectTab(id: id)
            navigateSelectedTab(toURLString: urlString)
        }
    }

    func setMediaVolumeInEngine(_ volume: Double, tabID: String) {
        tabDriver.setMediaVolume(volume, forTabWithID: tabID)
    }

    func recentSuggestions(onHost host: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        historyStore.suggestions(for: host, maximumCount: maximumCount)
            .filter { URLComponents(string: $0.resolvedURLString)?.host?.lowercased() == host }
    }

    /// Each renderer's process and the tabs it shows.
    func taskManagerPages() -> [Int32: [String]] {
        var pages = [Int32: [String]]()
        for (tabID, processID) in tabDriver.rendererProcessIDsByTabID() {
            guard let tab = tabs.first(where: { $0.id == tabID }) else { continue }
            pages[processID, default: []].append(tab.displayTitle)
        }
        return pages.mapValues { $0.sorted() }
    }

    func isPeekSessionOpen(_ sessionID: Int) -> Bool {
        tabDriver.isPeekSessionOpen(sessionID)
    }

    func hostPasswordPrompt(_ view: NSView, height: CGFloat, inPeekSession sessionID: Int) -> Bool {
        tabDriver.hostPrompt(view, height: height, inPeekSession: sessionID)
    }

    func fillAddressInEngine(json: String, frameID: String, origin: String, tabID: String) {
        tabDriver.fillAddress(json: json, frameID: frameID, origin: origin, tabID: tabID)
    }

    func fillPasswordInEngine(username: String, password: String, frameID: String, origin: String, tabID: String) {
        tabDriver.fillPassword(username: username, password: password, frameID: frameID, origin: origin, tabID: tabID)
    }

    /// Translates in place, or takes a translated page back to the original.
    /// Pages the engine cannot translate open in Google's translator instead.
    @discardableResult func translateCurrentPage() -> Bool {
        guard let tab = currentTab else { return false }
        let language = Self.translationLanguage(forPreferredLanguage: Locale.preferredLanguages.first)
        switch tabDriver.translationState(ofTabWithID: tab.id) {
        case .translated:
            tabDriver.revertTranslation(ofTabWithID: tab.id)
            return true
        case .translating:
            return true
        case .none:
            break
        }
        switch tabDriver.translateTab(withID: tab.id, toLanguage: language) {
        case .alreadyInLanguage:
            return true
        case .started:
            fallBackToTranslatorIfNeeded(tabID: tab.id, urlString: tab.urlString, language: language, attempts: 2)
            return true
        case .unavailable:
            return openPageInTranslator(tabID: tab.id, urlString: tab.urlString, language: language)
        }
    }

    /// An extension asked to select or close a tab. False when it is not in this window.
    @discardableResult func handleExtensionTabAction(browserIdentifier: Int32, closes: Bool) -> Bool {
        guard let tabID = tabDriver.tabID(forBrowserIdentifier: browserIdentifier),
              tabs.contains(where: { $0.id == tabID })
        else { return false }
        if closes {
            closeTab(id: tabID)
        } else {
            selectTab(id: tabID)
        }
        return true
    }

    /// Right-clicking back or forward lists the pages that way.
    func showNavigationList(goingBack: Bool, below anchor: NSView) {
        tabDriver.navigationEntriesForActiveTab { [weak self, weak anchor] entries, currentIndex in
            guard let self, let anchor else { return }
            BrowserNavigationListPanel.show(
                entries: BrowserNavigationEntry.list(entries, currentIndex: currentIndex, goingBack: goingBack),
                below: anchor,
            ) { [weak self] offset in
                self?.tabDriver.goToHistoryOffsetInActiveTab(offset)
            }
        }
    }

    func goBack() {
        guard canGoBack else {
            return
        }

        tabDriver.goBackActiveTab()
    }

    func goForward() {
        guard canGoForward else {
            return
        }

        tabDriver.goForwardActiveTab()
    }

    /// The engine keeps zoom per site, so the shown value is read back from the
    /// selected page instead of being remembered per tab.
    func refreshZoomFromEngine() {
        let level = selectedTabID.flatMap { tabDriver.zoomLevel(forTabWithID: $0) } ?? 0
        let exact = 100 * pow(1.2, level)
        let percent = Self.zoomPercentages.min { abs(Double($0) - exact) < abs(Double($1) - exact) } ?? 100
        if zoomPercent != percent {
            zoomPercent = percent
        }
    }

    func zoomIn() {
        refreshZoomFromEngine()
        guard let nextPercent = Self.zoomPercentages.first(where: { $0 > zoomPercent }) else {
            return
        }

        setZoomPercent(nextPercent)
    }

    func zoomOut() {
        refreshZoomFromEngine()
        guard let previousPercent = Self.zoomPercentages.last(where: { $0 < zoomPercent }) else {
            return
        }

        setZoomPercent(previousPercent)
    }

    func resetZoom() {
        setZoomPercent(100)
    }

    func openInLittleWindow(_ url: URL) {
        tabDriver.showLittleWindow(withURLString: url.absoluteString)
    }

    /// A web sign-in page in a small window, which its callback closes.
    func openSignInWindow(_ url: URL) {
        tabDriver.showSignInWindow(withURLString: url.absoluteString)
    }

    /// New Small Window: an empty small window with its address
    /// field focused.
    @discardableResult func openNewLittleWindow() -> Bool {
        guard canOpenLittleWindow else { return false }
        historyStore.prepareSearchIndex()
        if onPresentLittleWindowLauncher?() != true {
            tabDriver.showNewLittleWindow()
        }
        return true
    }

    /// Developer Tools with the element picker on.
    @discardableResult func inspectElements() -> Bool {
        guard selectedTabID != nil else { return false }
        tabDriver.inspectElementsInActiveTab()
        return true
    }

    func requestExtensionOpen(id: String) {
        onOpenExtensionRequest?(id)
    }

    /// Developer Tools on their Network panel.
    @discardableResult func showNetworkInspector() -> Bool {
        guard selectedTabID != nil else { return false }
        tabDriver.showNetworkInspectorForActiveTab()
        return true
    }

    /// Developer Tools on their Console panel.
    @discardableResult func showJavaScriptConsole() -> Bool {
        guard selectedTabID != nil else { return false }
        tabDriver.showJavaScriptConsoleForActiveTab()
        return true
    }

    /// The Library's Spaces section.
    @discardableResult func openSpacesInLibrary() -> Bool {
        guard supportsSpaces else { return false }
        openLibrary(section: .spaces)
        return true
    }

    /// The system's share sheet for the current page.
    @discardableResult func shareSelectedTab() -> Bool {
        guard let url = selectedTab.flatMap({ URL(string: $0.urlString) }), let onShareURL else { return false }
        onShareURL(url)
        return true
    }

    @discardableResult func showDeveloperTools() -> Bool {
        guard canShowDeveloperTools else { return false }
        tabDriver.showDevToolsForActiveTab()
        return true
    }

    /// View Source opens the page's source as a new tab.
    @discardableResult func viewSourceOfSelectedTab() -> Bool {
        guard canViewSource, let selectedTab else { return false }
        createTab(withURLString: "view-source:" + selectedTab.urlString)
        return true
    }

    func setZoomPercent(_ percent: Int) {
        guard canCreateTab, selectedTabID != nil, Self.zoomPercentages.contains(percent) else {
            return
        }

        zoomPercent = percent
        let zoomLevel = log(Double(percent) / 100) / log(1.2)
        tabDriver.setActiveTabZoomLevel(zoomLevel)
        onZoomChanged?(percent)
    }

    /// The selected page's certificate and its issuers, as DER, for the
    /// certificate panel; empty without a secure connection.
    func certificateChainOfSelectedTab() -> [Data] {
        guard selectedTab.flatMap({ URL(string: $0.urlString)?.scheme?.lowercased() }) == "https" else { return [] }
        return tabDriver.activeTabCertificateChain()
    }

    func castCurrentPage() {
        guard canCastPage else {
            return
        }

        tabDriver.castActiveTab()
    }

    func closeAllTabs() {
        let openTabIDs = tabs.map(\.id)
        if isShuttingDown {
            pendingTabCloseRequests.removeAll()
            localAutomaticArchiveCandidates.removeAll()
            closingTabIDs.formUnion(openTabIDs)
            for tabID in openTabIDs {
                tabDriver.closeTab(withID: tabID, forceClose: true)
            }
            return
        }

        changingTabRowsTogether {
            for tabID in openTabIDs {
                closeTab(id: tabID, registersUndo: false)
            }
        }
    }

    func applyRemoteSyncSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        guard !isShuttingDown else { return }
        guard !hasUncommittedSessionWrites, !hasDiscardedSessionForClosure else {
            // The coordinator must gate its durable commit too. Never retain a
            // stale projection to replay over successfully retried local actions.
            deferredRemoteSyncSnapshot = nil
            return
        }
        guard isContextReady, !isRestoringSession else {
            deferredRemoteSyncSnapshot = snapshot
            return
        }

        isApplyingRemoteSync = true
        isReconcilingRemoteProjection = true
        remoteProjectionGeneration += 1
        remoteProjectionSnapshot = snapshot
        hasCreatedInitialTab = true
        let previousSpaceSelections = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.selectedTabID) })
        var seenSyncIDs = Set<String>()
        let remoteTabs = snapshot.tabs.filter { tab in
            guard let id = tab.id, !id.isEmpty else { return false }
            return seenSyncIDs.insert(id).inserted
        }
        let remoteTabsByID = Dictionary(uniqueKeysWithValues: remoteTabs.compactMap { tab in
            tab.id.map { ($0, tab) }
        })

        for (engineID, binding) in pendingRemoteTabCreations {
            guard let replacement = remoteTabsByID[binding.snapshot.id ?? ""] else {
                pendingRemoteTabCreations.removeValue(forKey: engineID)
                discardedRemoteTabCreationIDs.insert(engineID)
                tabDriver.closeTab(withID: engineID, forceClose: true)
                continue
            }
            pendingRemoteTabCreations[engineID] = RemoteTabCreation(
                snapshot: replacement, generation: remoteProjectionGeneration,
            )
            if replacement.urlString != binding.snapshot.urlString {
                tabDriver.navigateTab(withID: engineID, toURLString: resolvedBrowserURLString(replacement.urlString))
            }
        }

        for tab in tabs where !seenSyncIDs.contains(tab.syncID)
            || ((closedAppTabIDs.contains(tab.id) || closedPinnedTabIDs.contains(tab.id))
                && remoteTabsByID[tab.syncID]?.placement != tab.placement)
        {
            closeTab(id: tab.id, forceClose: true, registersUndo: false, reason: .remoteProjection)
        }

        let restoredSpaces = snapshot.spaces?.isEmpty != false ? [] : restoredSpaces(from: snapshot)
        needsRemoteFallbackPublication = restoredSpaces.isEmpty
        if needsRemoteFallbackPublication {
            // Concurrent deletion can remove every space. The old default ID
            // may be tombstoned; this is a new local parent that must be queued.
            spaces = [makeDefaultSpace(id: UUID().uuidString)]
            hasLocalChangesDuringRemoteProjection = true
        } else {
            spaces = restoredSpaces
        }
        // A deferred launch projection carries this device's stored colors,
        // except for Spaces whose color was chosen since, None included.
        for space in snapshot.spaces ?? [] where isApplyingPeerSnapshot || !locallyColoredSpaceIDs.contains(space.id) {
            spaceThemesByID[space.id] = space.colorName.flatMap(BrowserSpaceTheme.init(stored:))
            spaceProfilesByID[space.id] = space.profileDirectory
        }
        pinnedTabFolders = restoredPinnedTabFolders(from: snapshot)
        if isApplyingPeerSnapshot {
            splitGroups = restoredSplitGroups(from: snapshot)
        }
        selectedSpaceID = selectedSpaceID.flatMap { selectedSpaceID in
            spaces.contains(where: { $0.id == selectedSpaceID }) ? selectedSpaceID : nil
        } ?? spaces.first?.id

        for index in tabs.indices {
            guard let remoteTab = remoteTabsByID[tabs[index].syncID] else { continue }
            var tab = tabs[index]
            applyRemoteTabMetadata(remoteTab, to: &tab)
            if isApplyingPeerSnapshot, hasNoPage(tab.id) {
                // The window with the page knows where it is now.
                if tab.urlString != remoteTab.urlString {
                    tab.urlString = remoteTab.urlString
                    tab.faviconURLString = nil
                }
                tab.title = remoteTab.pageTitle ?? tab.title
            }
            if isApplyingPeerSnapshot {
                tabIconsBySyncID[tab.syncID] = remoteTab.systemImageName
            }
            tabs[index] = tab
        }
        for index in spaces.indices {
            spaces[index].selectedTabID = previousSpaceSelections[spaces[index].id] ?? nil
        }

        let existingSyncIDs = Set(tabs.map(\.syncID))
        let pendingSyncIDs = Set(pendingRemoteTabCreations.values.compactMap(\.snapshot.id))
        for remoteTab in remoteTabs {
            guard let syncID = remoteTab.id,
                  !existingSyncIDs.contains(syncID), !pendingSyncIDs.contains(syncID)
            else { continue }
            if isApplyingPeerSnapshot {
                appendTabWithoutPage(remoteTab, syncID: syncID)
                continue
            }
            let engineID = createEngineTab(
                withURLString: remoteTab.urlString, makeActive: false,
                spaceID: remoteTab.placement == .app ? nil : remoteTab.spaceID,
            )
            pendingRemoteTabCreations[engineID] = RemoteTabCreation(
                snapshot: remoteTab, generation: remoteProjectionGeneration,
            )
        }
        isReconcilingRemoteProjection = false
        finishRemoteSyncProjectionIfReady()
    }

    func closeTabsBelow(id: String) {
        changingTabRowsTogether {
            for tabID in tabIDsBelowInSidebarOrder(forTabID: id) {
                closeTab(id: tabID)
            }
        }
    }

    /// Command-W: the tabs picked in the sidebar together, or else the shown one.
    @discardableResult func archiveSelectedTab() -> Bool {
        let picked = tabs.filter { sidebarMultiSelection.contains($0.id) }.map(\.id)
        if picked.count > 1, !isShuttingDown {
            var archived = false
            // Their rows leave the sidebar in one step.
            changingTabRowsTogether {
                for id in picked {
                    archived = archiveTab(id: id) || archived
                }
            }
            return archived
        }
        guard canArchiveSelectedTab, let selectedTabID else {
            return false
        }
        return archiveTab(id: selectedTabID)
    }

    @discardableResult func closeAppTabProcess(
        id: String,
        forceClose: Bool = false,
        engineAlreadyClosed: Bool = false,
    ) -> Bool {
        guard
            !closingTabIDs.contains(id),
            let tab = tabs.first(where: { $0.id == id }),
            tab.placement == .app,
            !closedAppTabIDs.contains(id)
        else {
            return false
        }

        if !forceClose, !engineAlreadyClosed {
            guard !isShuttingDown else { return false }
            return requestConfirmedTabClose(
                id: id, registersUndo: false, actionName: BrowserStrings.tabArchiveAction,
                createsArchive: false, preservesPersistentTab: true, unloadsPersistentTab: true,
            )
        }

        retireTabCreationCallbacks(id: id)
        if let home = effectivePinnedURLString(forPinnedTab: tab), !areEquivalentPinnedURLStrings(tab.urlString, home),
           let index = tabs.firstIndex(where: { $0.id == id })
        {
            tabs[index].title = ""
            tabs[index].urlString = home
            tabs[index].faviconURLString = nil
            tabs[index].canGoBack = false
            tabs[index].canGoForward = false
            tabs[index].isLoading = false
        }
        closedAppTabIDs.insert(id)
        removeTabFromSwitcherTracking(id)
        BrowserTelemetry.captureUsage(.tabClosed, properties: telemetryProperties(for: tab))

        if selectedTabID == id {
            clearSelectedTab(id, forSpaceID: tab.spaceID)
            let fallbackTabID = fallbackTabID(afterClosingDormantTab: tab, excluding: [id])
            selectedTabID = fallbackTabID
            findResultMatchCount = nil
            if let fallbackTabID {
                tabDriver.selectTab(withID: fallbackTabID)
                setSelectedTabID(fallbackTabID, forSpaceID: tab.spaceID)
                recordSelectedTab(fallbackTabID)
                runFind(forward: true, findNext: false)
            } else {
                tabDriver.deselectActiveTab()
            }
        }

        if !engineAlreadyClosed {
            tabDriver.closeTab(withID: id, forceClose: forceClose)
        }
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        return true
    }

    @discardableResult func closePinnedTabProcessOrReset(
        id: String,
        forceClose: Bool = false,
        engineAlreadyClosed: Bool = false,
    ) -> Bool {
        guard
            !closingTabIDs.contains(id),
            let tab = tabs.first(where: { $0.id == id }),
            tab.placement == .spacePinned,
            let pinnedURLString = effectivePinnedURLString(forPinnedTab: tab),
            !closedPinnedTabIDs.contains(id)
        else {
            return false
        }

        if !forceClose, !engineAlreadyClosed {
            guard !isShuttingDown else { return false }
            return requestConfirmedTabClose(
                id: id, registersUndo: false, actionName: BrowserStrings.tabArchiveAction,
                createsArchive: false, preservesPersistentTab: true, unloadsPersistentTab: true,
            )
        }

        retireTabCreationCallbacks(id: id)
        if !areEquivalentPinnedURLStrings(tab.urlString, pinnedURLString),
           let index = tabs.firstIndex(where: { $0.id == id })
        {
            tabs[index].title = ""
            tabs[index].urlString = pinnedURLString
            tabs[index].faviconURLString = nil
            tabs[index].canGoBack = false
            tabs[index].canGoForward = false
            tabs[index].isLoading = false
        }

        closedPinnedTabIDs.insert(id)
        removeTabFromSwitcherTracking(id)
        BrowserTelemetry.captureUsage(.tabClosed, properties: telemetryProperties(for: tab))

        if selectedTabID == id {
            clearSelectedTab(id, forSpaceID: tab.spaceID)
            let fallbackTabID = fallbackTabID(afterClosingDormantTab: tab, excluding: [id])
            selectedTabID = fallbackTabID
            findResultMatchCount = nil
            if let fallbackTabID {
                tabDriver.selectTab(withID: fallbackTabID)
                setSelectedTabID(fallbackTabID, forSpaceID: tab.spaceID)
                recordSelectedTab(fallbackTabID)
                runFind(forward: true, findNext: false)
            } else {
                tabDriver.deselectActiveTab()
            }
        }

        if !engineAlreadyClosed {
            tabDriver.closeTab(withID: id, forceClose: forceClose)
        }
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
        return true
    }

    func removeAppTabFavorite(id: String) {
        if closedAppTabIDs.contains(id), let tab = tabs.first(where: { $0.id == id }) {
            tabs.removeAll { $0.id == id }
            closedAppTabIDs.remove(id)
            removeTabFromSwitcherTracking(id)
            clearSelectedTab(id, forSpaceID: tab.spaceID)
            updateWindowTitle()
            persistCurrentSessionIfAllowed()
            return
        }

        moveTab(
            withID: id,
            toPlacement: .temporary,
            atSectionIndex: temporaryTabs.count,
        )
    }

    func hasTabsBelow(id: String) -> Bool {
        !tabIDsBelowInSidebarOrder(forTabID: id).isEmpty
    }

    func selectTab(id: String) {
        guard
            let tab = tabs.first(where: { $0.id == id }),
            !blocksTabInteraction(id)
        else {
            return
        }
        if pendingTabCloseRequests[id]?.localAutomaticCandidate != nil {
            pendingTabCloseRequests[id]?.invalidatedAutomaticClose = true
        }

        let didRecordActivity = recordExplicitViewingActivity(ids: [selectedTabID, id])

        if closedAppTabIDs.contains(id), tab.placement == .app {
            reopenClosedAppTab(id: id)
            return
        }

        if closedPinnedTabIDs.contains(id), tab.placement != .app {
            reopenClosedPinnedTab(id: id)
            return
        }

        guard selectedTabID != id else {
            if didRecordActivity {
                persistCurrentSessionIfAllowed()
            }
            return
        }

        captureSelectedTabPreviewIfNeeded()
        dismissCommandBar()
        // Another tab never shows behind a page in fullscreen.
        if pageFullscreenTabID != nil, pageFullscreenTabID != id {
            exitPageFullscreen()
        }

        if tab.spaceID != selectedSpaceID {
            selectedSpaceID = tab.spaceID
        }
        selectedTabID = id
        setSelectedTabID(id, forSpaceID: tab.spaceID)
        findResultMatchCount = nil
        tabDriver.selectTab(withID: id)
        scheduleSelectedTabWebAppManifestLoad()
        recordSelectedTab(id)
        updateWindowTitle()
        BrowserTelemetry.captureUsage(.tabSelected, properties: telemetryProperties(for: tab))
        persistSessionSoon()
        runFind(forward: true, findNext: false)
    }

    @discardableResult func advanceTabSwitcher(reverse: Bool = false) -> Bool {
        if var state = tabSwitcherState, !state.entries.isEmpty {
            let selectedIndex = state.entries.firstIndex { $0.id == state.selectedTabID } ?? 0
            let offset = reverse ? -1 : 1
            let nextIndex = (selectedIndex + offset + state.entries.count) % state.entries.count
            state.selectedTabID = state.entries[nextIndex].id
            tabSwitcherState = state
            return true
        }

        captureSelectedTabPreviewIfNeeded()
        let entries = tabSwitcherEntries()
        guard entries.count > 1 else {
            return false
        }

        let initialSelectionIndex = reverse ? entries.count - 1 : 1
        tabSwitcherState = TabSwitcherState(
            entries: entries,
            selectedTabID: entries[initialSelectionIndex].id,
            isVisible: false,
        )
        scheduleTabSwitcherPresentation()
        return true
    }

    @discardableResult func commitTabSwitcher() -> Bool {
        guard let state = tabSwitcherState else {
            return false
        }

        clearTabSwitcherState()
        if selectedTabID != state.selectedTabID {
            selectTab(id: state.selectedTabID)
        }
        return true
    }

    @discardableResult func cancelTabSwitcher() -> Bool {
        guard tabSwitcherState != nil else {
            return false
        }

        clearTabSwitcherState()
        return true
    }

    @discardableResult func closeTab(
        id: String,
        forceClose: Bool = false,
        registersUndo: Bool = true,
        undoActionName: String = BrowserStrings.tabArchiveAction,
        reason: TabCloseReason = .manual,
    ) -> Bool {
        guard let closingIndex = tabs.firstIndex(where: { $0.id == id }) else { return false }
        // A remote/structural removal supersedes an outstanding local dialog.
        // It must not be rejected merely because that request owns the close ID.
        if forceClose || reason == .structuralRemoval || reason == .remoteProjection {
            if let superseded = pendingTabCloseRequests.removeValue(forKey: id) {
                closingTabIDs.remove(id)
                superseded.completion?(.removed)
                if superseded.localAutomaticCandidate != nil {
                    localAutomaticArchiveCandidates.removeAll()
                }
            }
        }
        guard !closingTabIDs.contains(id) else { return false }
        if reason == .manual, !forceClose, !isShuttingDown {
            // Capture the user's action once. Removing a persistent row remains
            // a logical removal even if its placement changes during approval.
            let archives = tabs[closingIndex].placement == .temporary
            return requestConfirmedTabClose(
                id: id, registersUndo: registersUndo, actionName: undoActionName,
                createsArchive: archives, preservesPersistentTab: archives,
                historyKind: archives ? .archive : .logicalRemoval,
            )
        }
        return finishTabClose(
            id: id, forceClose: forceClose, requestsEngineClose: true,
            registersUndo: registersUndo, undoActionName: undoActionName,
        )
    }

    func setUserTitleOverride(_ titleOverride: String?, forTabID tabID: String) {
        withArrangementUndo(BrowserStrings.undoRenameAction) {
            guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
                return
            }

            let sanitizedTitleOverride = sanitizedUserTitleOverride(from: titleOverride)
            guard tabs[index].userTitleOverride != sanitizedTitleOverride else {
                return
            }

            tabs[index].userTitleOverride = sanitizedTitleOverride
            updateWindowTitle()
            persistCurrentSessionIfAllowed()
        }
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func setSidebarWidth(_ width: CGFloat) {
        let clampedWidth = min(max(width, Self.minSidebarWidth), Self.maxSidebarWidth)
        guard sidebarWidth != clampedWidth else {
            return
        }
        sidebarWidth = clampedWidth
        if isSidebarResizing {
            onLiveSidebarWidthChange?()
        }
    }

    func setExtensionSidePanelWidth(_ width: CGFloat) {
        let clampedWidth = min(max(width, Self.minExtensionSidePanelWidth), Self.maxExtensionSidePanelWidth)
        guard extensionSidePanelWidth != clampedWidth else {
            return
        }
        extensionSidePanelWidth = clampedWidth
    }

    func persistSidebarWidthPreferenceIfAllowed() {
        guard isContextReady, isPersistenceEnabled, !isRestoringSession else {
            return
        }

        sessionPreferencesStore.saveSidebarWidth(sidebarWidth)
    }

    /// Split View edits persist like other local tree edits. The store keeps
    /// them out of sync because sync payloads never include split groups.
    func persistSplitGroupChange() {
        persistCurrentSessionIfAllowed()
    }

    func sendVisibleTabLayout(_ layout: BrowserTabVisibleLayout?) {
        tabDriver.setVisibleTabLayout(layout)
    }

    /// Peek's Open in Split View: the page becomes a pane beside the shown tab.
    /// False when the shown tab cannot take another pane.
    /// True once the page has a tab, split or not, so the caller never opens a
    /// second one. Web-app windows have no splits.
    @discardableResult func openURLInSplitView(_ url: URL) -> Bool {
        guard !isWebApp, canAddSplitView, let anchor = selectedTabID else { return false }
        createTab(withURLString: url.absoluteString)
        if let tabID = selectedTabID, tabID != anchor {
            openInSplitView(tabID: tabID, anchorTabID: anchor)
        }
        return true
    }

    /// Picture in Picture on leaving a tab: a playing video follows the
    /// user out of its tab and returns when they come back. Panes that stay on
    /// screen in a split and closing tabs are left alone.
    /// The engine side of a media control.
    func controlMediaInEngine(_ action: BrowserMediaAction, tabID: String) {
        tabDriver.controlMedia(action, inTabWithID: tabID)
    }

    /// Whether leaving the tab moved its video to Picture in Picture.
    func pictureInPictureDidEnd(tabID: String, showsTab: Bool) {
        pictureInPictureTabIDs.remove(tabID)
        // A video still playing came back through "back to tab", unless another tab's
        // video took the one window: going back would push that one out in turn, and
        // two playing videos would switch tabs back and forth without end.
        let takenOver = pictureInPictureTabIDs.contains { $0 != tabID }
            || tabMediaStates.contains { $0.key != tabID && $0.value.inPictureInPicture }
        guard showsTab, !takenOver, selectedTabID != tabID, !isShuttingDown else { return }
        selectTab(id: tabID)
        hostView.window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult func togglePictureInPicture() -> Bool {
        guard canTogglePictureInPicture else { return false }
        tabDriver.togglePictureInPictureInActiveTab()
        return true
    }

    func isInPictureInPicture(tabID: String) -> Bool {
        pictureInPictureTabIDs.contains(tabID) || tabMediaStates[tabID]?.inPictureInPicture == true
    }

    func isCommandBarActionAvailable(_ commandID: BrowserCommandID) -> Bool {
        switch commandID {
        case .openSettings,
             .setAsDefaultBrowser:
            true
        case .newTab:
            canCreateTab
        case .openLocation:
            canOpenLocation
        case .zoomIn:
            canZoomIn
        case .zoomOut:
            canZoomOut
        case .resetZoom:
            canResetZoom
        case .stopLoading:
            canStopLoading
        case .inspectElements:
            canShowDeveloperToolsForCommand
        case .javaScriptConsole:
            canShowDeveloperToolsForCommand
        case .manageSpaces:
            supportsSpaces
        case .translatePage:
            currentTab?.urlString.hasPrefix("http") == true
        case .addBottomSplit:
            canAddSplitView
        case .addTopSplit:
            canAddSplitView
        case .addRightSplit:
            canAddSplitView
        case .addLeftSplit:
            canAddSplitView
        case .capturePortrait:
            canCaptureArea
        case .blankWindow:
            true
        case .viewMedia:
            supportsSpaces
        case .networkInspector:
            canShowDeveloperToolsForCommand
        case .toggleDeveloperMode:
            canToggleDeveloperMode
        case .editSpaceTheme:
            supportsSpaces
        case .togglePictureInPicture:
            canTogglePictureInPicture
        case .muteAllTabs:
            canCreateTab && tabs.contains { !mutedTabSyncIDs.contains($0.syncID) }
        case .unmuteAllTabs:
            canCreateTab && !mutedTabSyncIDs.isEmpty
        case .shareTab:
            canShareSelectedTab
        case .developerTools:
            canShowDeveloperTools
        case .viewSource:
            canViewSource
        case .restoreLastClosedTab:
            canRestoreLastClosedTab
        case .newWindow:
            !isShuttingDown
        case .newIncognitoWindow:
            !isShuttingDown
        case .newLittleWindow:
            canOpenLittleWindow
        case .openHistory:
            canCreateTab && !isShuttingDown
        case .toggleBookmark:
            selectedTab?.urlString.isEmpty == false
        case .archiveTab:
            canArchiveSelectedTab
        case .viewArchive:
            canBrowseArchive
        case .clearArchive:
            canBrowseArchive && !isArchiveOperationInFlight
        case .savePage:
            canSavePage
        case .printPage:
            canPrintPage
        case .copyLink,
             .copyLinkAsMarkdown:
            canCopySelectedTabLink
        case .copyLinkAsQuote:
            canCopySelectedTextAsQuoteLink
        case .findInPage:
            canPresentFindInPage
        case .findAndReplace,
             .jumpToSelection:
            false
        case .findNext,
             .findPrevious:
            canStepThroughFindMatches
        case .clearTemporaryTabs:
            canClearTemporaryTabs
        case .viewDownloads:
            onToggleDownloads != nil
        case .viewLibrary:
            supportsSpaces
        case .togglePinTab:
            canTogglePinSelectedTab
        case .duplicateTab:
            selectedTabID.map { canDuplicateTab(id: $0) } ?? false
        case .renameTab:
            canRenameSelectedTab
        case .resetTabToPinnedURL:
            canResetSelectedTabToPinnedURL
        case .resetSpaceTabs:
            canResetSpaceTabs()
        case .collapseAllFolders:
            canSetActiveSpaceFoldersExpanded(false)
        case .expandAllFolders:
            canSetActiveSpaceFoldersExpanded(true)
        case .newSpace:
            supportsSpaces && !isShuttingDown
        case .newFolder:
            canCreateFolder
        case .captureFullPage:
            canCreateTab && selectedTabID != nil
        case .captureArea:
            canCaptureArea
        case .goToLastSidebarItem,
             .selectNextTab,
             .selectPreviousTab:
            !sidebarItemTabIDs.isEmpty
        case .selectNextTabAlternate,
             .selectPreviousTabAlternate:
            // The command bar lists Next/Previous Tab once.
            false
        case .selectNextSpace,
             .selectPreviousSpace:
            supportsSpaces && spaces.count > 1
        case .revealCurrentTab:
            canRevealSelectedTab
        case .openExtensions:
            canOpenExtensions
        case .goToSidebarItem1,
             .goToSidebarItem2,
             .goToSidebarItem3,
             .goToSidebarItem4,
             .goToSidebarItem5,
             .goToSidebarItem6,
             .goToSidebarItem7,
             .goToSidebarItem8:
            sidebarItemTabIDs.count > commandID.sidebarItemIndex
        case .goBack:
            canGoBack
        case .goForward:
            canGoForward
        case .clearCacheAndRefresh,
             .clearCookiesAndRefresh,
             .forceReload,
             .reload:
            canReload
        case .addSplitView:
            canAddSplitView
        case .closeSplitPane,
             .separateSplitView,
             .separateTabFromSplit,
             .toggleSplitOrientation:
            selectedSplitGroup != nil && !isShuttingDown
        case .focusSplitPane1,
             .focusSplitPane2,
             .focusSplitPane3,
             .focusSplitPane4:
            selectedSplitGroup.map { splitPaneTabIDs(of: $0).count > commandID.splitPaneIndex } == true
        case .expandCurrentSplit,
             .focusNextSplitPane,
             .focusPreviousSplitPane:
            selectedSplitGroup != nil
        case .toggleSidebar:
            true
        case .toggleSidebarPosition:
            !isWebApp
        case .toggleBookmarksBar:
            true
        case .customizeToolbar,
             .toggleSiteToolbar:
            !isWebApp
        }
    }

    /// Follows a session saved by another window of this profile.
    func applyPeerSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        // A window still starting up reads the store when it is ready.
        guard isContextReady, !isRestoringSession, !isShuttingDown else { return }
        isApplyingPeerSnapshot = true
        defer { isApplyingPeerSnapshot = false }
        applyRemoteSyncSnapshot(snapshot)
    }

    /// The window with this tab's page saw its title change.
    func applyPeerPageTitle(_ title: String, syncID: String) {
        guard let index = tabs.firstIndex(where: { $0.syncID == syncID }), hasNoPage(tabs[index].id),
              tabs[index].title != title
        else { return }
        tabs[index].title = title
        updateWindowTitle()
    }

    func selectTab(syncID: String) {
        guard let id = tabs.first(where: { $0.syncID == syncID })?.id else { return }
        selectTab(id: id)
    }

    func hasPage(forSyncID syncID: String) -> Bool {
        tabs.first { $0.syncID == syncID }.map { !hasNoPage($0.id) && !closingTabIDs.contains($0.id) } ?? false
    }

    /// Another window opened this tab: its page closes here and the row stays, ready to
    /// reopen at the same address.
    func releasePage(forSyncID syncID: String) {
        guard let index = indexOfTabWithPage(forSyncID: syncID) else { return }
        let id = tabs[index].id
        leavePage(at: index, movedLive: false)
        tabDriver.closeTab(withID: id, forceClose: true)
    }

    /// Another window shows this tab: the live page moves there and the row stays here
    /// without one. Nil, with nothing changed, when the page cannot move now.
    func detachPage(forSyncID syncID: String) -> BrowserTabPageHandoff? {
        guard let index = indexOfTabWithPage(forSyncID: syncID),
              var handoff = tabDriver.detachPage(ofTabWithID: tabs[index].id)
        else { return nil }
        handoff.profileCachePath = engineProfilePathsByID.removeValue(forKey: tabs[index].id) ?? nil
        if let id = leavePage(at: index, movedLive: true) {
            let size = hostView.bounds.size
            let maximumPixelSize = max(size.width, size.height) * (hostView.window?.backingScaleFactor ?? 2)
            tabDriver.capturePicture(of: handoff) { [weak self] png in
                guard let self, movedPageTabIDs.contains(id), let png,
                      let picture = BrowserImageThumbnailer.image(data: png, maximumPixelSize: max(maximumPixelSize, 1))
                else { return }
                movedPagePictures[id] = picture
            }
        }
        return handoff
    }

    /// Takes a Today tab out of this window with its live page, for a new window; nil when
    /// the page cannot move, and nothing changes then.
    func removeTabKeepingPage(id: String, undoActionName: String) -> BrowserTabPageHandoff? {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].placement == .temporary,
              !hasNoPage(id), !closingTabIDs.contains(id),
              var handoff = tabDriver.detachPage(ofTabWithID: id)
        else { return nil }
        handoff.profileCachePath = engineProfilePathsByID.removeValue(forKey: id) ?? nil
        handoff.title = tabs[index].title
        handoff.urlString = tabs[index].urlString
        finishTabClose(
            id: id, forceClose: true, requestsEngineClose: false,
            registersUndo: true, undoActionName: undoActionName,
        )
        return handoff
    }

    /// A live page from another window becomes a new Today tab here.
    @discardableResult func adoptPageAsNewTab(_ handoff: BrowserTabPageHandoff, makeActive: Bool) -> String? {
        guard canCreateTab, let id = tabDriver.adoptPage(handoff, makeActive: makeActive) else { return nil }
        engineProfilePathsByID.updateValue(handoff.profileCachePath, forKey: id)
        handleCreatedTab(id: id, title: handoff.title, urlString: handoff.urlString, isActive: makeActive)
        handleTabCreationStateChange(id: id, state: .ready)
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            applyAdoptedPage(handoff, toTabAt: index)
        }
        return id
    }

    /// This window is closing: its pages stay alive in another window of the profile,
    /// one that shows a picture of the page if there is one, or else the oldest.
    func handPagesToOtherWindows() {
        guard let group = windowGroup, let oldest = group.models.first(where: { $0 !== self }) else { return }
        for tab in tabs where !hasNoPage(tab.id) && !closingTabIDs.contains(tab.id) {
            let receiver = group.models.first { $0 !== self && $0.showsMovedPage(syncID: tab.syncID) } ?? oldest
            receiver.keepPageOfClosingWindow(syncID: tab.syncID)
        }
    }

    /// A tab a link opened goes right below its Today opener, or at the top of Today
    /// when a pinned tab or Favorite opened it, after the tabs opened from the same
    /// tab before.
    func placeTabOpened(id: String, fromTabID openerID: String) {
        guard let opener = tabs.first(where: { $0.id == openerID }),
              let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].placement == .temporary
        else { return }
        let spaceID = tabs[index].spaceID
        let start: Int
        if opener.placement == .temporary {
            guard opener.spaceID == spaceID,
                  let openerIndex = tabs.firstIndex(where: { $0.id == openerID }) else { return }
            start = openerIndex + 1
        } else {
            guard let firstToday = tabs.firstIndex(where: { $0.spaceID == spaceID && $0.placement == .temporary })
            else { return }
            start = firstToday
        }
        guard start <= index else { return }
        var target = start
        while target < index, tabOpenerIDs[tabs[target].id] == openerID {
            target += 1
        }
        tabOpenerIDs[id] = openerID
        guard target < index else { return }
        moveTab(id: id, toGlobalIndex: target)
        persistCurrentSessionIfAllowed()
    }

    /// Asks the page in fullscreen to leave it.
    func exitPageFullscreen() {
        guard pageFullscreenTabID != nil else { return }
        tabDriver.exitPageFullscreen()
    }

    /// Brings back the page of the selected tab from the window that took it.
    func showMovedPageHere() {
        guard showsMovedPage, let id = selectedTabID else { return }
        selectTab(id: id)
    }

    /// A closed window's pages close with it; its tabs stay in the store and in the
    /// profile's other windows. Without this they kept running in the hidden window.
    func closePagesOfClosedWindow() {
        guard isShuttingDown else { return }
        for tab in tabs where !hasNoPage(tab.id) {
            tabDriver.closeTab(withID: tab.id, forceClose: true)
        }
    }

    /// The window is named after its shown tab, or its Space without one.
    func updateWindowTitle() {
        let title = tabs.first(where: { $0.id == selectedTabID })?.displayTitle
            ?? spaces.first(where: { $0.id == selectedSpaceID })?.title
            ?? BrowserStrings.applicationName
        windowTitleHandler(title)
    }

    /// New Tab in a small window: the same results as its bar, going to `navigate`.
    func makeLittleWindowSearchModel(navigate: @escaping (String) -> Void) -> BrowserCommandBarModel {
        makeCommandBarModel(forLittleWindow: true, submit: navigate)
    }

    /// Saves a tab switch once the new page has had time to show: the write reads and
    /// rewrites the whole session on the main thread, which also draws the page. Quick
    /// switches share one write, and any other save includes the selection and drops it.
    /// Saves a tab switch still waiting, now.
    func persistPendingSelection() {
        guard pendingSelectionPersist != nil else { return }
        persistCurrentSessionIfAllowed()
    }

    /// Rows that one action takes away leave the sidebar together, not one by one.
    func changingTabRowsTogether(_ changes: () -> Void) {
        tabRowChangeBatchDepth += 1
        changes()
        tabRowChangeBatchDepth -= 1
        if tabRowChangeBatchDepth == 0, tabRowsChangedInBatch {
            tabRowsChangedInBatch = false
            onTabRowsChanged?()
        }
    }

    @discardableResult private func archiveTab(id: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return false
        }

        if tab.placement == .app {
            return closeAppTabProcess(id: id)
        }

        if tab.placement == .spacePinned, effectivePinnedURLString(forPinnedTab: tab) != nil {
            return closePinnedTabProcessOrReset(id: id)
        }

        return closeTab(id: id)
    }

    /// Saves shortly after a change that shows at once: the save reads and rewrites the
    /// whole session on the main thread, about 10 ms that would hold its first frames.
    private func persistSessionSoon() {
        pendingSelectionPersist?.invalidate()
        let timer = Timer(timeInterval: Self.selectionPersistDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingSelectionPersist != nil else { return }
                self.persistCurrentSessionIfAllowed()
            }
        }
        pendingSelectionPersist = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Shows a row change at once, or with the rest of the batch it belongs to.
    private func tabRowsChanged() {
        if tabRowChangeBatchDepth > 0 {
            tabRowsChangedInBatch = true
        } else {
            onTabRowsChanged?()
        }
    }

    private func showsMovedPage(syncID: String) -> Bool {
        tabs.first { $0.syncID == syncID }.map { movedPageTabIDs.contains($0.id) && hasNoPage($0.id) } ?? false
    }

    /// Takes a closing window's live page for this tab, shown only if this window has the
    /// tab selected. A page that cannot move closes with its window.
    private func keepPageOfClosingWindow(syncID: String) {
        guard canCreateTab, let index = tabs.firstIndex(where: { $0.syncID == syncID }), hasNoPage(tabs[index].id)
        else { return }
        let tab = tabs[index]
        let isSelected = selectedTabID == tab.id
        guard let adopted = adoptPageFromAnotherWindow(syncID: syncID, makeActive: isSelected) else { return }
        lastPageRestoreTabIDs.remove(tab.id)
        closedPinnedTabIDs.remove(tab.id)
        closedAppTabIDs.remove(tab.id)
        tabs[index] = reidentifiedTab(from: tab, id: adopted.id)
        applyAdoptedPage(adopted.handoff, toTabAt: index)
        replaceTabRuntimeReferences(oldID: tab.id, newID: adopted.id, spaceID: tab.spaceID, selectsInSpace: false)
        if isSelected {
            tabDriver.selectTab(withID: adopted.id)
            updateWindowTitle()
        }
    }

    private func indexOfTabWithPage(forSyncID syncID: String) -> Int? {
        guard !isShuttingDown, let index = tabs.firstIndex(where: { $0.syncID == syncID }),
              !hasNoPage(tabs[index].id), !closingTabIDs.contains(tabs[index].id)
        else { return nil }
        return index
    }

    /// The row at `index` stays without a page. A selected one whose page moved live stays
    /// selected and shows the page's picture, returning its ID; one whose page closed gives
    /// way to another tab.
    @discardableResult private func leavePage(at index: Int, movedLive: Bool) -> String? {
        let tab = tabs[index]
        let wasSelected = selectedTabID == tab.id
        let newID = UUID().uuidString
        retireTabCreationCallbacks(id: tab.id)
        tabs[index] = reidentifiedTab(from: tab, id: newID)
        markWithoutPage(newID, placement: tab.placement)
        replaceTabRuntimeReferences(oldID: tab.id, newID: newID, spaceID: tab.spaceID, selectsInSpace: false)
        guard wasSelected else { return nil }
        if movedLive, splitPaneTabIDs(forTabID: newID).count <= 1 {
            movedPageTabIDs.insert(newID)
            findResultMatchCount = nil
            tabDriver.deselectActiveTab()
            updateWindowTitle()
            return newID
        }
        clearSelectedTab(newID, forSpaceID: tab.spaceID)
        // The window shows another tab of its own, not an empty page.
        let elsewhere = Set(tabs.map(\.id).filter(isPageInAnotherWindow))
        let fallback = fallbackTabID(afterClosingDormantTab: tabs[index], excluding: elsewhere.union([newID]))
        if let fallback, hasNoPage(fallback) {
            selectTab(id: fallback)
            updateWindowTitle()
            return nil
        }
        selectedTabID = fallback
        findResultMatchCount = nil
        if let fallback {
            tabDriver.selectTab(withID: fallback)
            setSelectedTabID(fallback, forSpaceID: tab.spaceID)
            recordSelectedTab(fallback)
        } else {
            tabDriver.deselectActiveTab()
        }
        updateWindowTitle()
        return nil
    }

    /// The small window's bar opens every result in the small window, so its
    /// tabs are pages to open there, not tabs to switch to.
    private func makeCommandBarModel(
        forLittleWindow: Bool = false,
        submit: @escaping (String) -> Void,
    ) -> BrowserCommandBarModel {
        BrowserCommandBarModel(
            suggestionProvider: commandBarSuggestionProvider,
            navigationResolver: navigationResolver,
            localSuggestionProvider: { [weak self] query, maximumCount in
                let suggestions = self?.localCommandSuggestions(for: query, maximumCount: maximumCount) ?? []
                return forLittleWindow ? suggestions.map(Self.pageSuggestion(forTabSuggestion:)) : suggestions
            },
            remoteSuggestionsEnabledProvider: { [weak self] in
                self?.canLoadRemoteSearchSuggestions ?? false
            },
            aiSearchProviderProvider: { [weak self] in
                self?.userPreferencesStore.aiSearchProvider ?? .chatGPT
            },
            aiSearchEnabledProvider: { [weak self] in
                self?.userPreferencesStore.showsAISearchSuggestion ?? false
            },
            recentPagesProvider: { [weak self] maximumCount in
                forLittleWindow
                    ? self?.recentLittleWindowPages(maximumCount: maximumCount) ?? []
                    : self?.recentCommandBarPages(maximumCount: maximumCount) ?? []
            },
            siteSearchesProvider: { [weak self] in
                self?.userPreferencesStore.siteSearches ?? []
            },
            siteRecentPagesProvider: { [weak self] site, maximumCount in
                site.resultsURLPrefix.map {
                    self?.historyStore.recentSuggestions(withURLPrefix: $0, maximumCount: maximumCount) ?? []
                } ?? []
            },
            submitHandler: submit,
            openTabHandler: { [weak self] tabIDs in
                self?.openCommandBarTabSelection(tabIDs: tabIDs)
            },
            commandHandler: { [weak self] commandID in
                guard let self else { return }
                commandHandler(commandID, self)
            },
        )
    }

    /// An inline translation reports no failure, so check that it took effect.
    private func fallBackToTranslatorIfNeeded(tabID: String, urlString: String, language: String, attempts: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, tabs.first(where: { $0.id == tabID })?.urlString == urlString else { return }
            switch tabDriver.translationState(ofTabWithID: tabID) {
            case .translated:
                break
            case .translating where attempts > 1:
                fallBackToTranslatorIfNeeded(
                    tabID: tabID,
                    urlString: urlString,
                    language: language,
                    attempts: attempts - 1,
                )
            case .none, .translating:
                _ = openPageInTranslator(tabID: tabID, urlString: urlString, language: language)
            }
        }
    }

    private func openPageInTranslator(tabID: String, urlString: String, language: String) -> Bool {
        guard let url = Self.translatedPageURL(for: urlString, language: language) else { return false }
        navigateTab(id: tabID, toURLString: url.absoluteString)
        return true
    }

    private func reportExtensionTabs() {
        tabDriver.setWarmTabs(Self.warmTabIDs(spaces: spaces, selectedSpaceID: selectedSpaceID, tabs: tabs))
        tabDriver.reportExtensionTabs(
            windowKey: extensionWindowKey,
            focused: tabDriver.hostView.window?.isKeyWindow ?? false,
            tabs: Self.extensionTabReports(tabs: tabs, selectedTabID: selectedTabID),
        )
    }

    private func copyFolder(_ source: PinnedTabFolder) -> String? {
        guard let copyID = createEmptyPinnedFolder(title: source.title, inSpaceID: source.spaceID) else { return nil }
        setIcon(source.systemImageName, forPinnedTabFolderID: copyID)
        let items = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
            .items(in: .pinned(source.spaceID, folderID: source.id))
        var order = [BrowserSidebarItemID]()
        for item in items {
            switch item {
            case .tab(let id):
                guard let tab = tabs.first(where: { $0.id == id }) else { continue }
                let home = tab.pinnedURLString ?? tab.urlString
                let tabID = UUID().uuidString
                restoredTabCreationIDs.insert(tabID)
                tabs.append(Tab(
                    id: tabID,
                    syncID: tabSyncIDProvider(),
                    spaceID: source.spaceID,
                    title: tab.title,
                    userTitleOverride: tab.userTitleOverride,
                    urlString: home,
                    pinnedURLString: home,
                    placement: .spacePinned,
                    pinnedFolderID: copyID,
                    lastActivityAt: dateProvider(),
                ))
                order.append(.tab(tabID))
            case .folder(let id):
                guard let nested = pinnedTabFolders.first(where: { $0.id == id }), let nestedID = copyFolder(nested)
                else { continue }
                movePinnedTabFolder(withID: nestedID, toRootSectionIndex: order.count, targetParentFolderID: copyID)
                order.append(.folder(nestedID))
            }
        }
        var tree = BrowserSidebarTabTree(snapshot: sidebarPlanningSnapshot())
        tree.children[.pinned(source.spaceID, folderID: copyID)] = order
        applyPinnedTree(tree)
        return copyID
    }

    /// Shows the live page another window of this profile has for the tab, with its
    /// scroll position, form input and playing media. Nil when no window can give it.
    private func adoptPageFromAnotherWindow(syncID: String, makeActive: Bool) -> (
        id: String,
        handoff: BrowserTabPageHandoff,
    )? {
        guard let handoff = windowGroup?.takePage(syncID: syncID, for: self),
              let id = tabDriver.adoptPage(handoff, makeActive: makeActive)
        else { return nil }
        engineProfilePathsByID.updateValue(handoff.profileCachePath, forKey: id)
        return (id, handoff)
    }

    /// An adopted page is ready at once, at the address it shows.
    private func applyAdoptedPage(_ handoff: BrowserTabPageHandoff, toTabAt index: Int) {
        tabs[index].creationState = .ready
        tabs[index].canGoBack = handoff.canGoBack
        tabs[index].canGoForward = handoff.canGoForward
        tabs[index].isLoading = handoff.isLoading
    }

    private func hasNoPage(_ id: String) -> Bool {
        closedPinnedTabIDs.contains(id) || closedAppTabIDs.contains(id)
    }

    private func isPageInAnotherWindow(_ id: String) -> Bool {
        guard let syncID = tabs.first(where: { $0.id == id })?.syncID else { return false }
        return windowGroup?.hasPageElsewhere(syncID: syncID, than: self) ?? false
    }

    private func markWithoutPage(_ id: String, placement: BrowserTabPlacement) {
        if placement == .app {
            closedAppTabIDs.insert(id)
        } else {
            closedPinnedTabIDs.insert(id)
            lastPageRestoreTabIDs.insert(id)
        }
    }

    private func reidentifiedTab(from tab: Tab, id: String, lastActivityAt: Date? = nil) -> Tab {
        Tab(
            id: id, syncID: tab.syncID, spaceID: tab.spaceID, title: tab.title,
            userTitleOverride: tab.userTitleOverride, urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
            faviconURLString: tab.faviconURLString, placement: tab.placement, pinnedFolderID: tab.pinnedFolderID,
            pinnedSiblingRank: tab.pinnedSiblingRank, lastActivityAt: lastActivityAt ?? tab.lastActivityAt,
        )
    }

    private func appendTabWithoutPage(_ snapshot: BrowserTabSessionSnapshotTab, syncID: String) {
        let id = UUID().uuidString
        var tab = Tab(
            id: id, syncID: syncID, spaceID: Self.defaultSpaceID, title: snapshot.pageTitle ?? "",
            urlString: snapshot.urlString, lastActivityAt: lastActivityDate(from: snapshot) ?? dateProvider(),
        )
        applyRemoteTabMetadata(snapshot, to: &tab)
        tabIconsBySyncID[syncID] = snapshot.systemImageName
        tabs.append(tab)
        markWithoutPage(id, placement: snapshot.placement)
    }

    /// Panes of a split are on screen together, so the others open with the one chosen.
    private func loadSplitSiblings(ofTabWithID id: String) {
        guard windowGroup != nil else { return }
        for sibling in splitPaneTabIDs(forTabID: id) where sibling != id && hasNoPage(sibling) {
            loadUnloadedTabInPlace(id: sibling, persists: false)
        }
    }

    /// Reopens pages whose Space now uses another profile, since a page cannot change
    /// the place it keeps its data. Tabs without a page pick it up when they next load.
    private func reopenTabsInTheirProfiles() {
        guard canCreateTab else { return }
        for tab in tabs where !closedAppTabIDs.contains(tab.id) && !closedPinnedTabIDs.contains(tab.id)
            && !closingTabIDs.contains(tab.id)
        {
            let path = profileCachePath(forSpaceID: tab.placement == .app ? nil : tab.spaceID)
            guard (engineProfilePathsByID[tab.id] ?? nil) != path else { continue }
            loadUnloadedTabInPlace(id: tab.id, persists: false)
            engineProfilePathsByID[tab.id] = nil
            tabDriver.closeTab(withID: tab.id, forceClose: true)
        }
    }

    private func profileCachePath(forSpaceID spaceID: String?) -> String? {
        spaceID.flatMap { spaceProfilesByID[$0] }.flatMap { profileDirectories?.cachePath($0) }
    }

    /// Opens a page with the data of its Space's profile. Favorites belong to every
    /// Space, so they pass no Space and stay in the window's own profile. Pages the
    /// engine opens by itself, like links asking for a new tab, use the selected Space's.
    private func createEngineTab(withURLString urlString: String, makeActive: Bool, spaceID: String?) -> String {
        let path = profileCachePath(forSpaceID: spaceID)
        tabDriver.profileCachePathForNewTabs = path
        defer { tabDriver.profileCachePathForNewTabs = profileCachePath(forSpaceID: selectedSpaceID) }
        let id = tabDriver.createTab(withURLString: urlString, makeActive: makeActive)
        engineProfilePathsByID.updateValue(path, forKey: id)
        return id
    }

    /// Chromium writes the pasteboard only for a selection that differs from
    /// the find text, so nothing happens without one, as in Chrome.
    private func awaitSelectionForFind(changedFrom before: Int, tabID: String, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.findPasteboardDelay) { [weak self] in
            guard let self, selectedTabID == tabID, canPresentFindInPage else { return }
            guard findPasteboardChangeCount() != before else {
                if attempts > 1 {
                    awaitSelectionForFind(changedFrom: before, tabID: tabID, attempts: attempts - 1)
                }
                return
            }
            guard let text = findPasteboardText(), !text.isEmpty else { return }
            findQuery = text
            _ = presentFindInPage()
        }
    }

    private func updatePictureInPicture(leaving oldID: String?, entering newID: String?) {
        guard oldID != newID else { return }
        if let newID, pictureInPictureTabIDs.remove(newID) != nil {
            tabDriver.setPictureInPicture(false, forTabWithID: newID)
        }
        // Only a tab playing a video asks its page: the check runs script in the page
        // through the engine's debugging channel on every tab switch otherwise.
        guard userPreferencesStore.pictureInPictureEnabled, let oldID,
              tabMediaStates[oldID].map({ $0.isPlaying && $0.video }) == true,
              tabs.contains(where: { $0.id == oldID }), !closingTabIDs.contains(oldID),
              !closedAppTabIDs.contains(oldID), !closedPinnedTabIDs.contains(oldID),
              !(newID.map { splitPaneTabIDs(forTabID: $0).contains(oldID) } ?? false)
        else { return }
        // Forget tabs that have closed since.
        pictureInPictureTabIDs.formIntersection(tabs.map(\.id))
        pictureInPictureTabIDs.insert(oldID)
        tabDriver.setPictureInPicture(true, forTabWithID: oldID)
        // A page that refuses, or has no video, keeps its mini player.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, tabMediaStates[oldID]?.inPictureInPicture != true else { return }
            pictureInPictureTabIDs.remove(oldID)
            objectWillChange.send()
        }
    }

    private func localAutomaticArchivalOwnershipAllowsClose() -> Bool {
        // A paused, signed-out or offline owner still requires conditional expiry.
        guard let ownership = sessionSnapshotStore as? any BrowserSyncOwnershipReading else { return true }
        do {
            guard try ownership.syncOwner() == nil else {
                syncCoordinator?.requestExpirySweep()
                return false
            }
            return true
        } catch {
            Self.automaticArchivalLogger.error(
                "Skipping automatic archival because sync ownership could not be read: \(error.localizedDescription, privacy: .public)",
            )
            return false
        }
    }

    private func isLocalAutomaticArchiveEligible(_ tab: Tab) -> Bool {
        let now = dateProvider().timeIntervalSince1970
        let activity = tab.lastActivityAt.timeIntervalSince1970
        return now.isFinite && activity.isFinite && tab.spaceID == selectedSpaceID &&
            tab.placement == .temporary && tab.id != selectedTabID &&
            !(selectedTabID.map { splitPaneTabIDs(forTabID: $0).contains(tab.id) } ?? false) &&
            activity <= now - temporaryTabLifetime.timeInterval
    }

    private func continueLocalAutomaticArchiveSweep() {
        guard !isProcessingLocalAutomaticArchiveCandidates else { return }
        isProcessingLocalAutomaticArchiveCandidates = true
        defer { isProcessingLocalAutomaticArchiveCandidates = false }
        while !localAutomaticArchiveCandidates.isEmpty {
            guard canAdmitLocalAutomaticArchive, localAutomaticArchivalOwnershipAllowsClose() else {
                localAutomaticArchiveCandidates.removeAll()
                return
            }
            let candidate = localAutomaticArchiveCandidates.removeFirst()
            guard let tab = tabs.first(where: { $0.id == candidate.id && $0.syncID == candidate.syncID }),
                  tab.spaceID == candidate.spaceID, tab.lastActivityAt == candidate.lastActivityAt,
                  isLocalAutomaticArchiveEligible(tab) else { continue }
            _ = requestConfirmedTabClose(
                id: tab.id, registersUndo: false, actionName: BrowserStrings.tabArchiveAction,
                createsArchive: true, preservesPersistentTab: true, localAutomaticCandidate: candidate,
            )
            // Inline engine-less outcomes continue this loop; a deferred result
            // resumes it after finishing its own transaction. Never stack sheets.
            if pendingTabCloseRequests[tab.id] != nil {
                return
            }
        }
    }

    @discardableResult private func requestConfirmedTabClose(
        id: String, registersUndo: Bool, actionName: String, createsArchive: Bool,
        preservesPersistentTab: Bool, unloadsPersistentTab: Bool = false,
        historyKind: TabHistoryKind = .archive,
        localAutomaticCandidate: LocalAutomaticArchiveCandidate? = nil,
        completion: ((HistoryCloseResult) -> Void)? = nil,
    ) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }), !closingTabIDs.contains(id) else { return false }
        if closedAppTabIDs.contains(id) || closedPinnedTabIDs.contains(id) {
            // The logical persistent tab outlives its unloaded native record.
            // Logical removal and Undo Create need no missing-engine request.
            if preservesPersistentTab, tab.placement != .temporary {
                completion?(.removed)
                return true
            }
            return finishTabClose(
                id: id, forceClose: false, requestsEngineClose: false,
                registersUndo: registersUndo, undoActionName: actionName,
                createsArchive: createsArchive, historyKind: historyKind, completion: completion,
            )
        }
        let requestID = UUID().uuidString
        pendingTabCloseRequests[id] = PendingTabCloseRequest(
            requestID: requestID, syncID: tab.syncID, registersUndo: registersUndo,
            undoActionName: actionName, createsArchive: createsArchive,
            preservesPersistentTab: preservesPersistentTab, unloadsPersistentTab: unloadsPersistentTab,
            historyKind: historyKind,
            localAutomaticCandidate: localAutomaticCandidate,
            completion: completion,
        )
        closingTabIDs.insert(id)
        if tab.placement == .temporary, !unloadsPersistentTab, localAutomaticCandidate == nil {
            tabsLeavingSidebar.insert(id)
            tabRowsChanged()
        }
        guard tabDriver.requestCloseTab(withID: id, requestID: requestID) else {
            if pendingTabCloseRequests[id]?.requestID == requestID {
                pendingTabCloseRequests.removeValue(forKey: id)
                closingTabIDs.remove(id)
            }
            tabsLeavingSidebar.remove(id)
            return false
        }
        return true
    }

    @discardableResult private func finishTabClose(
        id: String, forceClose: Bool, requestsEngineClose: Bool,
        registersUndo: Bool, undoActionName: String, createsArchive: Bool = false,
        historyKind: TabHistoryKind = .archive,
        completion: ((HistoryCloseResult) -> Void)? = nil,
    ) -> Bool {
        let undoBatch = tabCloseUndoBatches.removeValue(forKey: id)
        guard let closingIndex = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let closingTab = tabs[closingIndex]
        tabsLeavingSidebar.remove(id)
        let undoSnapshot = tabUndoSnapshot(forClosingTabAt: closingIndex)
        let precloseSnapshot: BrowserTabSessionSnapshot? = createsArchive && canBrowseArchive && closingTab
            .placement == .temporary
            ? (isApplyingRemoteSync ? snapshotPreservingPendingRemoteCreations() : currentSessionSnapshot())
            : nil
        let archivedTab = precloseSnapshot?.tabs.first { $0.id == closingTab.syncID }
        let archiveEntry = archivedTab.map {
            BrowserTabArchiveEntry(
                id: UUID().uuidString, tab: $0, archivedAt: dateProvider().timeIntervalSince1970,
                title: closingTab.title,
            )
        }
        let closingTabWasSelected = selectedTabID == id
        closingTabIDs.insert(id)
        BrowserTelemetry.captureUsage(.tabClosed, properties: telemetryProperties(for: closingTab))

        let wasCompletingTabClose = isCompletingTabClose
        isCompletingTabClose = true
        tabs.removeAll { $0.id == id }
        // A logical tab can close before its allocation placeholder arrives.
        // Retain the retired identity so repeated late callbacks cannot recreate it.
        retireTabCreationCallbacks(id: id)
        closedAppTabIDs.remove(id)
        closedPinnedTabIDs.remove(id)
        removeTabFromSwitcherTracking(id)
        tabCreationUndoReferences.removeValue(forKey: id)?.currentTabID = nil
        clearSelectedTab(id, forSpaceID: closingTab.spaceID)

        if closingTabWasSelected {
            let fallbackTabID = fallbackTabID(afterClosingDormantTab: closingTab, excluding: [id])
            let fallbackUsesWindowedBrowser = fallbackTabID.map { tabUsesWindowedBrowser(id: $0) } ?? false
            if fallbackUsesWindowedBrowser {
                dismissFindBar()
            }
            selectedTabID = fallbackTabID
            findResultMatchCount = nil
            if let fallbackTabID {
                tabDriver.selectTab(withID: fallbackTabID)
                setSelectedTabID(fallbackTabID, forSpaceID: closingTab.spaceID)
                recordSelectedTab(fallbackTabID)
                if !fallbackUsesWindowedBrowser {
                    runFind(forward: true, findNext: false)
                }
            } else {
                tabDriver.deselectActiveTab()
            }
        } else if selectedTabID == id {
            selectedTabID = nil
        }

        if requestsEngineClose {
            tabDriver.closeTab(withID: id, forceClose: forceClose)
        } else {
            closingTabIDs.remove(id)
        }
        updateWindowTitle()
        // Reserve normal history in the order of the user's logical actions.
        // Failed persistence gates execution, not registration: a later New Tab
        // must stay above this Close even if its write also retries this batch.
        if registersUndo, let undoSnapshot {
            registerTabCloseUndo(
                undoSnapshot, archiveID: archiveEntry?.id, kind: historyKind, actionName: undoActionName,
                batch: undoBatch,
            )
        }
        let didCommit: () -> Void = { [weak self] in
            guard let self, let undoSnapshot else { return }
            if archiveEntry != nil {
                archiveRevision &+= 1
            }
            completion?(.closed(undoSnapshot, archiveID: archiveEntry?.id))
        }
        if isContextReady, isPersistenceEnabled, !isRestoringSession, !isReconcilingRemoteProjection {
            let snapshot: BrowserTabSessionSnapshot
            if isApplyingRemoteSync {
                snapshot = snapshotPreservingPendingRemoteCreations()
                remoteProjectionSnapshot = snapshot
                hasLocalChangesDuringRemoteProjection = true
            } else {
                snapshot = currentSessionSnapshot()
            }
            _ = persistSessionWrite(
                .init(
                    snapshot: snapshot,
                    origin: .local(syncMove: nil),
                    archiveAction: archiveEntry.map { .insert($0) },
                    // The live URL can differ from SQLite's remote projection
                    // while other engines are pending. Normalize inside this
                    // Archive action, after its receipt check, so retry cannot
                    // replay a stale prefix after the deletion already committed.
                    archiveProjectionSnapshot: isApplyingRemoteSync ? precloseSnapshot : nil,
                ),
                schedulesPush: !isApplyingRemoteSync,
                onCommit: didCommit,
            )
        } else {
            didCommit()
        }
        isCompletingTabClose = wasCompletingTabClose
        return true
    }

    private func indexedFolderMovePlan(
        folderID: String, index: Int, targetSpaceID: String?, parentFolderID: String?,
    ) -> BrowserSidebarMovePlan? {
        let tree = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
        guard let folder = tree.folders[folderID],
              targetSpaceID != nil || parentFolderID != nil || folder.spaceID == selectedSpaceID else { return nil }
        let spaceID = parentFolderID.flatMap { tree.folders[$0]?.spaceID }
            ?? targetSpaceID ?? selectedSpaceID ?? folder.spaceID
        let container = BrowserSidebarDropContainer.pinned(spaceID, folderID: parentFolderID)
        let siblings = tree.items(in: container).filter { $0 != .folder(folderID) }
        let index = min(max(index, 0), siblings.count)
        return sidebarMovePlan(
            payload: .init(
                primary: .folder(folderID),
                tabIDs: Set(tree.tabIDs(in: .pinned(folder.spaceID, folderID: folderID))),
            ),
            destination: .init(container: container, beforeItem: index < siblings.count ? siblings[index] : nil),
        )
    }

    private func indexedTabMovePlan(
        tabIDs: Set<String>, placement: BrowserTabPlacement, sectionIndex: Int,
        targetSpaceID: String?, targetPinnedFolderID: String?,
    ) -> BrowserSidebarMovePlan? {
        guard let primary = tabs.first(where: { tabIDs.contains($0.id) })?.id else { return nil }
        let candidate = tabIDs.count == 1
            ? reorderedTabs(
                movingTabID: primary,
                toPlacement: placement,
                requestedSectionIndex: sectionIndex,
                targetSpaceID: targetSpaceID,
                targetPinnedFolderID: targetPinnedFolderID,
            )
            : reorderedTabs(
                movingTabIDs: tabIDs,
                toPlacement: placement,
                requestedSectionIndex: sectionIndex,
                targetSpaceID: targetSpaceID,
                targetPinnedFolderID: targetPinnedFolderID,
            )
        guard let candidate, candidate != tabs,
              let moved = candidate.first(where: { $0.id == primary }) else { return nil }
        // Index APIs retain their historical flattened-tab addressing. Resolve it
        // once to a typed sibling anchor; the actual mutation uses the shared tree.
        let unrankedTabs = candidate.map { tab in var tab = tab
            tab.pinnedSiblingRank = nil
            return tab
        }
        let unrankedFolders = pinnedTabFolders.map { folder in
            var folder = folder
            folder.pinnedSiblingRank = nil
            return folder
        }
        let inferred = BrowserSidebarTabTree(snapshot: sidebarSnapshot.replacingTabs(
            unrankedTabs,
            pinnedTabFolders: unrankedFolders,
        ))
        let container: BrowserSidebarDropContainer =
            switch placement {
            case .app: .app
            case .temporary: .temporary(moved.spaceID)
            case .spacePinned: .pinned(moved.spaceID, folderID: moved.pinnedFolderID)
            }
        let siblings = inferred.items(in: container)
        let moving = Set(tabIDs.map(BrowserSidebarItemID.tab))
        guard let last = siblings.lastIndex(where: { moving.contains($0) }) else { return nil }
        let before = siblings.dropFirst(last + 1).first { !moving.contains($0) }
        return sidebarMovePlan(
            payload: .init(primary: .tab(primary), tabIDs: tabIDs),
            destination: .init(container: container, beforeItem: before),
        )
    }

    private func applyPinnedTree(_ value: BrowserSidebarTabTree) {
        var tree = value
        var logicalTabs = sidebarPlanningSnapshot().allTabs
        tree.assignPinnedRanks(to: &logicalTabs)
        pinnedTabFolders = pinnedTabFolders.compactMap { tree.folders[$0.id] }
        let byID = Dictionary(uniqueKeysWithValues: logicalTabs.map { ($0.id, $0) })
        publishPlannedTabs(tree.orderedTabIDs().compactMap { byID[$0] })
    }

    /// Pending remote identities occupy real sibling slots before their logical
    /// engine callback. They participate in planning without appearing as tabs.
    private func sidebarPlanningSnapshot() -> BrowserSidebarSnapshot {
        guard !pendingRemoteTabCreations.isEmpty else { return sidebarSnapshot }
        let hydrated = Dictionary(uniqueKeysWithValues: tabs.map { ($0.syncID, $0) })
        let pending = Dictionary(uniqueKeysWithValues: pendingRemoteTabCreations.compactMap { engineID, binding in
            binding.snapshot.id.map { ($0, engineID) }
        })
        let logicalTabs = snapshotPreservingPendingRemoteCreations().tabs.compactMap { snapshot -> Tab? in
            guard let syncID = snapshot.id else { return nil }
            if let tab = hydrated[syncID] {
                return tab
            }
            guard let engineID = pending[syncID] else { return nil }
            return Tab(
                id: engineID, syncID: syncID, spaceID: snapshot.spaceID ?? Self.defaultSpaceID,
                title: "", userTitleOverride: snapshot.userTitleOverride, urlString: snapshot.urlString,
                pinnedURLString: snapshot.pinnedURLString, placement: snapshot.placement,
                pinnedFolderID: snapshot.pinnedFolderID, pinnedSiblingRank: snapshot.pinnedSiblingRank,
                lastActivityAt: lastActivityDate(from: snapshot) ?? dateProvider(),
            )
        }
        return sidebarSnapshot.replacingTabs(logicalTabs)
    }

    private func publishPlannedTabs(_ logicalTabs: [Tab]) {
        let pendingIDs = Set(pendingRemoteTabCreations.keys)
        tabs = logicalTabs.filter { !pendingIDs.contains($0.id) }
        let snapshots = logicalTabs.map { tab in
            if let original = pendingRemoteTabCreations[tab.id]?.snapshot {
                return BrowserTabSessionSnapshotTab(
                    id: original.id, urlString: original.urlString, pinnedURLString: original.pinnedURLString,
                    userTitleOverride: original.userTitleOverride, placement: tab.placement, spaceID: tab.spaceID,
                    pinnedFolderID: tab.pinnedFolderID, lastActivityTimestamp: original.lastActivityTimestamp,
                    pinnedSiblingRank: tab.pinnedSiblingRank, systemImageName: original.systemImageName,
                )
            }
            return BrowserTabSessionSnapshotTab(
                id: tab.syncID, urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
                userTitleOverride: tab.userTitleOverride, placement: tab.placement, spaceID: tab.spaceID,
                pinnedFolderID: tab.pinnedFolderID, lastActivityTimestamp: tab.lastActivityAt.timeIntervalSince1970,
                pinnedSiblingRank: tab.pinnedSiblingRank, pageTitle: tab.title.isEmpty ? nil : tab.title,
                systemImageName: tabIconsBySyncID[tab.syncID],
            )
        }
        for (tab, snapshot) in zip(logicalTabs, snapshots) {
            guard let binding = pendingRemoteTabCreations[tab.id] else { continue }
            pendingRemoteTabCreations[tab.id] = RemoteTabCreation(snapshot: snapshot, generation: binding.generation)
        }
        if let projection = remoteProjectionSnapshot {
            remoteProjectionSnapshot = BrowserTabSessionSnapshot(
                spaces: projection.spaces, pinnedTabFolders: projection.pinnedTabFolders, tabs: snapshots,
            )
        }
    }

    private func applyRemoteTabMetadata(_ snapshot: BrowserTabSessionSnapshotTab, to tab: inout Tab) {
        tab.spaceID = snapshot.spaceID.flatMap { id in spaces.contains { $0.id == id } ? id : nil }
            ?? spaces.first?.id ?? Self.defaultSpaceID
        tab.placement = snapshot.placement
        tab.userTitleOverride = sanitizedUserTitleOverride(from: snapshot.userTitleOverride)
        tab.pinnedURLString = snapshot.placement.keepsPinnedURL
            ? normalizedPinnedURLString(from: snapshot.pinnedURLString ?? snapshot.urlString)
            : nil
        tab.pinnedFolderID = snapshot.placement == .spacePinned ? snapshot.pinnedFolderID : nil
        tab.pinnedSiblingRank = snapshot.placement == .spacePinned ? snapshot.pinnedSiblingRank : nil
        if let activity = lastActivityDate(from: snapshot), activity.timeIntervalSince1970.isFinite {
            // The shared projection already reconciled canonical and pending
            // activity. Keep it when publishing the live-engine projection.
            tab.lastActivityAt = activity
        }
        if !isApplyingPeerSnapshot, tab.creationState != .ready, !tab.hasPendingLocalNavigation,
           tab.urlString != snapshot.urlString
        {
            tabDriver.navigateTab(withID: tab.id, toURLString: resolvedBrowserURLString(snapshot.urlString))
            tab.urlString = snapshot.urlString
            tab.title = ""
            tab.faviconURLString = nil
        }
        // Attached engines keep their live URL/history. Before attachment a
        // remote URL initializes the page unless the user already chose a target.
    }

    private func finishRemoteSyncProjectionIfReady() {
        guard isApplyingRemoteSync, !isReconcilingRemoteProjection,
              let snapshot = remoteProjectionSnapshot
        else { return }

        var remoteOrder = [String: Int]()
        for (index, tab) in snapshot.tabs.enumerated() {
            if let id = tab.id, remoteOrder[id] == nil {
                remoteOrder[id] = index
            }
        }
        tabs = tabs.enumerated()
            .sorted { lhs, rhs in
                let left = remoteOrder[lhs.element.syncID] ?? snapshot.tabs.count + lhs.offset
                let right = remoteOrder[rhs.element.syncID] ?? snapshot.tabs.count + rhs.offset
                return left < right
            }
            .map(\.element)
        guard pendingRemoteTabCreations.isEmpty else { return }
        removeInvalidPinnedTabFolderAssignments()

        for index in spaces.indices {
            let visibleTabs = sidebarTabs(forSpaceID: spaces[index].id)
            if let selectedID = spaces[index].selectedTabID, visibleTabs.contains(where: { $0.id == selectedID }) {
                continue
            }
            let remoteIndex = snapshot.spaces?.first { $0.id == spaces[index].id }?.selectedTabIndex
            spaces[index].selectedTabID = remoteIndex.flatMap {
                visibleTabs.indices.contains($0) ? visibleTabs[$0].id : nil
            } ?? visibleTabs.first { !hasNoPage($0.id) }?.id
        }
        if let selectedTab = tabs.first(where: { $0.id == selectedTabID }) {
            selectedSpaceID = selectedTab.spaceID
            setSelectedTabID(selectedTab.id, forSpaceID: selectedTab.spaceID)
        } else {
            selectActiveTabForSelectedSpace()
        }
        updateWindowTitle()
        if isApplyingPeerSnapshot {
            needsRemoteFallbackPublication = false
            remoteProjectionSnapshot = nil
            isApplyingRemoteSync = false
            hasLocalChangesDuringRemoteProjection = false
            reopenTabsInTheirProfiles()
            return
        }
        let origin: BrowserSessionWrite.Origin = needsRemoteFallbackPublication
            ? .local(syncMove: nil)
            : .remoteProjection
        let schedulesPush = hasLocalChangesDuringRemoteProjection || needsRemoteFallbackPublication
        needsRemoteFallbackPublication = false
        remoteProjectionSnapshot = nil
        isApplyingRemoteSync = false
        hasLocalChangesDuringRemoteProjection = false
        _ = persistSessionWrite(.init(snapshot: currentSessionSnapshot(), origin: origin), schedulesPush: schedulesPush)
    }

    @discardableResult private func drainDeferredRemoteSyncSnapshot() -> Bool {
        guard !hasUncommittedSessionWrites, !hasDiscardedSessionForClosure else {
            deferredRemoteSyncSnapshot = nil
            return false
        }
        guard isContextReady, !isRestoringSession, let snapshot = deferredRemoteSyncSnapshot else { return false }
        deferredRemoteSyncSnapshot = nil
        applyRemoteSyncSnapshot(snapshot)
        return true
    }

    private func handleRemoteCreatedTab(id: String, title: String, urlString: String) -> Bool {
        if discardedRemoteTabCreationIDs.remove(id) != nil {
            tabDriver.closeTab(withID: id, forceClose: true)
            return true
        }
        guard let binding = pendingRemoteTabCreations.removeValue(forKey: id) else { return false }
        guard binding.generation == remoteProjectionGeneration, let syncID = binding.snapshot.id else {
            tabDriver.closeTab(withID: id, forceClose: true)
            return true
        }
        var tab = Tab(
            id: id, syncID: syncID, spaceID: Self.defaultSpaceID,
            title: urlString == binding.snapshot.urlString ? title : "",
            urlString: binding.snapshot.urlString,
            lastActivityAt: lastActivityDate(from: binding.snapshot) ?? dateProvider(),
        )
        applyRemoteTabMetadata(binding.snapshot, to: &tab)
        if let icon = binding.snapshot.systemImageName {
            // A deferred launch projection creates every tab this way.
            tabIconsBySyncID[syncID] = icon
        }
        tabs.append(tab)
        finishRemoteSyncProjectionIfReady()
        return true
    }

    private func telemetryProperties(for tab: Tab) -> [String: String] {
        var properties = telemetryProperties
        properties["placement"] = tab.placement.rawValue
        properties["is_selected"] = selectedTabID == tab.id ? "true" : "false"
        properties["is_internal_page"] = Self.internalPage(for: tab.urlString) == nil ? "false" : "true"
        if let scheme = URL(string: tab.urlString)?.scheme {
            properties["scheme"] = scheme.lowercased()
        }
        return properties
    }

    private func handleExtensionSidePanelClosed(panelID: String) {
        guard extensionSidePanel?.panelID == panelID else {
            return
        }

        extensionSidePanel = nil
    }

    private func closeExtensionSidePanelIfNeeded() {
        guard let sidePanel = extensionSidePanel else {
            return
        }

        guard
            let browserExtension = browserExtensions.first(where: { $0.id == sidePanel.extensionID }),
            browserExtension.isEnabled,
            browserExtension.sidePanelURLString == sidePanel.urlString
        else {
            closeExtensionSidePanel()
            return
        }

        extensionSidePanel = BrowserExtensionSidePanel(
            panelID: sidePanel.panelID,
            extensionID: browserExtension.id,
            title: browserExtension.name,
            urlString: sidePanel.urlString,
            iconData: browserExtension.iconData,
        )
    }

    private func removeUnavailablePinnedExtensionsIfNeeded() {
        guard !browserExtensions.isEmpty else {
            return
        }

        let availableExtensionIDs = Set(browserExtensions.map(\.id))
        let availablePinnedExtensionIDs = pinnedExtensionIDs.filter(availableExtensionIDs.contains)
        guard availablePinnedExtensionIDs != pinnedExtensionIDs else {
            return
        }

        setPinnedExtensionIDs(availablePinnedExtensionIDs)
    }

    private func setPinnedExtensionIDs(_ ids: [String]) {
        var seen = Set<String>()
        let normalizedIDs = ids.filter { id in
            guard !id.isEmpty, !seen.contains(id) else {
                return false
            }

            seen.insert(id)
            return true
        }

        pinnedExtensionIDs = normalizedIDs
        userPreferencesStore.pinnedExtensionIDs = normalizedIDs
    }

    private func ensureInitialTab() {
        guard canCreateTab, !hasCreatedInitialTab else {
            return
        }

        ensureDefaultSpace()
        hasCreatedInitialTab = true
        // Blank and incognito windows start with no page and ask where to go.
        guard (windowMode != .blank && windowMode != .incognito) || firstTabURLString != nil || !initialTabPages.isEmpty
        else { return }
        let pages = initialTabPages
        initialTabPages.removeAll()
        let page = { (index: Int) in index < pages.count ? pages[index] : nil }
        if page(0).flatMap({ adoptPageAsNewTab($0, makeActive: true) }) == nil {
            createTab(withURLString: firstTabURLString ?? newTabURLString, registersUndo: false)
        }
        let first = selectedTabID
        for (offset, urlString) in additionalTabURLStrings.enumerated()
            where page(offset + 1).flatMap({ adoptPageAsNewTab($0, makeActive: false) }) == nil
        {
            createTab(withURLString: urlString, registersUndo: false, makeActive: false)
        }
        additionalTabURLStrings.removeAll()
        if let first, selectedTabID != first {
            selectTab(id: first)
        }
    }

    private func restoreSessionIfAvailable() -> Bool {
        // An additional window must see the session whatever the launch setting says:
        // saving an empty list would close the other window's tabs.
        guard windowMode.persistsSession, userPreferencesStore.restoreWindowsOnLaunch || isAdditionalWindow,
              let snapshot = sessionSnapshotStore.loadSnapshot()
        else {
            return false
        }

        let restoredSpaces = restoredSpaces(from: snapshot)
        guard !restoredSpaces.isEmpty || !snapshot.tabs.isEmpty else {
            return false
        }

        isRestoringSession = true
        hasCreatedInitialTab = true
        spaces = restoredSpaces.isEmpty ? [makeDefaultSpace()] : restoredSpaces
        spaceProfilesByID = Dictionary(
            (snapshot.spaces ?? []).compactMap { space in space.profileDirectory.map { (space.id, $0) } },
            uniquingKeysWith: { first, _ in first },
        )
        spaceThemesByID = Dictionary(
            (snapshot.spaces ?? []).compactMap { space in
                space.colorName.flatMap(BrowserSpaceTheme.init(stored:)).map { (space.id, $0) }
            },
            uniquingKeysWith: { first, _ in first },
        )
        pinnedTabFolders = restoredPinnedTabFolders(from: snapshot)
        splitGroups = restoredSplitGroups(from: snapshot)
        let selectedSpaceIndex = sessionPreferencesStore.loadSelectedSpaceIndex(
            spaceCount: spaces.count,
        ) ?? 0
        selectedSpaceID = firstSpaceID.flatMap { id in spaces.first { $0.id == id }?.id }
            ?? (spaces.indices.contains(selectedSpaceIndex) ? spaces[selectedSpaceIndex].id : spaces.first?.id)
        pendingRestoredSelectedTabIndex = sessionPreferencesStore.loadSelectedTabIndex(
            tabCount: snapshot.tabs.count,
        )
        pendingRestoredSpaces = snapshot.spaces ?? []
        let splitMemberSyncIDs = Set((snapshot.splitGroups ?? []).flatMap(\.tabIDs))
        for (index, tabSnapshot) in snapshot.tabs.enumerated() {
            let placement = tabSnapshot.placement
            // Pinned tabs come back unloaded, with their last title,
            // and load when first shown. The shown tab and split panes load now;
            // Favorites, a handful of app tiles that often notify, stay loaded.
            let restoresUnloaded = isAdditionalWindow || (
                placement == .spacePinned && index != pendingRestoredSelectedTabIndex
                    && !(tabSnapshot.id.map(splitMemberSyncIDs.contains) ?? false)
            )
            let engineID = restoresUnloaded
                ? UUID().uuidString
                : createEngineTab(
                    withURLString: tabSnapshot.urlString,
                    makeActive: index == pendingRestoredSelectedTabIndex,
                    spaceID: placement == .app ? nil : tabSnapshot.spaceID,
                )
            restoredTabCreationIDs.insert(engineID)
            if restoresUnloaded {
                markWithoutPage(engineID, placement: placement)
            }
            if let syncID = tabSnapshot.id, let icon = tabSnapshot.systemImageName {
                tabIconsBySyncID[syncID] = icon
            }
            tabs.append(Tab(
                id: engineID,
                syncID: tabSnapshot.id ?? tabSyncIDProvider(),
                spaceID: tabSnapshot.spaceID ?? selectedSpaceID ?? Self.defaultSpaceID,
                title: tabSnapshot.id.flatMap { windowGroup?.pageTitle(forSyncID: $0, than: self) }
                    ?? tabSnapshot.pageTitle ?? "",
                userTitleOverride: tabSnapshot.userTitleOverride,
                urlString: tabSnapshot.urlString,
                pinnedURLString: placement.keepsPinnedURL
                    ? normalizedPinnedURLString(from: tabSnapshot.pinnedURLString ?? tabSnapshot.urlString)
                    : nil,
                placement: placement,
                pinnedFolderID: tabSnapshot.pinnedFolderID,
                pinnedSiblingRank: tabSnapshot.pinnedSiblingRank,
                lastActivityAt: lastActivityDate(from: tabSnapshot) ?? dateProvider(),
            ))
        }
        // The driver returns the logical identity immediately. Its later created
        // callback is a placeholder notification, not CEF readiness. Restored
        // state must be complete before user actions or remote snapshots arrive.
        finishSessionRestoreIfNeeded()
        return true
    }

    private func restoreSidebarWidthIfNeeded() {
        guard isPersistenceEnabled, let storedSidebarWidth = sessionPreferencesStore.loadSidebarWidth(
            minimum: Self.minSidebarWidth,
            maximum: Self.maxSidebarWidth,
        ) else {
            return
        }

        sidebarWidth = storedSidebarWidth
    }

    private func finishSessionRestoreIfNeeded() {
        guard isRestoringSession else {
            return
        }

        removeInvalidPinnedTabFolderAssignments()
        restoreSelectedTabsForSpaces()
        selectActiveTabForSelectedSpace()

        pendingRestoredSelectedTabIndex = nil
        pendingRestoredSpaces.removeAll()
        isRestoringSession = false
        updateWindowTitle()

        guard !drainDeferredRemoteSyncSnapshot() else { return }
        persistCurrentSessionIfAllowed()
        archiveExpiredTemporaryTabs()
    }

    private func syncMoveIntent(for payload: BrowserSidebarDragPayload) -> BrowserSyncMoveIntent? {
        switch payload.primary {
        case .folder(let id): BrowserSyncMoveIntent(items: [.init(entityType: .folder, entityID: id)])
        case .tab: syncMoveIntent(forTabIDs: payload.tabIDs)
        }
    }

    private func syncMoveIntent(forTabIDs tabIDs: Set<String>) -> BrowserSyncMoveIntent? {
        let syncIDs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.syncID) })
        let orderedIDs = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
            .orderedTabIDs()
            .filter { tabIDs.contains($0) }
            .compactMap { syncIDs[$0] }
        return orderedIDs.isEmpty ? nil : BrowserSyncMoveIntent(tabIDs: orderedIDs)
    }

    private func persistCurrentSessionIfAllowed(syncMove: BrowserSyncMoveIntent? = nil) {
        pendingSelectionPersist?.invalidate()
        pendingSelectionPersist = nil
        guard isContextReady, isPersistenceEnabled, !isRestoringSession, !isReconcilingRemoteProjection,
              !isCompletingTabClose, !isApplyingPeerSnapshot
        else {
            return
        }

        let snapshot: BrowserTabSessionSnapshot
        if isApplyingRemoteSync {
            snapshot = snapshotPreservingPendingRemoteCreations()
            remoteProjectionSnapshot = snapshot
            hasLocalChangesDuringRemoteProjection = true
        } else {
            snapshot = currentSessionSnapshot()
        }
        _ = persistSessionWrite(
            .init(snapshot: snapshot, origin: .local(syncMove: syncMove)),
            schedulesPush: !isApplyingRemoteSync,
        )
    }

    @discardableResult private func persistSessionWrite(
        _ write: BrowserSessionWrite, schedulesPush: Bool,
        onCommit: (() -> Void)? = nil,
    ) -> Bool {
        isSessionClosurePrepared = false
        guard isPersistenceEnabled, !hasDiscardedSessionForClosure, !sessionWriteBuffer.isTerminal else { return false }
        if let onCommit {
            pendingSessionCompletions.append(.init(write: write, completion: onCommit))
        }
        if !sessionWriteBuffer.writes.isEmpty {
            guard sessionWriteBuffer.append(write) else {
                publishSessionPersistenceFailure()
                return false
            }
            return commitSessionWrites(sessionWriteBuffer.writes, schedulesPush: schedulesPush)
        }
        return commitSessionWrites([write], schedulesPush: schedulesPush)
    }

    @discardableResult private func commitSessionWrites(_ writes: [BrowserSessionWrite], schedulesPush: Bool) -> Bool {
        guard !writes.isEmpty, !sessionWriteBuffer.isTerminal, !hasDiscardedSessionForClosure else { return false }
        let wasBlocked = hasUncommittedSessionWrites
        do {
            try sessionSnapshotStore.writeSessionBatch(writes)
        } catch {
            if sessionWriteBuffer.writes.isEmpty {
                for write in writes where !sessionWriteBuffer.isTerminal {
                    sessionWriteBuffer.append(write)
                }
            }
            sessionWriteBuffer.recordFailure(error)
            publishSessionPersistenceFailure()
            return false
        }
        sessionWriteBuffer.clearAfterSuccess()
        showSessionPersistenceFailure(historyRestoreFailure)
        if wasBlocked, !hasUncommittedSessionWrites {
            deferredRemoteSyncSnapshot = nil
            syncCoordinator?.setLocalPersistenceBlocked(false)
            syncCoordinator?.schedulePull()
        }
        // Preferences remain a separate best-effort store. They are only written
        // after the snapshot/outbox commits; this does not make them atomic with it.
        sessionPreferencesStore.saveSelectedSpaceIndex(selectedSpaceIndex)
        let selectedSyncID = selectedTab?.syncID
        if let snapshot = writes.last?.snapshot {
            if !isApplyingPeerSnapshot {
                windowGroup?.sessionDidChange(snapshot, from: self)
            }
            sessionPreferencesStore.saveSelectedTabIndex(snapshot.tabs.firstIndex { $0.id == selectedSyncID })
            if schedulesPush, !isApplyingRemoteSync {
                syncCoordinator?.schedulePush(snapshot: snapshot)
            }
        }
        let completed = pendingSessionCompletions.filter { writes.contains($0.write) }
        pendingSessionCompletions.removeAll { writes.contains($0.write) }
        for action in completed {
            action.completion()
        }
        return true
    }

    /// Every save sets this; an unchanged value publishes nothing, so a tab switch's
    /// save does not redraw the window.
    private func showSessionPersistenceFailure(_ failure: BrowserSessionPersistenceFailure?) {
        if sessionPersistenceFailure != failure {
            sessionPersistenceFailure = failure
        }
    }

    private func publishSessionPersistenceFailure() {
        showSessionPersistenceFailure(sessionWriteBuffer.failure ?? historyRestoreFailure)
        deferredRemoteSyncSnapshot = nil
        syncCoordinator?.setLocalPersistenceBlocked(true)
    }

    private func snapshotPreservingPendingRemoteCreations() -> BrowserTabSessionSnapshot {
        let current = currentSessionSnapshot()
        guard let remoteProjectionSnapshot else { return current }
        var mergedTabs = current.tabs
        let pendingByID = Dictionary(uniqueKeysWithValues: pendingRemoteTabCreations.values.compactMap { binding in
            binding.snapshot.id.map { ($0, binding.snapshot) }
        })
        // Place pending creations before their next surviving remote sibling.
        // Existing tabs keep the user's current relative order, including moves
        // and deletions performed while the engine creates remote tabs.
        for (index, tab) in remoteProjectionSnapshot.tabs.enumerated().reversed() {
            guard let id = tab.id, let pending = pendingByID[id] else { continue }
            let followingIDs = remoteProjectionSnapshot.tabs.dropFirst(index + 1).compactMap(\.id)
            let insertion = followingIDs.lazy
                .compactMap { nextID in
                    mergedTabs.firstIndex { $0.id == nextID }
                }
                .first ?? mergedTabs.count
            mergedTabs.insert(pending, at: insertion)
        }
        let spaceSnapshots = current.spaces?.map { space in
            let selectedID = spaces.first { $0.id == space.id }?.selectedTabID
            let selectedSyncID = tabs.first { $0.id == selectedID }?.syncID
            let inSpace = mergedTabs.filter { $0.spaceID == space.id }
            let visible = inSpace.filter { $0.placement == .spacePinned }
                + inSpace.filter { $0.placement == .temporary }
            return BrowserSpaceSessionSnapshot(
                id: space.id, title: space.title, systemImageName: space.systemImageName,
                isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                selectedTabIndex: visible.firstIndex { $0.id == selectedSyncID },
                colorName: space.colorName,
                profileDirectory: space.profileDirectory,
            )
        }
        return BrowserTabSessionSnapshot(
            spaces: spaceSnapshots,
            pinnedTabFolders: current.pinnedTabFolders,
            tabs: mergedTabs,
            splitGroups: current.splitGroups,
        )
    }

    private func currentSessionSnapshot() -> BrowserTabSessionSnapshot {
        if !isRestoringSession {
            pruneSplitGroupsIfNeeded()
        }
        var tree = BrowserSidebarTabTree(snapshot: sidebarSnapshot)
        var snapshotTabs = tabs
        // Pending remote tabs may not have a model row yet. Preserve known ranks
        // so a metadata save cannot compact their still-occupied sibling slots.
        tree.assignPinnedRanks(to: &snapshotTabs, preservingExistingRanks: true)
        return BrowserTabSessionSnapshot(
            spaces: spaces.map { space in
                BrowserSpaceSessionSnapshot(
                    id: space.id,
                    title: space.title,
                    systemImageName: space.systemImageName,
                    isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                    selectedTabIndex: selectedTabIndex(inSpace: space.id),
                    colorName: spaceThemesByID[space.id]?.stored,
                    profileDirectory: spaceProfilesByID[space.id],
                )
            },
            pinnedTabFolders: pinnedTabFolders.compactMap { tree.folders[$0.id] }.map { folder in
                BrowserPinnedTabFolderSessionSnapshot(
                    id: folder.id,
                    spaceID: folder.spaceID,
                    parentFolderID: folder.parentFolderID,
                    title: folder.title,
                    systemImageName: folder.systemImageName,
                    isExpanded: folder.isExpanded,
                    pinnedSiblingRank: folder.pinnedSiblingRank,
                )
            },
            tabs: snapshotTabs.map { tab in
                BrowserTabSessionSnapshotTab(
                    id: tab.syncID,
                    urlString: tab.urlString,
                    pinnedURLString: tab.pinnedURLString,
                    userTitleOverride: tab.userTitleOverride,
                    placement: tab.placement,
                    spaceID: tab.spaceID,
                    pinnedFolderID: tab.pinnedFolderID,
                    lastActivityTimestamp: tab.lastActivityAt.timeIntervalSince1970,
                    pinnedSiblingRank: tab.pinnedSiblingRank,
                    pageTitle: tab.title.isEmpty ? nil : tab.title,
                    systemImageName: tabIconsBySyncID[tab.syncID],
                )
            },
            splitGroups: splitGroupSessionSnapshots(),
        )
    }

    /// A new temporary tab of the selected Space; a background one keeps the
    /// selection.
    @discardableResult private func createTab(
        withURLString urlString: String,
        registersUndo: Bool = true,
        undoActionName: String = BrowserStrings.menuNewTab,
        makeActive: Bool = true,
        placesAtTop: Bool = false,
    ) -> String? {
        guard canCreateTab else {
            return nil
        }

        ensureDefaultSpace()
        guard let selectedSpaceID else {
            return nil
        }

        if makeActive {
            captureSelectedTabPreviewIfNeeded()
        }
        let resolvedURLString = resolvedBrowserURLString(urlString)
        let tabID = createEngineTab(
            withURLString: resolvedURLString, makeActive: makeActive, spaceID: selectedSpaceID,
        )
        let context = PendingCreatedTabContext(
            spaceID: selectedSpaceID,
            placement: .temporary,
            undoSnapshot: nil,
            placesAtTop: placesAtTop,
        )
        applyCreatedTabContext(context, toTabID: tabID)
        if registersUndo, canRegisterTabUndo {
            let creationUndoReference = TabCreationUndoReference(tabID: tabID)
            tabCreationUndoReferences[tabID] = creationUndoReference
            registerTabCreationUndo(creationUndoReference, actionName: undoActionName)
        }
        if makeActive {
            selectedTabID = tabID
            setSelectedTabID(tabID, forSpaceID: selectedSpaceID)
            findResultMatchCount = nil
        }
        // The returned ID already identifies a logical tab. Persist it before
        // another user action can target it, independently of the allocation callback.
        handleCreatedTab(id: tabID, title: "", urlString: resolvedURLString, isActive: makeActive)
        pendingHydratedTabCreationIDs.insert(tabID)
        return tabID
    }

    private func openResolvedSelectionInNewTab(_ resolvedURLString: String) {
        let pending = takePendingSplitAnchor()
        createTab(withURLString: resolvedURLString, placesAtTop: pending == nil)
        if let pending, let tabID = selectedTabID, tabID != pending.anchorID {
            openInSplitView(
                tabID: tabID,
                anchorTabID: pending.anchorID,
                insertion: pending.insertion,
                orientation: pending.orientation,
            )
        }
    }

    private func openCommandBarTabSelection(tabIDs: [String]) {
        let candidateTabs = tabIDs.compactMap { tabID in
            tabs.first { $0.id == tabID }
        }
        let tab = candidateTabs.first { candidate in
            candidate.placement == .spacePinned && candidate.pinnedFolderID != nil
        } ?? candidateTabs.first

        guard let tab else {
            return
        }

        if let pending = takePendingSplitAnchor(), openInSplitView(
            tabID: tab.id,
            anchorTabID: pending.anchorID,
            insertion: pending.insertion,
            orientation: pending.orientation,
        ) {
            return
        }
        selectTab(id: tab.id)
    }

    private func navigateSelectedTabOrOpenNewTab(toURLString urlString: String) {
        guard canCreateTab else {
            return
        }

        if selectedTabID == nil {
            createTab(withURLString: urlString, placesAtTop: true)
            return
        }

        navigateSelectedTab(toURLString: urlString)
    }

    @discardableResult private func navigateSelectedTab(toURLString urlString: String) -> Bool {
        guard canCreateTab, let index = selectedTabIndex else { return false }
        let resolvedURL = resolvedBrowserURLString(urlString)
        let id = tabs[index].id
        guard tabDriver.navigateTab(withID: id, toURLString: resolvedURL) else { return false }
        guard tabs[index].creationState != .ready || pendingTabCloseRequests[id]?.localAutomaticCandidate != nil
        else { return true }

        // Preserve the intent even if there is no engine yet, the process exits,
        // or creation is refused. Engine callbacks are not the durable owner.
        tabs[index].hasPendingLocalNavigation = true
        if tabs[index].urlString != resolvedURL {
            tabs[index].urlString = resolvedURL
            tabs[index].title = ""
            tabs[index].faviconURLString = nil
            tabs[index].lastActivityAt = advancedActivityDate(after: tabs[index].lastActivityAt)
            invalidateSelectedTabWebAppInstallMetadata()
            updateWindowTitle()
            persistCurrentSessionIfAllowed()
        }
        if tabs[index].creationState == .failed {
            retrySelectedTabCreation()
        }
        return true
    }

    private func localCommandSuggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, maximumCount > 0 else {
            return []
        }

        var suggestions = [BrowserCommandSuggestion]()
        suggestions.append(
            contentsOf: commandActionSuggestions(
                for: trimmedQuery,
                maximumCount: maximumCount,
            ),
        )

        suggestions
            .append(contentsOf: newDocumentSuggestions(for: trimmedQuery).prefix(maximumCount - suggestions.count))

        let remainingAfterCommands = maximumCount - suggestions.count
        if remainingAfterCommands > 0 {
            suggestions.append(
                contentsOf: internalPageSuggestions(
                    for: trimmedQuery,
                    maximumCount: remainingAfterCommands,
                ),
            )
        }

        let remainingAfterInternalPages = maximumCount - suggestions.count
        if remainingAfterInternalPages > 0 {
            suggestions.append(
                contentsOf: openTabSuggestions(
                    for: trimmedQuery,
                    maximumCount: remainingAfterInternalPages,
                ),
            )
        }

        let remainingAfterTabs = maximumCount - suggestions.count
        if remainingAfterTabs > 0 {
            suggestions.append(
                contentsOf: bookmarksModel.suggestions(
                    for: trimmedQuery,
                    maximumCount: remainingAfterTabs,
                ),
            )
        }

        let remainingAfterBookmarks = maximumCount - suggestions.count
        if remainingAfterBookmarks > 0 {
            suggestions.append(
                contentsOf: historyStore.suggestions(
                    for: trimmedQuery,
                    maximumCount: remainingAfterBookmarks,
                ),
            )
        }

        return Array(suggestions.prefix(maximumCount))
    }

    private func newDocumentSuggestions(for query: String) -> [BrowserCommandSuggestion] {
        BrowserNewDocument.matching(query, app: userPreferencesStore.newDocumentsApp).map {
            BrowserCommandSuggestion(kind: .url, displayText: $0.title, resolvedURLString: $0.urlString)
        }
    }

    private func commandActionSuggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        guard maximumCount > 0 else {
            return []
        }

        let normalizedQuery = normalizedCommandSearchText(query)
        return BrowserCommandID.allCases
            .filter(isCommandBarActionAvailable)
            .filter { commandID in
                commandSearchText(for: commandID).contains(normalizedQuery)
            }
            .prefix(maximumCount)
            .map { commandID in
                let descriptor = shortcutStore.descriptor(for: commandID)
                return BrowserCommandSuggestion(
                    kind: .command,
                    displayText: commandDisplayText(for: commandID, descriptor: descriptor),
                    commandID: commandID,
                    shortcut: descriptor.shortcut.isAssigned ? descriptor.shortcut : nil,
                )
            }
    }

    private func commandDisplayText(for commandID: BrowserCommandID, descriptor: BrowserCommandDescriptor) -> String {
        switch commandID {
        case .toggleBookmarksBar:
            userPreferencesStore.bookmarksBarVisible
                ? BrowserStrings.bookmarksHideBarAction
                : BrowserStrings.settingsShowBookmarksBar
        case .toggleSplitOrientation:
            splitOrientationToggleTitle
        case .toggleSidebarPosition:
            sidebarPositionToggleTitle
        case .expandCurrentSplit:
            isSelectedSplitPaneExpanded ? BrowserStrings.menuShowAllSplitPanes : BrowserStrings.menuExpandCurrentSplit
        case .toggleSiteToolbar:
            siteToolbarToggleTitle
        case .togglePinTab:
            pinToggleTitle
        default:
            descriptor.menuTitle
        }
    }

    private func commandSearchText(for commandID: BrowserCommandID) -> String {
        let descriptor = shortcutStore.descriptor(for: commandID)
        return ([
            descriptor.menuTitle,
            descriptor.helpTitle,
            commandID.rawValue,
        ] + commandID.commandBarSearchAliases + descriptor.shortcut.commandBarSearchAliases)
            .map(normalizedCommandSearchText)
            .joined(separator: " ")
    }

    private func internalPageSuggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        guard maximumCount > 0 else {
            return []
        }

        let normalizedQuery = normalizedCommandSearchText(query)
        let pages = [
            (
                title: "Open Settings",
                detail: "openarc://settings",
                aliases: ["settings", "chrome://settings", "arc://settings", "dia://settings"],
                urlString: "openarc://settings/",
            ),
            (
                title: "Open Bookmarks",
                detail: "openarc://bookmarks",
                aliases: ["bookmarks", "chrome://bookmarks", "arc://bookmarks", "dia://bookmarks"],
                urlString: "openarc://bookmarks/",
            ),
            (
                title: "Open History",
                detail: "openarc://history",
                aliases: ["history", "chrome://history", "arc://history", "dia://history"],
                urlString: "openarc://history",
            ),
            (
                title: "Open Extensions",
                detail: "openarc://extensions",
                aliases: ["extensions", "chrome://extensions", "arc://extensions", "dia://extensions"],
                urlString: "openarc://extensions/",
            ),
            (
                title: "Open Passwords",
                detail: "openarc://password-manager/passwords",
                aliases: [
                    "passwords",
                    "password manager",
                    "password-manager",
                    "chrome://password-manager/passwords",
                    "arc://password-manager/passwords",
                    "dia://password-manager/passwords",
                ],
                urlString: "openarc://password-manager/passwords",
            ),
        ]

        return pages
            .filter { page in
                normalizedCommandSearchText(page.title).contains(normalizedQuery)
                    || normalizedCommandSearchText(page.detail).contains(normalizedQuery)
                    || page.aliases.contains { normalizedCommandSearchText($0).contains(normalizedQuery) }
            }
            .prefix(maximumCount)
            .map { page in
                BrowserCommandSuggestion(
                    kind: .url,
                    displayText: page.title,
                    detailText: page.detail,
                    resolvedURLString: page.urlString,
                )
            }
    }

    /// What an empty command bar lists: this Space's latest tabs, then history.
    /// Before anything is typed: the latest tabs, this Space's first and then
    /// the other Spaces' named by their Space, then recent history.
    private func recentCommandBarPages(maximumCount: Int) -> [BrowserCommandSuggestion] {
        let candidates = tabs
            .filter { $0.id != selectedTabID && !$0.urlString.isEmpty && $0.placement != .app }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        let here = candidates.filter { $0.spaceID == selectedSpaceID }
        let elsewhere = candidates.filter { $0.spaceID != selectedSpaceID }
        var recentTabs = (here + elsewhere)
            .prefix(maximumCount)
            .map(commandBarSuggestion(forTab:))
        // A Blank Window also offers the profile's other windows' tabs, as pages to open here.
        if windowMode == .blank, let group = windowGroup {
            let ownURLs = Set(recentTabs.map(\.resolvedURLString))
            let others = group.models
                .filter { $0 !== self }
                .flatMap(\.tabs)
                .filter { !$0.urlString.isEmpty && $0.placement != .app && !ownURLs.contains($0.urlString) }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
            var seen = Set<String>()
            for tab in others where recentTabs.count < maximumCount && seen.insert(tab.urlString).inserted {
                var page = BrowserCommandSuggestion(
                    kind: .history,
                    displayText: tab.displayTitle,
                    detailText: BrowserURLDisplayFormatter.displayString(for: tab.urlString),
                    resolvedURLString: tab.urlString,
                )
                page.faviconURL = tab.faviconURL
                recentTabs.append(page)
            }
        }
        // The page on screen is already here, so its visit is not offered either.
        var urls = Set(recentTabs.map(\.resolvedURLString))
        if let current = selectedTab?.urlString { urls.insert(current) }
        let history = historyStore.recentSuggestions(maximumCount: maximumCount + 1)
            .filter { !urls.contains($0.resolvedURLString) }
        return Array((recentTabs + history).prefix(maximumCount))
    }

    /// The small window's bar before typing: the latest tabs of every Space,
    /// the one on screen too, as pages to open there, then recent history.
    private func recentLittleWindowPages(maximumCount: Int) -> [BrowserCommandSuggestion] {
        let recentTabs = tabs
            .filter { !$0.urlString.isEmpty && $0.placement != .app }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(maximumCount)
            .map { Self.pageSuggestion(forTabSuggestion: commandBarSuggestion(forTab: $0)) }
        let urls = Set(recentTabs.map(\.resolvedURLString))
        let history = historyStore.recentSuggestions(maximumCount: maximumCount)
            .filter { !urls.contains($0.resolvedURLString) }
        return Array((recentTabs + history).prefix(maximumCount))
    }

    /// Tabs in every Space, those in the current one first, typos allowed.
    private func openTabSuggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        let activeIDs = Set(activeSpaceTabs.map(\.id))
        let candidates = tabs.filter { $0.id != selectedTabID && !$0.urlString.isEmpty }
            .sorted { activeIDs.contains($0.id) && !activeIDs.contains($1.id) }
        let index = BrowserSearchIndex(documents: candidates.map {
            .init(title: $0.displayTitle, urlString: $0.urlString)
        })
        return index.search(query, limit: maximumCount).map { position in
            commandBarSuggestion(forTab: candidates[position])
        }
    }

    private func commandBarSuggestion(forTab tab: Tab) -> BrowserCommandSuggestion {
        var suggestion = BrowserCommandSuggestion(
            kind: .openTab,
            displayText: tab.displayTitle,
            resolvedURLString: tab.urlString,
            tabIDs: [tab.id],
        )
        if tab.spaceID != selectedSpaceID {
            suggestion.spaceTitle = spaces.first { $0.id == tab.spaceID }?.title
        }
        suggestion.faviconURL = tab.faviconURL
        return suggestion
    }

    private func normalizedCommandSearchText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func resolvedBrowserURLString(_ urlString: String) -> String {
        BrowserInternalURLNormalizer.canonicalURLString(for: urlString) ?? urlString
    }

    private func tabURLString(forTabID tabID: String) -> String? {
        tabs.first(where: { $0.id == tabID })?.urlString
    }

    private func tabIDsBelowInSidebarOrder(forTabID tabID: String) -> [String] {
        let sidebarTabIDs = (appTabs + spacePinnedTabs + temporaryTabs).map(\.id)
        guard let tabIndex = sidebarTabIDs.firstIndex(of: tabID) else {
            return []
        }

        return Array(sidebarTabIDs.dropFirst(tabIndex + 1))
    }

    private func applyCreatedTabContext(_ context: PendingCreatedTabContext, toTabID tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            pendingCreatedTabContexts[tabID] = context
            return
        }

        guard let undoSnapshot = context.undoSnapshot else {
            tabs[index].spaceID = context.spaceID
            tabs[index].placement = context.placement
            tabs[index].pinnedURLString = pinnedURLString(for: tabs[index], movingTo: context.placement)
            return
        }

        tabs[index] = restoredTab(from: undoSnapshot, id: tabID)
        moveTab(id: tabID, toGlobalIndex: undoSnapshot.insertionIndex)
        restoreCreationUndoReference(from: undoSnapshot, toTabID: tabID)
        restoreSelection(from: undoSnapshot, toTabID: tabID)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    private func restoredTab(from undoSnapshot: TabUndoSnapshot, id: String) -> Tab {
        Tab(
            id: id,
            // Explicit undo creates a new incarnation. Reusing the deleted
            // identity would let stale offline changes undo a server tombstone.
            syncID: tabSyncIDProvider(),
            spaceID: undoSnapshot.tab.spaceID,
            title: undoSnapshot.tab.title,
            userTitleOverride: undoSnapshot.tab.userTitleOverride,
            urlString: undoSnapshot.tab.urlString,
            pinnedURLString: undoSnapshot.tab.pinnedURLString,
            faviconURLString: undoSnapshot.tab.faviconURLString,
            placement: undoSnapshot.tab.placement,
            pinnedFolderID: undoSnapshot.tab.pinnedFolderID,
            pinnedSiblingRank: undoSnapshot.tab.pinnedSiblingRank,
            lastActivityAt: undoSnapshot.tab.lastActivityAt,
        )
    }

    private func reidentifiedAppTab(
        from tab: Tab,
        id: String,
        title: String? = nil,
        urlString: String? = nil,
        lastActivityAt: Date? = nil,
    ) -> Tab {
        Tab(
            id: id,
            syncID: tab.syncID,
            spaceID: tab.spaceID,
            title: title ?? tab.title,
            userTitleOverride: tab.userTitleOverride,
            urlString: urlString ?? tab.urlString,
            pinnedURLString: nil,
            faviconURLString: tab.faviconURLString,
            placement: .app,
            pinnedFolderID: nil,
            lastActivityAt: lastActivityAt ?? tab.lastActivityAt,
        )
    }

    private func reidentifiedPinnedTab(
        from tab: Tab,
        id: String,
        title: String? = nil,
        urlString: String? = nil,
        lastActivityAt: Date? = nil,
    ) -> Tab {
        Tab(
            id: id,
            syncID: tab.syncID,
            spaceID: tab.spaceID,
            title: title ?? tab.title,
            userTitleOverride: tab.userTitleOverride,
            urlString: urlString ?? tab.urlString,
            pinnedURLString: effectivePinnedURLString(forPinnedTab: tab),
            faviconURLString: tab.faviconURLString,
            placement: .spacePinned,
            pinnedFolderID: tab.pinnedFolderID,
            pinnedSiblingRank: tab.pinnedSiblingRank,
            lastActivityAt: lastActivityAt ?? tab.lastActivityAt,
        )
    }

    private func reopenClosedAppTab(id: String) {
        guard
            canCreateTab,
            let index = tabs.firstIndex(where: { $0.id == id }),
            tabs[index].placement == .app,
            closedAppTabIDs.contains(id)
        else {
            return
        }

        let tab = tabs[index]
        captureSelectedTabPreviewIfNeeded()
        dismissCommandBar()

        let adopted = adoptPageFromAnotherWindow(syncID: tab.syncID, makeActive: true)
        let newTabID: String
        if let adopted {
            newTabID = adopted.id
        } else {
            windowGroup?.pageWillOpen(syncID: tab.syncID, in: self)
            newTabID = createEngineTab(
                withURLString: resolvedBrowserURLString(tab.urlString),
                makeActive: true,
                spaceID: nil,
            )
            pendingReopenedAppTabCreations[newTabID] = .init(previousID: id, titleAtRequest: tab.title)
        }
        tabs[index] = reidentifiedAppTab(
            from: tab,
            id: newTabID,
            lastActivityAt: advancedActivityDate(after: tab.lastActivityAt),
        )
        if let adopted {
            applyAdoptedPage(adopted.handoff, toTabAt: index)
        }
        closedAppTabIDs.remove(id)
        replaceTabRuntimeReferences(oldID: id, newID: newTabID, spaceID: tab.spaceID)

        selectedSpaceID = tab.spaceID
        selectedTabID = newTabID
        findResultMatchCount = nil
        setSelectedTabID(newTabID, forSpaceID: tab.spaceID)
        recordSelectedTab(newTabID)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    private func reopenClosedPinnedTab(id: String) {
        guard
            canCreateTab,
            let index = tabs.firstIndex(where: { $0.id == id }),
            tabs[index].placement != .app,
            closedPinnedTabIDs.contains(id)
        else {
            return
        }

        let tab = tabs[index]
        captureSelectedTabPreviewIfNeeded()
        dismissCommandBar()

        // A tab restored unloaded keeps the page it showed last; one the user
        // unloaded opens its pinned URL.
        let restoresLastPage = lastPageRestoreTabIDs.remove(id) != nil && !tab.urlString.isEmpty
        // A page open in another window comes here as it is.
        let adopted = adoptPageFromAnotherWindow(syncID: tab.syncID, makeActive: true)
        let urlString = restoresLastPage || adopted != nil
            ? tab.urlString
            : effectivePinnedURLString(forPinnedTab: tab) ?? tab.urlString
        let newTabID: String
        if let adopted {
            newTabID = adopted.id
        } else {
            windowGroup?.pageWillOpen(syncID: tab.syncID, in: self)
            newTabID = createEngineTab(
                withURLString: resolvedBrowserURLString(urlString),
                makeActive: true,
                spaceID: tab.spaceID,
            )
            pendingReopenedPinnedTabCreations[newTabID] = .init(previousID: id, titleAtRequest: tab.title)
        }
        tabs[index] = tab.placement == .spacePinned
            ? reidentifiedPinnedTab(
                from: tab,
                id: newTabID,
                urlString: urlString,
                lastActivityAt: advancedActivityDate(after: tab.lastActivityAt),
            )
            : reidentifiedTab(from: tab, id: newTabID, lastActivityAt: advancedActivityDate(after: tab.lastActivityAt))
        if let adopted {
            applyAdoptedPage(adopted.handoff, toTabAt: index)
        }
        closedPinnedTabIDs.remove(id)
        replaceTabRuntimeReferences(oldID: id, newID: newTabID, spaceID: tab.spaceID)
        loadSplitSiblings(ofTabWithID: newTabID)

        selectedSpaceID = tab.spaceID
        selectedTabID = newTabID
        findResultMatchCount = nil
        setSelectedTabID(newTabID, forSpaceID: tab.spaceID)
        recordSelectedTab(newTabID)
        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    /// Gives an unloaded tab that moved out of the pinned tabs or Favorites a
    /// page at its last URL, keeping its row, identity and selection.
    private func loadUnloadedTabInPlace(id: String, persists: Bool = true) {
        guard canCreateTab, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        lastPageRestoreTabIDs.remove(id)
        closedPinnedTabIDs.remove(id)
        closedAppTabIDs.remove(id)
        let isSelected = selectedTabID == id
        let adopted = adoptPageFromAnotherWindow(syncID: tab.syncID, makeActive: isSelected)
        let newTabID: String
        if let adopted {
            newTabID = adopted.id
        } else {
            windowGroup?.pageWillOpen(syncID: tab.syncID, in: self)
            newTabID = createEngineTab(
                withURLString: resolvedBrowserURLString(tab.urlString),
                makeActive: isSelected,
                spaceID: tab.placement == .app ? nil : tab.spaceID,
            )
            pendingReopenedPinnedTabCreations[newTabID] = .init(previousID: id, titleAtRequest: tab.title)
        }
        tabs[index] = reidentifiedTab(from: tab, id: newTabID)
        if let adopted {
            applyAdoptedPage(adopted.handoff, toTabAt: index)
        }
        replaceTabRuntimeReferences(oldID: id, newID: newTabID, spaceID: tab.spaceID, selectsInSpace: false)
        if isSelected {
            tabDriver.selectTab(withID: newTabID)
        }
        if persists {
            persistCurrentSessionIfAllowed()
        }
    }

    private func handleReopenedPersistentTabCreated(id: String, title: String, urlString: String) {
        // Reopen publishes its logical identity and selection before allocation.
        // A delayed placeholder must not replay its old placement or selection,
        // nor revive an engine that has already completed another unload.
        guard let creation = pendingReopenedAppTabCreations[id] ?? pendingReopenedPinnedTabCreations[id] else { return }
        // Archive controls also depend on the pending binding. Publish its
        // completion even if newer metadata makes the title callback obsolete.
        objectWillChange.send()
        retireTabCreationCallbacks(id: id)
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].title == creation.titleAtRequest, tabs[index].urlString == urlString else { return }
        tabs[index].title = title
        updateWindowTitle()
    }

    private func replaceTabRuntimeReferences(
        oldID: String, newID: String, spaceID: String, selectsInSpace: Bool = true,
    ) {
        if selectedTabID == oldID {
            selectedTabID = newID
        }

        for index in spaces.indices where spaces[index].selectedTabID == oldID {
            spaces[index].selectedTabID = newID
        }
        if selectsInSpace {
            setSelectedTabID(newID, forSpaceID: spaceID)
        }

        recentlySelectedTabIDs = recentlySelectedTabIDs.map { $0 == oldID ? newID : $0 }
        if movedPageTabIDs.remove(oldID) != nil {
            movedPagePictures.removeValue(forKey: oldID)
        }
        if let previewImage = tabPreviewImagesByID.removeValue(forKey: oldID) {
            tabPreviewImagesByID[newID] = previewImage
        }
        if let creationUndoReference = tabCreationUndoReferences.removeValue(forKey: oldID) {
            creationUndoReference.currentTabID = newID
            tabCreationUndoReferences[newID] = creationUndoReference
        }
        clearTabSwitcherState()
    }

    private func moveTab(id tabID: String, toGlobalIndex insertionIndex: Int) {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let tab = tabs.remove(at: currentIndex)
        let targetIndex = min(max(insertionIndex, 0), tabs.count)
        tabs.insert(tab, at: targetIndex)
    }

    private func restoreSelection(from undoSnapshot: TabUndoSnapshot, toTabID tabID: String) {
        let tabSpaceID = undoSnapshot.tab.spaceID
        if undoSnapshot.wasSelectedInSpace {
            setSelectedTabID(tabID, forSpaceID: tabSpaceID)
        }

        guard undoSnapshot.wasSelectedTab || selectedTabID == nil else {
            return
        }

        selectedSpaceID = tabSpaceID
        selectedTabID = tabID
        findResultMatchCount = nil
        setSelectedTabID(tabID, forSpaceID: tabSpaceID)
        recordSelectedTab(tabID)
    }

    private func restoreCreationUndoReference(from undoSnapshot: TabUndoSnapshot, toTabID tabID: String) {
        guard let creationUndoReference = undoSnapshot.creationUndoReference else {
            return
        }

        creationUndoReference.currentTabID = tabID
        tabCreationUndoReferences[tabID] = creationUndoReference
    }

    private func tabUndoSnapshot(forClosingTabAt closingIndex: Int) -> TabUndoSnapshot? {
        guard tabs.indices.contains(closingIndex) else {
            return nil
        }

        let tab = tabs[closingIndex]
        return TabUndoSnapshot(
            tab: tab,
            insertionIndex: closingIndex,
            wasSelectedTab: selectedTabID == tab.id,
            wasSelectedInSpace: spaces.first { $0.id == tab.spaceID }?.selectedTabID == tab.id,
            creationUndoReference: tabCreationUndoReferences[tab.id],
        )
    }

    /// Undo for a closed Peek: Undo, or Restore Last Closed Tab, reopens it.
    private func registerPeekReopenUndo(urlString: String, standalone: Bool) {
        guard canRegisterTabUndo, !urlString.isEmpty, urlString != "about:blank" else { return }
        undoManager.registerTabAction(.init(name: BrowserStrings.peekCloseAction) { [weak self] completion in
            guard let self, canCreateTab else {
                completion(.cancelled)
                return
            }
            if standalone {
                tabDriver.showLittleWindow(withURLString: urlString)
            } else {
                tabDriver.showPeek(withURLString: urlString)
            }
            completion(.committed(inverse: nil))
        })
    }

    private func registerTabCreationUndo(_ reference: TabCreationUndoReference, actionName: String) {
        guard canRegisterTabUndo else { return }
        undoManager.registerTabAction(creationUndoAction(reference, actionName: actionName))
    }

    private func registerTabCloseUndo(
        _ snapshot: TabUndoSnapshot, archiveID: String?, kind: TabHistoryKind, actionName: String,
        batch: UUID? = nil,
    ) {
        guard canRegisterTabUndo else { return }
        var action = historyRestoreAction(snapshot, archiveID: archiveID, kind: kind, actionName: actionName)
        action.batch = batch
        undoManager.registerTabAction(action)
    }

    private func creationUndoAction(
        _ reference: TabCreationUndoReference, actionName: String,
    ) -> BrowserTabUndoManager.Action {
        .init(name: actionName) { [weak self] completion in
            guard let self else { completion(.cancelled)
                return
            }
            guard let id = reference.currentTabID, tabs.contains(where: { $0.id == id }) else {
                completion(.committed(inverse: nil))
                return
            }
            let admitted = requestConfirmedTabClose(
                id: id, registersUndo: false, actionName: actionName,
                createsArchive: false, preservesPersistentTab: false, historyKind: .creation,
            ) { [weak self] result in
                guard let self else { completion(.cancelled)
                    return
                }
                switch result {
                case .cancelled: completion(.cancelled)
                case .removed: completion(.committed(inverse: nil))
                case .closed(let snapshot, _):
                    completion(.committed(inverse: historyRestoreAction(
                        snapshot, archiveID: nil, kind: .creation, actionName: actionName,
                    )))
                }
            }
            if !admitted {
                completion(.cancelled)
            }
        }
    }

    private func archiveRedoAction(syncID: String, actionName: String) -> BrowserTabUndoManager.Action {
        closeRedoAction(syncID: syncID, kind: .archive, actionName: actionName)
    }

    private func logicalRemovalRedoAction(syncID: String, actionName: String) -> BrowserTabUndoManager.Action {
        closeRedoAction(syncID: syncID, kind: .logicalRemoval, actionName: actionName)
    }

    private func closeRedoAction(
        syncID: String, kind: TabHistoryKind, actionName: String,
    ) -> BrowserTabUndoManager.Action {
        .init(name: actionName) { [weak self] completion in
            guard let self else { completion(.cancelled)
                return
            }
            guard let tab = tabs.first(where: { $0.syncID == syncID }),
                  kind == .logicalRemoval || tab.placement == .temporary
            else {
                completion(.committed(inverse: nil))
                return
            }
            let admitted = requestConfirmedTabClose(
                id: tab.id, registersUndo: false, actionName: actionName,
                createsArchive: kind == .archive, preservesPersistentTab: kind == .archive,
                historyKind: kind,
            ) { [weak self] result in
                guard let self else { completion(.cancelled)
                    return
                }
                switch result {
                case .cancelled: completion(.cancelled)
                case .removed: completion(.committed(inverse: nil))
                case .closed(let snapshot, let archiveID):
                    completion(.committed(inverse: historyRestoreAction(
                        snapshot, archiveID: archiveID, kind: kind, actionName: actionName,
                    )))
                }
            }
            if !admitted {
                completion(.cancelled)
            }
        }
    }

    private func historyRestoreAction(
        _ snapshot: TabUndoSnapshot, archiveID: String?, kind: TabHistoryKind, actionName: String,
    ) -> BrowserTabUndoManager.Action {
        .init(name: actionName) { [weak self] completion in
            guard let self, pendingHistoryRestore == nil, canCreateTab,
                  !hasUncommittedSessionWrites
            else { completion(.cancelled)
                return
            }
            pendingHistoryRestore = PendingHistoryRestore(
                archiveID: archiveID, syncID: tabSyncIDProvider(), snapshot: snapshot,
                kind: kind, actionName: actionName, completion: completion,
            )
            _ = retryHistoryRestore()
        }
    }

    /// A failed restore has not changed the live tree. Retry keeps its identities
    /// and rebuilds the snapshot from current edits instead of buffering a stale
    /// full snapshot that could erase later tabs or consume the entry twice.
    @discardableResult private func retryHistoryRestore() -> Bool {
        guard let request = pendingHistoryRestore, canCreateTab, isPersistenceEnabled,
              !hasDiscardedSessionForClosure, sessionWriteBuffer.writes.isEmpty,
              !isRestoringSession, !isApplyingRemoteSync, !isReconcilingRemoteProjection,
              !isArchiveOperationInFlight, pendingRemoteTabCreations.isEmpty else { return false }
        do {
            let original = request.snapshot.tab
            var archived: BrowserTabArchiveEntry?
            if let archiveID = request.archiveID {
                guard let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring else {
                    throw BrowserTabArchiveError.unsupportedStore
                }
                guard let entry = try archive.loadArchiveEntry(id: archiveID) else {
                    archiveError = BrowserStrings.archiveEntryMissing
                    finishHistoryRestore(request, outcome: .committed(inverse: nil))
                    archiveRevision &+= 1
                    return true
                }
                archived = entry
            }
            let destination: String
            if spaces.contains(where: { $0.id == original.spaceID }) {
                destination = original.spaceID
            } else if request.archiveID == nil, let fallback = selectedSpaceID ?? spaces.first?.id {
                destination = fallback
            } else {
                archiveError = BrowserStrings.archiveDestinationMissing
                finishHistoryRestore(request, outcome: .cancelled)
                return false
            }
            guard !request.syncID.isEmpty, request.syncID != original.syncID,
                  !tabs.contains(where: { $0.syncID == request.syncID })
            else {
                throw BrowserTabArchiveError.restoredTabIDNotFresh
            }
            let now = dateProvider().timeIntervalSince1970.rounded(.down)
            guard now.isFinite else { throw BrowserTabArchiveError.invalidEntry }
            let placement = archived == nil ? original.placement : .temporary
            let folderID = placement == .spacePinned && pinnedTabFolders
                .contains(where: { $0.id == original.pinnedFolderID && $0.spaceID == destination })
                ? original.pinnedFolderID
                : nil
            let restored = BrowserTabSessionSnapshotTab(
                id: request.syncID, urlString: archived?.tab.urlString ?? original.urlString,
                pinnedURLString: placement.keepsPinnedURL ? original.pinnedURLString : nil,
                userTitleOverride: archived?.tab.userTitleOverride ?? original.userTitleOverride,
                placement: placement, spaceID: destination, pinnedFolderID: folderID,
                lastActivityTimestamp: now,
                pinnedSiblingRank: destination == original.spaceID && folderID == original.pinnedFolderID
                    ? original.pinnedSiblingRank
                    : nil,
                pageTitle: archived?.tab.pageTitle ?? (original.title.isEmpty ? nil : original.title),
                systemImageName: archived?.tab.systemImageName ?? tabIconsBySyncID[original.syncID],
            )
            let shouldSelect = request.snapshot.wasSelectedTab || selectedTabID == nil
            let outgoing = shouldSelect && canRecordExplicitViewingActivity && selectedTab?.creationState == .ready
                ? selectedTab
                : nil
            let outgoingDate = outgoing.map { advancedActivityDate(after: $0.lastActivityAt) }
            let current = currentSessionSnapshot()
            var nextTabs = current.tabs.map { tab in
                guard tab.id == outgoing?.syncID, let outgoingDate else { return tab }
                return BrowserTabSessionSnapshotTab(
                    id: tab.id, urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
                    userTitleOverride: tab.userTitleOverride, placement: tab.placement, spaceID: tab.spaceID,
                    pinnedFolderID: tab.pinnedFolderID, lastActivityTimestamp: outgoingDate.timeIntervalSince1970,
                    pinnedSiblingRank: tab.pinnedSiblingRank, pageTitle: tab.pageTitle,
                    systemImageName: tab.systemImageName,
                )
            }
            let insertionIndex = min(max(request.snapshot.insertionIndex, 0), nextTabs.count)
            nextTabs.insert(restored, at: insertionIndex)
            let next = BrowserTabSessionSnapshot(
                spaces: current.spaces?.map { space in
                    let selectedID: String?
                    if space.id == destination, request.snapshot.wasSelectedInSpace || shouldSelect {
                        selectedID = request.syncID
                    } else {
                        let runtimeID = spaces.first { $0.id == space.id }?.selectedTabID
                        selectedID = tabs.first { $0.id == runtimeID }?.syncID
                    }
                    let members = nextTabs.filter { $0.spaceID == space.id }
                    let visible = members.filter { $0.placement == .spacePinned } + members
                        .filter { $0.placement == .temporary }
                    return BrowserSpaceSessionSnapshot(
                        id: space.id, title: space.title, systemImageName: space.systemImageName,
                        isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                        selectedTabIndex: visible.firstIndex { $0.id == selectedID },
                        colorName: space.colorName,
                        profileDirectory: space.profileDirectory,
                    )
                }, pinnedTabFolders: current.pinnedTabFolders, tabs: nextTabs, splitGroups: current.splitGroups,
            )
            try sessionSnapshotStore.writeSessionBatch([.init(
                snapshot: next, origin: .local(syncMove: nil),
                archiveAction: request.archiveID.map { .restore(archiveID: $0, tabID: request.syncID) },
            )])
            isSessionClosurePrepared = false
            let reference = publishHistoryRestoration(
                request, restored: restored, insertionIndex: insertionIndex,
                shouldSelect: shouldSelect, outgoing: outgoing, outgoingDate: outgoingDate,
            )
            archiveError = nil
            if request.archiveID != nil {
                archiveRevision &+= 1
            }
            sessionPreferencesStore.saveSelectedSpaceIndex(selectedSpaceIndex)
            sessionPreferencesStore.saveSelectedTabIndex(next.tabs.firstIndex { $0.id == selectedTab?.syncID })
            syncCoordinator?.schedulePush(snapshot: next)
            let inverse: BrowserTabUndoManager.Action =
                switch request.kind {
                case .creation: creationUndoAction(reference, actionName: request.actionName)
                case .archive: archiveRedoAction(syncID: request.syncID, actionName: request.actionName)
                case .logicalRemoval: logicalRemovalRedoAction(syncID: request.syncID, actionName: request.actionName)
                }
            finishHistoryRestore(request, outcome: .committed(inverse: inverse))
            return true
        } catch {
            if error as? BrowserTabArchiveError == .entryMissing || error as? BrowserTabArchiveError ==
                .archiveAlreadyRestored
            {
                archiveError = BrowserStrings.archiveEntryMissing
                finishHistoryRestore(request, outcome: .committed(inverse: nil))
                archiveRevision &+= 1
                return true
            }
            var classification = BrowserSessionWriteBuffer()
            classification.recordFailure(error)
            historyRestoreFailure = classification.failure
            publishSessionPersistenceFailure()
            return false
        }
    }

    private func finishHistoryRestore(_ request: PendingHistoryRestore, outcome: BrowserTabUndoManager.Outcome) {
        pendingHistoryRestore = nil
        let wasBlocked = hasUncommittedSessionWrites
        historyRestoreFailure = nil
        showSessionPersistenceFailure(sessionWriteBuffer.failure)
        if wasBlocked, !hasUncommittedSessionWrites {
            deferredRemoteSyncSnapshot = nil
            syncCoordinator?.setLocalPersistenceBlocked(false)
            syncCoordinator?.schedulePull()
        }
        request.completion(outcome)
    }

    private func publishHistoryRestoration(
        _ request: PendingHistoryRestore, restored: BrowserTabSessionSnapshotTab, insertionIndex: Int,
        shouldSelect: Bool, outgoing: Tab?, outgoingDate: Date?,
    ) -> TabCreationUndoReference {
        let wasRestoringSession = isRestoringSession
        isRestoringSession = true
        defer { isRestoringSession = wasRestoringSession }
        if let outgoingDate, let index = tabs.firstIndex(where: { $0.id == outgoing?.id }) {
            tabs[index].lastActivityAt = outgoingDate
        }
        let runtimeID = createEngineTab(
            withURLString: resolvedBrowserURLString(restored.urlString), makeActive: shouldSelect,
            spaceID: restored.placement == .app ? nil : restored.spaceID ?? request.snapshot.tab.spaceID,
        )
        restoredTabCreationIDs.insert(runtimeID)
        let tab = Tab(
            id: runtimeID, syncID: request.syncID, spaceID: restored.spaceID ?? request.snapshot.tab.spaceID,
            title: request.snapshot.tab.title, userTitleOverride: restored.userTitleOverride,
            urlString: restored.urlString, pinnedURLString: restored.pinnedURLString,
            faviconURLString: request.snapshot.tab.faviconURLString, placement: restored.placement,
            pinnedFolderID: restored.pinnedFolderID, pinnedSiblingRank: restored.pinnedSiblingRank,
            lastActivityAt: Date(timeIntervalSince1970: restored.lastActivityTimestamp ?? 0),
        )
        tabs.insert(tab, at: min(insertionIndex, tabs.count))
        tabIconsBySyncID[request.syncID] = restored.systemImageName
        let reference = request.snapshot.creationUndoReference ?? TabCreationUndoReference(tabID: runtimeID)
        reference.currentTabID = runtimeID
        tabCreationUndoReferences[runtimeID] = reference
        if request.snapshot.wasSelectedInSpace || shouldSelect {
            setSelectedTabID(runtimeID, forSpaceID: tab.spaceID)
        }
        if shouldSelect {
            selectedSpaceID = tab.spaceID
            selectedTabID = runtimeID
            findResultMatchCount = nil
            recordSelectedTab(runtimeID)
        }
        updateWindowTitle()
        return reference
    }
}

// MARK: - Durable Archive

extension BrowserChromeModel {
    var canBrowseArchive: Bool {
        windowMode.persistsSession && isPersistenceEnabled && !isShuttingDown && !hasDiscardedSessionForClosure &&
            sessionSnapshotStore is any BrowserTabArchiveStoring
    }

    var canRestoreArchivedTab: Bool {
        canBrowseArchive && canCreateTab && !isArchiveOperationInFlight && !hasUncommittedSessionWrites &&
            !undoManager.isTabTransitionPending &&
            !isRestoringSession && !isApplyingRemoteSync && !isReconcilingRemoteProjection &&
            deferredRemoteSyncSnapshot == nil && pendingRemoteTabCreations.isEmpty &&
            pendingCreatedTabContexts.isEmpty && pendingHydratedTabCreationIDs.isEmpty &&
            pendingReopenedAppTabCreations.isEmpty && pendingReopenedPinnedTabCreations.isEmpty
    }

    func loadArchivedTabs(
        query: String, before: BrowserTabArchiveCursor? = nil, limit: Int = 50,
    ) async throws -> BrowserTabArchivePage {
        guard canBrowseArchive, let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring
        else { throw BrowserTabArchiveError.unsupportedStore }
        return try await archive.searchArchivePage(query: query, before: before, limit: limit)
    }

    func archiveClearBoundary() async throws -> BrowserTabArchiveBoundary {
        guard canBrowseArchive, let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring
        else { throw BrowserTabArchiveError.unsupportedStore }
        return try await archive.archiveClearBoundary()
    }

    @discardableResult func deleteArchivedTab(id: String) async -> Bool {
        guard canBrowseArchive, !isArchiveOperationInFlight,
              let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring else { return false }
        isArchiveOperationInFlight = true
        archiveError = nil
        defer { isArchiveOperationInFlight = false }
        do {
            _ = try await archive.removeArchiveEntry(id: id)
            archiveRevision &+= 1
            return true
        } catch {
            archiveError = BrowserStrings.archiveActionFailed
            return false
        }
    }

    @discardableResult func clearArchive(through boundary: BrowserTabArchiveBoundary) async -> Bool {
        guard canBrowseArchive, !isArchiveOperationInFlight,
              let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring else { return false }
        isArchiveOperationInFlight = true
        archiveError = nil
        defer { isArchiveOperationInFlight = false }
        do {
            _ = try await archive.clearArchive(through: boundary)
            archiveRevision &+= 1
            return true
        } catch {
            archiveError = BrowserStrings.archiveActionFailed
            return false
        }
    }

    func syncArchiveDidChange() {
        guard canBrowseArchive else { return }
        archiveRevision &+= 1
    }

    /// Commit the new identity and consume its recovery entry together before
    /// allocating an engine. Failed storage has no optimistic state to replay:
    /// an explicit Retry rebuilds this action against the latest live snapshot.
    @discardableResult func restoreArchivedTab(id: String, toSpaceID: String? = nil) -> String? {
        guard canRestoreArchivedTab, let archive = sessionSnapshotStore as? any BrowserTabArchiveStoring else {
            archiveError = BrowserStrings.archiveUnavailable
            return nil
        }
        isArchiveOperationInFlight = true
        archiveError = nil
        defer { isArchiveOperationInFlight = false }
        do {
            guard let entry = try archive.loadArchiveEntry(id: id) else {
                archiveError = BrowserStrings.archiveEntryMissing
                archiveRevision &+= 1
                return nil
            }
            guard let destination = toSpaceID ?? entry.tab.spaceID,
                  spaces.contains(where: { $0.id == destination })
            else {
                archiveError = BrowserStrings.archiveDestinationMissing
                return nil
            }
            let syncID = tabSyncIDProvider()
            guard !syncID.isEmpty, syncID != entry.tab.id, !tabs.contains(where: { $0.syncID == syncID })
            else { throw BrowserTabArchiveError.restoredTabIDNotFresh }
            let now = dateProvider().timeIntervalSince1970.rounded(.down)
            guard now.isFinite else { throw BrowserTabArchiveError.invalidEntry }
            let snapshot = currentSessionSnapshot()
            let outgoing = canRecordExplicitViewingActivity && selectedTab?.creationState == .ready ? selectedTab : nil
            let outgoingDate = outgoing.map { advancedActivityDate(after: $0.lastActivityAt) }
            let restored = BrowserTabSessionSnapshotTab(
                id: syncID, urlString: entry.tab.urlString, userTitleOverride: entry.tab.userTitleOverride,
                placement: .temporary, spaceID: destination, lastActivityTimestamp: now, pageTitle: entry.tab.pageTitle,
                systemImageName: entry.tab.systemImageName,
            )
            let nextTabs = snapshot.tabs.map { tab in
                guard tab.id == outgoing?.syncID, let outgoingDate else { return tab }
                return BrowserTabSessionSnapshotTab(
                    id: tab.id, urlString: tab.urlString, pinnedURLString: tab.pinnedURLString,
                    userTitleOverride: tab.userTitleOverride, placement: tab.placement, spaceID: tab.spaceID,
                    pinnedFolderID: tab.pinnedFolderID, lastActivityTimestamp: outgoingDate.timeIntervalSince1970,
                    pinnedSiblingRank: tab.pinnedSiblingRank, pageTitle: tab.pageTitle,
                    systemImageName: tab.systemImageName,
                )
            } + [restored]
            let next = BrowserTabSessionSnapshot(
                spaces: snapshot.spaces?.map { space in
                    guard space.id == destination else { return space }
                    return BrowserSpaceSessionSnapshot(
                        id: space.id, title: space.title, systemImageName: space.systemImageName,
                        isPinnedSectionCollapsed: space.isPinnedSectionCollapsed,
                        selectedTabIndex: nextTabs.count(where: { $0.spaceID == destination && $0.placement != .app })
                            - 1,
                        colorName: space.colorName,
                        profileDirectory: space.profileDirectory,
                    )
                }, pinnedTabFolders: snapshot.pinnedTabFolders, tabs: nextTabs, splitGroups: snapshot.splitGroups,
            )
            // Archive transitions cannot be buffered independently of the live
            // tree: a later full snapshot could otherwise drop a consumed restore.
            try sessionSnapshotStore.writeSessionBatch([.init(
                snapshot: next, origin: .local(syncMove: nil), archiveAction: .restore(archiveID: id, tabID: syncID),
            )])
            isSessionClosurePrepared = false
            publishArchivedTab(entry: entry, restored: restored, outgoing: outgoing, outgoingDate: outgoingDate)
            tabRowsChanged()
            archiveRevision &+= 1
            sessionPreferencesStore.saveSelectedSpaceIndex(selectedSpaceIndex)
            sessionPreferencesStore.saveSelectedTabIndex(next.tabs.firstIndex { $0.id == syncID })
            syncCoordinator?.schedulePush(snapshot: next)
            return syncID
        } catch {
            archiveError = (error as? BrowserTabArchiveError) == .entryMissing ||
                (error as? BrowserTabArchiveError) == .archiveAlreadyRestored
                ? BrowserStrings.archiveEntryMissing
                : BrowserStrings.archiveRestoreFailed
            return nil
        }
    }

    private func publishArchivedTab(
        entry: BrowserTabArchiveEntry, restored: BrowserTabSessionSnapshotTab, outgoing: Tab?, outgoingDate: Date?,
    ) {
        guard let syncID = restored.id, let destination = restored.spaceID,
              let activity = restored.lastActivityTimestamp else { return }
        // Suppress incidental selection persistence during this synchronous
        // publication; its complete snapshot already committed with the receipt.
        isRestoringSession = true
        defer { isRestoringSession = false }
        if let outgoingDate, let index = tabs.firstIndex(where: { $0.id == outgoing?.id }) {
            tabs[index].lastActivityAt = outgoingDate
        }
        captureSelectedTabPreviewIfNeeded()
        dismissCommandBar()
        dismissFindBar()
        invalidateSelectedTabWebAppInstallMetadata()
        let runtimeID = createEngineTab(
            withURLString: resolvedBrowserURLString(restored.urlString),
            makeActive: true,
            spaceID: restored.spaceID,
        )
        restoredTabCreationIDs.insert(runtimeID)
        tabs.append(Tab(
            id: runtimeID, syncID: syncID, spaceID: destination, title: entry.title ?? "",
            userTitleOverride: restored.userTitleOverride, urlString: restored.urlString,
            placement: .temporary, lastActivityAt: Date(timeIntervalSince1970: activity),
        ))
        tabIconsBySyncID[syncID] = restored.systemImageName
        selectedSpaceID = destination
        selectedTabID = runtimeID
        setSelectedTabID(runtimeID, forSpaceID: destination)
        findResultMatchCount = nil
        recordSelectedTab(runtimeID)
        updateWindowTitle()
    }
}

// MARK: BrowserSyncExpiryScheduling

extension BrowserChromeModel: BrowserSyncExpiryScheduling {
    func expirySchedulingState() -> BrowserSyncExpirySchedulingState? {
        guard canBrowseArchive, automaticArchivalSettingsLoaded, !isArchiveOperationInFlight,
              isViewingActivityActive, isContextReady, isPersistenceEnabled, !isShuttingDown,
              !isRestoringSession, !isApplyingRemoteSync, !isReconcilingRemoteProjection,
              deferredRemoteSyncSnapshot == nil, pendingRemoteTabCreations.isEmpty,
              pendingCreatedTabContexts.isEmpty, pendingHydratedTabCreationIDs.isEmpty,
              pendingReopenedAppTabCreations.isEmpty, pendingReopenedPinnedTabCreations.isEmpty,
              !hasUncommittedSessionWrites, pendingTabCloseRequests.isEmpty,
              tabs
                .allSatisfy({
                    $0.creationState == .ready || closedAppTabIDs.contains($0.id) || closedPinnedTabIDs
                        .contains($0.id) })
        else { return nil }
        let visibleIDs = Set(selectedTabID.map { splitPaneTabIDs(forTabID: $0) } ?? [])
        let protectedIDs = Set(tabs.filter { visibleIDs.contains($0.id) }.map(\.syncID))
        guard let ownership = sessionSnapshotStore as? any BrowserSyncOwnershipReading else { return nil }
        let owner: BrowserSyncOwner?
        do {
            owner = try ownership.syncOwner()
        } catch {
            return nil
        }
        return .init(
            inactiveForSeconds: owner != nil && automaticTabArchivalEnabled
                ? Int(temporaryTabLifetime.timeInterval)
                : nil,
            protectedTabIDs: protectedIDs,
        )
    }

    func refreshExpiryActivity() -> Bool {
        guard expirySchedulingState() != nil else { return false }
        persistCurrentViewingActivity()
        return !hasUncommittedSessionWrites
    }
}

@MainActor private extension BrowserChromeModel {
    var canRecordViewingActivity: Bool {
        canRecordExplicitViewingActivity && !isApplyingRemoteSync
    }

    var canRecordExplicitViewingActivity: Bool {
        isViewingActivityActive && isContextReady && isPersistenceEnabled && !isShuttingDown &&
            !isRestoringSession && !isReconcilingRemoteProjection
    }

    @discardableResult func recordExplicitViewingActivity(ids: [String?]) -> Bool {
        guard canRecordExplicitViewingActivity else { return false }
        var changed = false
        for id in Set(ids.compactMap(\.self)) where touchTab(id: id) {
            changed = true
        }
        return changed
    }

    func advancedActivityDate(after previous: Date) -> Date {
        let now = dateProvider().timeIntervalSince1970.rounded(.down)
        guard now.isFinite else { return previous }
        let old = previous.timeIntervalSince1970
        return !old.isFinite || now > old ? Date(timeIntervalSince1970: now) : previous
    }

    @discardableResult func recordCurrentViewingActivity() -> Bool {
        guard canRecordExplicitViewingActivity, let selectedTabID,
              selectedTab?.creationState == .ready
        else { return false }
        return touchTab(id: selectedTabID)
    }

    func persistCurrentViewingActivity() {
        if recordCurrentViewingActivity() {
            persistCurrentSessionIfAllowed()
        }
    }

    func startAutomaticArchivalTimerIfNeeded() {
        guard automaticArchivalTimer == nil else {
            return
        }

        automaticArchivalTimer = Timer.scheduledTimer(
            withTimeInterval: Self.automaticArchivalCheckInterval,
            repeats: true,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.archiveExpiredTemporaryTabs()
            }
        }
    }

    func sanitizedUserTitleOverride(from titleOverride: String?) -> String? {
        guard let titleOverride else {
            return nil
        }

        let trimmedTitleOverride = titleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitleOverride.isEmpty ? nil : trimmedTitleOverride
    }

    func normalizedPinnedURLString(from urlString: String?) -> String? {
        guard let urlString else {
            return nil
        }

        let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else {
            return nil
        }

        if let canonicalInternalURLString = BrowserInternalURLNormalizer.canonicalURLString(for: trimmedURLString) {
            return canonicalInternalURLString
        }

        if
            let components = URLComponents(string: trimmedURLString),
            components.scheme?.isEmpty == false,
            let url = components.url
        {
            return url.absoluteString
        }

        guard let resolution = navigationResolver.resolve(trimmedURLString), resolution.kind == .url else {
            return nil
        }

        return resolution.resolvedURLString
    }

    func effectivePinnedURLString(forPinnedTab tab: Tab) -> String? {
        guard tab.placement.keepsPinnedURL else {
            return nil
        }

        return normalizedPinnedURLString(from: tab.pinnedURLString ?? tab.urlString)
    }

    func pinnedURLString(for tab: Tab, movingTo placement: BrowserTabPlacement) -> String? {
        guard placement.keepsPinnedURL else {
            return nil
        }

        if tab.placement == .spacePinned, let pinnedURLString = normalizedPinnedURLString(from: tab.pinnedURLString) {
            return pinnedURLString
        }

        return normalizedPinnedURLString(from: tab.urlString)
    }

    func areEquivalentPinnedURLStrings(_ lhs: String, _ rhs: String) -> Bool {
        comparablePinnedURLString(lhs) == comparablePinnedURLString(rhs)
    }

    func comparablePinnedURLString(_ urlString: String) -> String {
        let resolvedURLString = resolvedBrowserURLString(urlString)
        guard var components = URLComponents(string: resolvedURLString) else {
            return resolvedURLString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        }
        return components.url?.absoluteString ?? resolvedURLString.lowercased()
    }

    func fallbackTabID(afterClosingTab closingTab: Tab?) -> String? {
        guard let closingTab else {
            return sidebarTabsForSelectedSpace().first?.id
        }
        if let splitSiblingID = splitSiblingTabID(afterClosing: closingTab, excluding: []) {
            return splitSiblingID
        }

        let visibleTabs = sidebarTabs(forSpaceID: closingTab.spaceID)
        if let previous = recentlySelectedTabID(among: visibleTabs, excluding: [closingTab.id]) {
            return previous
        }
        let previousSidebarOrder = sidebarTabs(
            forSpaceID: closingTab.spaceID,
            including: closingTab,
        )
        guard let closingIndex = previousSidebarOrder.firstIndex(where: { $0.id == closingTab.id }) else {
            return visibleTabs.first?.id
        }

        if visibleTabs.indices.contains(closingIndex) {
            return visibleTabs[closingIndex].id
        }

        let previousIndex = closingIndex - 1
        if visibleTabs.indices.contains(previousIndex) {
            return visibleTabs[previousIndex].id
        }

        return visibleTabs.first?.id
    }

    /// The latest selected of these tabs, other than the excluded ones.
    private func recentlySelectedTabID(among candidates: [Tab], excluding excluded: Set<String>) -> String? {
        let ids = Set(candidates.map(\.id))
        return selectionHistory.last { ids.contains($0) && !excluded.contains($0) }
    }

    func fallbackTabID(afterClosingDormantTab closingTab: Tab, excluding excludedTabIDs: Set<String>) -> String? {
        if let splitSiblingID = splitSiblingTabID(
            afterClosing: closingTab,
            excluding: excludedTabIDs.union(closedPinnedTabIDs),
        ) {
            return splitSiblingID
        }
        let visibleTabs = sidebarTabs(forSpaceID: closingTab.spaceID)
            .filter { !excludedTabIDs.contains($0.id) && !closedPinnedTabIDs.contains($0.id) }
        if let previous = recentlySelectedTabID(among: visibleTabs, excluding: [closingTab.id]) {
            return previous
        }
        let previousSidebarOrder = sidebarTabs(forSpaceID: closingTab.spaceID, including: closingTab)
        guard let closingIndex = previousSidebarOrder.firstIndex(where: { $0.id == closingTab.id }) else {
            return visibleTabs.first?.id
        }

        if visibleTabs.indices.contains(closingIndex) {
            return visibleTabs[closingIndex].id
        }

        let previousIndex = closingIndex - 1
        if visibleTabs.indices.contains(previousIndex) {
            return visibleTabs[previousIndex].id
        }

        return visibleTabs.first?.id
    }

    func tabUsesWindowedBrowser(id: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return false
        }

        return Self.usesWindowedBrowser(for: tab.urlString)
    }

    static func usesWindowedBrowser(for _: String) -> Bool {
        false
    }

    static func internalPage(for urlString: String) -> BrowserInternalPage? {
        guard let host = BrowserInternalURLNormalizer.host(for: urlString) else {
            return nil
        }

        switch host {
        case BrowserInternalURLNormalizer.settingsHost:
            return .settings
        case BrowserInternalURLNormalizer.extensionsHost:
            return .extensions
        case BrowserInternalURLNormalizer.historyHost:
            return .history
        case BrowserInternalURLNormalizer.passwordManagerHost:
            return .passwordManager
        case BrowserInternalURLNormalizer.bookmarksHost:
            return .bookmarks
        default:
            return .chromiumWebUI
        }
    }

    func handleCreatedTab(id: String, title: String, urlString: String, isActive: Bool) {
        if engineProfilePathsByID.index(forKey: id) == nil {
            engineProfilePathsByID.updateValue(tabDriver.profileCachePathForNewTabs, forKey: id)
        }
        if handleRemoteCreatedTab(id: id, title: title, urlString: urlString) {
            return
        }
        if pendingHydratedTabCreationIDs.remove(id) != nil {
            if let index = tabs.firstIndex(where: { $0.id == id }),
               tabs[index].title.isEmpty, tabs[index].urlString == urlString
            {
                tabs[index].title = title
                updateWindowTitle()
            }
            return
        }
        if restoredTabCreationIDs.contains(id) {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else {
                // Keep the identity until model teardown so even duplicate late
                // callbacks cannot recreate a tab deleted during startup. The
                // placeholder callback does not create an engine; its earlier
                // close already canceled the controller's pending record.
                return
            }
            if tabs[index].title.isEmpty, tabs[index].urlString == urlString {
                tabs[index].title = title
                updateWindowTitle()
            }
            return
        }
        if pendingReopenedPinnedTabCreations[id] != nil || pendingReopenedAppTabCreations[id] != nil {
            handleReopenedPersistentTabCreated(id: id, title: title, urlString: urlString)
            return
        }

        guard !tabs.contains(where: { $0.id == id }) else { return }
        let pendingContext = pendingCreatedTabContexts.removeValue(forKey: id)
        let undoSnapshot = pendingContext?.undoSnapshot
        let fallbackSpaceID = selectedSpaceID ?? spaces.first?.id ?? Self.defaultSpaceID
        let tabSpaceID = undoSnapshot?.tab.spaceID ?? pendingContext?.spaceID ?? fallbackSpaceID
        if spaces.isEmpty {
            spaces = [makeDefaultSpace()]
            selectedSpaceID = tabSpaceID
        }
        let restoredPlacement = undoSnapshot?.tab.placement ?? pendingContext?
            .placement ?? .temporary
        let restoredPinnedURLString = undoSnapshot?.tab.pinnedURLString
        let tabPinnedURLString = restoredPlacement == .spacePinned
            ? normalizedPinnedURLString(from: restoredPinnedURLString ?? urlString)
            : nil
        tabs.append(
            Tab(
                id: id,
                syncID: undoSnapshot?.tab.syncID ?? tabSyncIDProvider(),
                spaceID: tabSpaceID,
                title: undoSnapshot?.tab.title ?? title,
                userTitleOverride: undoSnapshot?.tab.userTitleOverride,
                urlString: undoSnapshot?.tab.urlString ?? urlString,
                pinnedURLString: tabPinnedURLString,
                faviconURLString: undoSnapshot?.tab.faviconURLString,
                placement: restoredPlacement,
                pinnedFolderID: undoSnapshot?.tab.pinnedFolderID,
                pinnedSiblingRank: undoSnapshot?.tab.pinnedSiblingRank,
                lastActivityAt: undoSnapshot?.tab.lastActivityAt ?? dateProvider(),
            ),
        )

        if let pendingContext {
            applyCreatedTabContext(pendingContext, toTabID: id)
            if pendingContext.placesAtTop, pendingContext.undoSnapshot == nil,
               let firstToday = tabs.firstIndex(where: {
                   $0.spaceID == pendingContext.spaceID && $0.placement == .temporary && $0.id != id
               }),
               let index = tabs.firstIndex(where: { $0.id == id }), firstToday < index
            {
                moveTab(id: id, toGlobalIndex: firstToday)
            }
        } else {
            if isActive || selectedTabID == nil {
                selectedTabID = id
                findResultMatchCount = nil
            }
            if selectedTabID == id {
                setSelectedTabID(id, forSpaceID: tabSpaceID)
            }
        }

        if selectedTabID == id {
            recordSelectedTab(id)
        }

        if let tab = tabs.first(where: { $0.id == id }) {
            BrowserTelemetry.captureUsage(.tabCreated, properties: telemetryProperties(for: tab))
        }

        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    private func handleFindQueryChange() {
        findResultMatchCount = nil
        guard isFindBarPresented else {
            return
        }

        // A new query selects its first match, so the bar can count from it.
        runFind(forward: true, findNext: false, selectsMatch: true)
    }

    /// The engine's `findNext` also selects a match: a changed query selects its
    /// first one, while the same query steps on. Searches run again for another
    /// tab or a reload leave it off, so they never step.
    private func runFind(forward: Bool, findNext: Bool, selectsMatch: Bool = false) {
        guard canFindInPage, isFindBarPresented else {
            return
        }

        if !findNext {
            findResultMatchCount = nil
        }

        guard !findQuery.isEmpty else {
            tabDriver.stopFindingInActiveTab(clearSelection: true)
            return
        }

        tabDriver.findInActiveTab(
            text: findQuery,
            forward: forward,
            matchCase: false,
            findNext: findNext || selectsMatch,
        )
    }

    func handleFindResult(
        id: String,
        matchCount: Int,
        activeMatchOrdinal: Int,
        finalUpdate: Bool,
    ) {
        guard id == selectedTabID, isFindBarPresented, !findQuery.isEmpty else {
            return
        }

        if finalUpdate || matchCount > 0 {
            findResultMatchCount = max(matchCount, 0)
        }
        if activeMatchOrdinal > 0 {
            findResultActiveOrdinal = activeMatchOrdinal
        }
    }

    func handleDownloadUpdate(_ update: BrowserDownloadUpdate) {
        let isNew = !downloadsModel.items.contains { $0.id == update.id }
        downloadsModel.apply(update)
        if isNew {
            downloadLaunch = BrowserDownloadLaunch(id: update.id, fileName: update.fileName)
        }
    }

    func handleUpdatedTab(
        id: String,
        title: String?,
        urlString: String?,
        faviconURLString: String?,
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        var didChangePersistentURL = false
        var didChangeTitle = false

        if let title, tabs[index].title != title {
            tabs[index].title = title
            didChangeTitle = true
            windowGroup?.pageTitleDidChange(title, syncID: tabs[index].syncID, from: self)
        }

        // Chromium reports a view-source page by its inner URL; keep the
        // source view's own address so it reopens as source.
        let viewSource = "view-source:"
        let urlString = urlString.map { reported in
            tabs[index].urlString.hasPrefix(viewSource) && tabs[index].urlString.dropFirst(viewSource.count) == reported
                ? tabs[index].urlString
                : reported
        }
        if let urlString, tabs[index].urlString != urlString {
            tabs[index].urlString = urlString
            tabs[index].lastActivityAt = advancedActivityDate(after: tabs[index].lastActivityAt)
            didChangePersistentURL = true
            if id == selectedTabID {
                invalidateSelectedTabWebAppInstallMetadata()
                // Another site may have its own zoom.
                refreshZoomFromEngine()
            }
        }

        // The engine repeats unchanged values, as while a page resizes; an unchanged tab
        // publishes nothing.
        if let faviconURLString, tabs[index].faviconURLString != faviconURLString {
            tabs[index].faviconURLString = faviconURLString
        }

        // The engine's history file lags; this session's pages stay searchable.
        if windowMode != .incognito, didChangeTitle || didChangePersistentURL {
            historyStore.noteVisit(title: tabs[index].displayTitle, urlString: tabs[index].urlString)
        }

        updateWindowTitle()

        if didChangePersistentURL {
            BrowserTelemetry.captureUsage(.tabNavigated, properties: telemetryProperties(for: tabs[index]))
            persistCurrentSessionIfAllowed()
        }
    }

    private func blocksTabInteraction(_ id: String) -> Bool {
        closingTabIDs.contains(id) && pendingTabCloseRequests[id]?.localAutomaticCandidate == nil
    }

    private func retireTabCreationCallbacks(id: String) {
        restoredTabCreationIDs.insert(id)
        pendingCreatedTabContexts.removeValue(forKey: id)
        pendingHydratedTabCreationIDs.remove(id)
        pendingReopenedAppTabCreations = pendingReopenedAppTabCreations
            .filter { $0.key != id && $0.value.previousID != id }
        pendingReopenedPinnedTabCreations = pendingReopenedPinnedTabCreations
            .filter { $0.key != id && $0.value.previousID != id }
    }

    private func replaceRuntimeAfterPreservedClose(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasCompleting = isCompletingTabClose
        isCompletingTabClose = true
        defer { isCompletingTabClose = wasCompleting }
        let selected = selectedTabID == tab.id
        let newID = createEngineTab(
            withURLString: resolvedBrowserURLString(tab.urlString), makeActive: selected,
            spaceID: tab.placement == .app ? nil : tab.spaceID,
        )
        // Both old and replacement allocation callbacks are placeholders. Neither
        // may manufacture another logical identity after a late/duplicate reply.
        retireTabCreationCallbacks(id: tab.id)
        restoredTabCreationIDs.insert(newID)
        closedAppTabIDs.remove(tab.id)
        closedPinnedTabIDs.remove(tab.id)
        tabs[index] = Tab(
            id: newID, syncID: tab.syncID, spaceID: tab.spaceID, title: tab.title,
            userTitleOverride: tab.userTitleOverride, urlString: tab.urlString,
            pinnedURLString: tab.pinnedURLString, faviconURLString: tab.faviconURLString,
            placement: tab.placement, pinnedFolderID: tab.pinnedFolderID,
            pinnedSiblingRank: tab.pinnedSiblingRank, lastActivityAt: tab.lastActivityAt,
        )
        replaceTabRuntimeReferences(oldID: tab.id, newID: newID, spaceID: tab.spaceID, selectsInSpace: false)
        if selected {
            findResultMatchCount = nil
            invalidateSelectedTabWebAppInstallMetadata()
        }
        updateWindowTitle()
        // Runtime replacement changes no persistent identity, content or order.
    }

    private func handleTabCloseRequestFinished(id: String, requestID: String, outcome: BrowserTabCloseOutcome) {
        guard let request = pendingTabCloseRequests[id], request.requestID == requestID else { return }
        pendingTabCloseRequests.removeValue(forKey: id)
        closingTabIDs.remove(id)
        tabsLeavingSidebar.remove(id)
        defer {
            tabCloseUndoBatches.removeValue(forKey: id)
            if request.localAutomaticCandidate != nil {
                continueLocalAutomaticArchiveSweep()
            }
        }
        guard outcome == .closed else {
            request.completion?(.cancelled)
            return
        }
        guard !isShuttingDown, let tab = tabs.first(where: { $0.id == id }), tab.syncID == request.syncID else {
            request.completion?(.removed)
            return
        }
        if let candidate = request.localAutomaticCandidate {
            guard !request.invalidatedAutomaticClose, canAdmitLocalAutomaticArchive,
                  localAutomaticArchivalOwnershipAllowsClose(), tab.spaceID == candidate.spaceID,
                  tab.lastActivityAt == candidate.lastActivityAt, isLocalAutomaticArchiveEligible(tab)
            else {
                replaceRuntimeAfterPreservedClose(tab)
                return
            }
        }
        if request.unloadsPersistentTab, tab.placement == .temporary {
            // Unpinning while the page confirms must not turn an unload into a
            // deletion. Preserve the new logical state and replace its engine.
            replaceRuntimeAfterPreservedClose(tab)
            request.completion?(.removed)
            return
        }
        if tab.placement == .temporary || !request.preservesPersistentTab {
            // Capture current metadata and selection only after the final engine
            // callback. Cancellation never mutates the session or Undo history.
            finishTabClose(
                id: id, forceClose: false, requestsEngineClose: false,
                registersUndo: request.registersUndo, undoActionName: request.undoActionName,
                createsArchive: request.createsArchive, historyKind: request.historyKind,
                completion: request.completion,
            )
        } else {
            // Pin/Favorite may have arrived while the page's dialog was open.
            // Keep that persistent identity; its already-closed engine is dormant.
            let wasCompletingTabClose = isCompletingTabClose
            isCompletingTabClose = true
            if tab.placement == .app {
                closeAppTabProcess(id: id, engineAlreadyClosed: true)
            } else {
                closePinnedTabProcessOrReset(id: id, engineAlreadyClosed: true)
            }
            isCompletingTabClose = wasCompletingTabClose
            persistCurrentSessionIfAllowed()
            request.completion?(.removed)
        }
    }

    /// A Today tab opened only to download a file leaves without an archive
    /// entry, and the tab selected before it comes back.
    func closeTabThatOnlyDownloaded(id: String) {
        guard tabs.first(where: { $0.id == id })?.placement == .temporary else { return }
        closeTab(id: id, forceClose: true, registersUndo: false, reason: .structuralRemoval)
    }

    func handleClosedTab(id: String) {
        engineProfilePathsByID[id] = nil
        if discardedRemoteTabCreationIDs.contains(id) {
            return
        }
        handleMediaStateChange(tabID: id, state: nil)
        crashedTabErrorCodes.removeValue(forKey: id)
        tabsNeedingReloadAfterCrash.remove(id)
        closingTabIDs.remove(id)
        tabsLeavingSidebar.remove(id)
        let closedTab = tabs.first { $0.id == id }
        // An already-removed or unknown identity has no model change to save.
        // Duplicate close receipts must not echo a finished remote projection.
        if closedTab == nil {
            return
        }
        if closedAppTabIDs.contains(id), closedTab?.placement == .app {
            updateWindowTitle()
            return
        }

        if closedPinnedTabIDs.contains(id), closedTab?.placement == .spacePinned {
            updateWindowTitle()
            return
        }

        if closedTab != nil {
            tabs.removeAll { $0.id == id }
        }
        closedAppTabIDs.remove(id)
        closedPinnedTabIDs.remove(id)
        removeTabFromSwitcherTracking(id)
        if let closedTab {
            clearSelectedTab(id, forSpaceID: closedTab.spaceID)
        }

        if selectedTabID == id {
            selectedTabID = fallbackTabID(afterClosingTab: closedTab) ?? sidebarTabsForSelectedSpace().first?.id
            if let fallback = selectedTabID,
               closedPinnedTabIDs.contains(fallback) || closedAppTabIDs.contains(fallback)
            {
                // An unloaded fallback loads like a click instead of showing a blank page.
                selectedTabID = nil
                if isPageInAnotherWindow(fallback) {
                    tabDriver.deselectActiveTab()
                } else {
                    selectTab(id: fallback)
                }
            } else if let selectedTabID {
                tabDriver.selectTab(withID: selectedTabID)
                scheduleSelectedTabWebAppManifestLoad()
                setSelectedTabID(selectedTabID, forSpaceID: selectedSpaceID)
                recordSelectedTab(selectedTabID)
            } else {
                tabDriver.deselectActiveTab()
            }
        }

        if tabs.isEmpty, selectedTabID == nil {
            selectedTabID = nil

            if isShuttingDown {
                allTabsClosedHandler()
            }
        }

        updateWindowTitle()
        persistCurrentSessionIfAllowed()
    }

    func handleNavigationStateChange(id: String, canGoBack: Bool, canGoForward: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        updateTab(at: index) {
            $0.canGoBack = canGoBack
            $0.canGoForward = canGoForward
        }
    }

    /// Writes a tab back only when it changed: each write publishes the whole model,
    /// and the engine repeats unchanged states, many per tab while a session loads.
    private func updateTab(at index: Int, _ change: (inout Tab) -> Void) {
        var tab = tabs[index]
        change(&tab)
        if tab != tabs[index] {
            tabs[index] = tab
        }
    }

    func handleTabCreationStateChange(id: String, state: BrowserTabCreationState) {
        if isShuttingDown {
            // The driver acknowledges ready after this callback. Closing the
            // record first keeps that ACK from enabling its initial load.
            // Pending remote records may not have a logical tab yet.
            if state == .ready {
                tabDriver.closeTab(withID: id, forceClose: true)
            }
            return
        }
        guard !closingTabIDs.contains(id) || pendingTabCloseRequests[id] != nil,
              !closedAppTabIDs.contains(id), !closedPinnedTabIDs.contains(id),
              let index = tabs.firstIndex(where: { $0.id == id })
        else { return }

        switch (tabs[index].creationState, state) {
        case (.creating, .failed),
             (.creating, .ready),
             (.failed, .creating):
            break
        default:
            // Duplicates and obsolete outcomes cannot regress an attached page
            // or revive a refused attempt. Only explicit Retry starts another.
            return
        }
        updateTab(at: index) { tab in
            tab.creationState = state
            if state == .ready {
                tab.hasPendingLocalNavigation = false
            }
            if state == .failed {
                tab.isLoading = false
                tab.canGoBack = false
                tab.canGoForward = false
            }
        }
        if state == .ready, mutedTabSyncIDs.contains(tabs[index].syncID) {
            tabDriver.setAudioMuted(true, forTabWithID: id)
        }
    }

    func handleLoadingStateChange(id: String, isLoading: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return
        }

        if isLoading {
            // A crashed page that loads again is back.
            crashedTabErrorCodes.removeValue(forKey: id)
            tabsNeedingReloadAfterCrash.remove(id)
        }
        updateTab(at: index) { $0.isLoading = isLoading }
        guard id == selectedTabID else {
            return
        }

        if isLoading {
            invalidateSelectedTabWebAppInstallMetadata()
        } else {
            scheduleSelectedTabWebAppManifestLoad()
        }
    }

    private func invalidateSelectedTabWebAppInstallMetadata() {
        webAppManifestLoadTask?.cancel()
        webAppManifestLoadTask = nil
        selectedTabWebAppInstallMetadata = nil
    }

    private func scheduleSelectedTabWebAppManifestLoad() {
        invalidateSelectedTabWebAppInstallMetadata()
        guard
            isContextReady,
            !windowMode.isIncognito,
            !windowMode.isWebApp,
            let tab = selectedTab,
            !tab.isLoading,
            let pageURL = tab.pageURL
        else {
            return
        }

        let tabID = tab.id
        let fallbackTitle = tab.displayTitle
        let fallbackIconURL = tab.faviconURL
        webAppManifestLoadTask = Task { [weak self] in
            guard let self else {
                return
            }

            let payloadJSON = await tabDriver.requestActiveTabWebAppManifest()
            guard !Task.isCancelled else {
                return
            }

            let metadata = BrowserWebAppManifestParser.installMetadata(
                payloadJSON: payloadJSON,
                fallbackPageURL: pageURL,
                fallbackTitle: fallbackTitle,
                fallbackIconURL: fallbackIconURL,
            )
            guard
                metadata.manifestURL != nil,
                selectedTabID == tabID,
                selectedTab?.pageURL == pageURL
            else {
                return
            }

            selectedTabWebAppInstallMetadata = metadata
        }
    }

    @discardableResult func touchTab(id: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let updated = advancedActivityDate(after: tabs[index].lastActivityAt)
        guard updated != tabs[index].lastActivityAt else { return false }
        tabs[index].lastActivityAt = updated
        return true
    }

    func ensureDefaultSpace() {
        guard spaces.isEmpty else {
            if selectedSpaceID == nil {
                selectedSpaceID = spaces.first?.id
            }
            return
        }

        let defaultSpace = makeDefaultSpace()
        spaces = [defaultSpace]
        selectedSpaceID = defaultSpace.id
    }

    func makeDefaultSpace(id: String = BrowserChromeModel.defaultSpaceID) -> Space {
        Space(
            id: id,
            title: defaultSpaceTitle(forDisplayIndex: 1),
            systemImageName: Self.defaultSpaceIconName,
            isPinnedSectionCollapsed: false,
            selectedTabID: nil,
        )
    }

    func makeSpace() -> Space {
        Space(
            id: uniqueSpaceID(),
            title: defaultSpaceTitle(forDisplayIndex: spaces.count + 1),
            systemImageName: Self.defaultSpaceIconName,
            isPinnedSectionCollapsed: false,
            selectedTabID: nil,
        )
    }

    func uniqueSpaceID() -> String {
        var id = spaceIDProvider()
        while spaces.contains(where: { $0.id == id }) {
            id = spaceIDProvider()
        }
        return id
    }

    func restoredSpaces(from snapshot: BrowserTabSessionSnapshot) -> [Space] {
        guard let spaceSnapshots = snapshot.spaces, !spaceSnapshots.isEmpty else {
            return [makeDefaultSpace()]
        }

        var seenIDs = Set<String>()
        return spaceSnapshots.enumerated().compactMap { index, snapshot -> Space? in
            let id = snapshot.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seenIDs.contains(id) else {
                return nil
            }

            seenIDs.insert(id)
            return Space(
                id: id,
                title: sanitizedSpaceTitle(from: snapshot.title) ?? defaultSpaceTitle(forDisplayIndex: index + 1),
                systemImageName: snapshot.systemImageName.isEmpty
                    ? Self.defaultSpaceIconName
                    : snapshot
                        .systemImageName,
                isPinnedSectionCollapsed: snapshot.isPinnedSectionCollapsed,
                selectedTabID: nil,
            )
        }
    }

    func restoredPinnedTabFolders(from snapshot: BrowserTabSessionSnapshot) -> [PinnedTabFolder] {
        guard let folderSnapshots = snapshot.pinnedTabFolders, !folderSnapshots.isEmpty else {
            return []
        }

        let validSpaceIDs = Set(spaces.map(\.id))
        let validFolderSpaceIDsByID = folderSnapshots.reduce(into: [String: String]()) { result, snapshot in
            result[snapshot.id] = result[snapshot.id] ?? snapshot.spaceID
        }
        var seenIDs = Set<String>()
        return folderSnapshots.compactMap { snapshot -> PinnedTabFolder? in
            let id = snapshot.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seenIDs.contains(id), validSpaceIDs.contains(snapshot.spaceID) else {
                return nil
            }

            let parentFolderID: String? =
                if let snapshotParentFolderID = snapshot.parentFolderID,
                snapshotParentFolderID != id,
                validFolderSpaceIDsByID[snapshotParentFolderID] == snapshot.spaceID {
                    snapshotParentFolderID
                } else {
                    nil
                }
            seenIDs.insert(id)
            return PinnedTabFolder(
                id: id,
                spaceID: snapshot.spaceID,
                parentFolderID: parentFolderID,
                title: sanitizedPinnedTabFolderTitle(from: snapshot.title)
                    ?? BrowserStrings.pinnedTabFolderDefaultTitle,
                systemImageName: snapshot.systemImageName,
                isExpanded: snapshot.isExpanded,
                pinnedSiblingRank: snapshot.pinnedSiblingRank,
            )
        }
    }

    func restoreSelectedTabsForSpaces() {
        for index in spaces.indices {
            let spaceID = spaces[index].id
            let visibleTabs = sidebarTabs(forSpaceID: spaceID)
            let selectedIndex = pendingRestoredSpaces.first { $0.id == spaceID }?.selectedTabIndex

            spaces[index].selectedTabID =
                if
                    let selectedIndex,
                    visibleTabs.indices.contains(selectedIndex)
                {
                    visibleTabs[selectedIndex].id
                } else if
                    spaceID == selectedSpaceID,
                    let legacySelectedTabIndex = pendingRestoredSelectedTabIndex,
                    tabs.indices.contains(legacySelectedTabIndex),
                    tabs[legacySelectedTabIndex].spaceID == spaceID
                {
                    tabs[legacySelectedTabIndex].id
                } else {
                    visibleTabs.first?.id
                }
        }
    }

    func selectActiveTabForSelectedSpace() {
        guard let selectedSpaceID else {
            captureSelectedTabPreviewIfNeeded()
            selectedTabID = nil
            tabDriver.deselectActiveTab()
            updateWindowTitle()
            return
        }

        let selectedTabIDForSpace = spaces.first { $0.id == selectedSpaceID }?.selectedTabID
        let candidate = selectedTabIDForSpace.flatMap { tabID -> String? in
            guard tabs.contains(where: { $0.id == tabID && $0.spaceID == selectedSpaceID }) else {
                return nil
            }
            return tabID
        } ?? sidebarTabs(forSpaceID: selectedSpaceID).first { !hasNoPage($0.id) }?.id
        // An unloaded tab has no page to show: the Space's remembered tab loads
        // through the same path as a click. A Space without a remembered tab or
        // an open page stays empty.
        if let candidate, hasNoPage(candidate), !isApplyingRemoteSync, !isReconcilingRemoteProjection,
           !(isAdditionalWindow && isRestoringSession), !isPageInAnotherWindow(candidate)
        {
            selectTab(id: candidate)
            if let selectedTabID, tabs.first(where: { $0.id == selectedTabID })?.spaceID == selectedSpaceID {
                return
            }
        }
        // A tab whose page is in another window stays there until it is clicked.
        let fallbackTabID = windowGroup != nil && candidate.map(hasNoPage) == true ? nil : candidate

        if selectedTabID != fallbackTabID {
            captureSelectedTabPreviewIfNeeded()
        }
        selectedTabID = fallbackTabID
        findResultMatchCount = nil

        if let fallbackTabID {
            setSelectedTabID(fallbackTabID, forSpaceID: selectedSpaceID)
            tabDriver.selectTab(withID: fallbackTabID)
            recordSelectedTab(fallbackTabID)
            runFind(forward: true, findNext: false)
        } else {
            tabDriver.deselectActiveTab()
        }

        updateWindowTitle()
    }

    func selectAdjacentSpace(offset: Int) {
        guard
            spaces.count > 1,
            let selectedSpaceIndex
        else {
            return
        }

        let nextIndex = (selectedSpaceIndex + offset + spaces.count) % spaces.count
        selectSpace(id: spaces[nextIndex].id)
    }

    func fallbackSpaceID(afterDeletingSpaceAt index: Int) -> String? {
        guard spaces.count > 1 else {
            return nil
        }

        let fallbackIndex = index < spaces.count - 1 ? index + 1 : index - 1
        return spaces[fallbackIndex].id
    }

    func setSelectedTabID(_ tabID: String?, forSpaceID spaceID: String?) {
        guard
            let spaceID,
            let index = spaces.firstIndex(where: { $0.id == spaceID })
        else {
            return
        }

        spaces[index].selectedTabID = tabID
    }

    func clearSelectedTab(_ tabID: String, forSpaceID spaceID: String) {
        guard
            let index = spaces.firstIndex(where: { $0.id == spaceID }),
            spaces[index].selectedTabID == tabID
        else {
            return
        }

        spaces[index].selectedTabID = nil
    }

    func sidebarTabsForSelectedSpace() -> [Tab] {
        guard let selectedSpaceID else {
            return []
        }

        return sidebarTabs(forSpaceID: selectedSpaceID)
    }

    func sidebarTabs(forSpaceID spaceID: String, including extraTab: Tab? = nil) -> [Tab] {
        var spaceTabs = tabs.filter { $0.spaceID == spaceID && $0.placement != .app }
        if let extraTab, !spaceTabs.contains(where: { $0.id == extraTab.id }) {
            spaceTabs.append(extraTab)
        }

        return spaceTabs
            .filter { $0.placement == .spacePinned }
            + spaceTabs.filter { $0.placement == .temporary }
    }

    func selectedTabIndex(inSpace spaceID: String) -> Int? {
        guard
            let selectedTabID = spaces.first(where: { $0.id == spaceID })?.selectedTabID,
            let index = sidebarTabs(forSpaceID: spaceID).firstIndex(where: { $0.id == selectedTabID })
        else {
            return nil
        }

        return index
    }

    func defaultSpaceTitle(forDisplayIndex displayIndex: Int) -> String {
        BrowserStrings.defaultSpaceTitle(index: displayIndex)
    }

    func sanitizedSpaceTitle(from title: String?) -> String? {
        guard let title else {
            return nil
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }
}

@MainActor extension BrowserChromeModel {
    func reorderedTabs(
        movingTabID: String,
        toPlacement placement: BrowserTabPlacement,
        requestedSectionIndex: Int,
        targetSpaceID: String? = nil,
        targetPinnedFolderID: String? = nil,
    ) -> [Tab]? {
        guard supportsAppTabs || placement != .app,
              let movingTab = tabs.first(where: { $0.id == movingTabID })
        else {
            return nil
        }

        if targetSpaceID == nil, movingTab.placement != .app, movingTab.spaceID != selectedSpaceID {
            return nil
        }

        let targetFolder = targetPinnedFolderID.flatMap { folderID in
            pinnedTabFolders.first { $0.id == folderID }
        }
        guard targetPinnedFolderID == nil || targetFolder != nil else {
            return nil
        }

        let resolvedTargetSpaceID = targetFolder?.spaceID ?? targetSpaceID ?? selectedSpaceID ?? movingTab.spaceID
        guard placement == .app || spaces.contains(where: { $0.id == resolvedTargetSpaceID }),
              targetFolder == nil || placement == .spacePinned, canMoveTab(
                  movingTab,
                  to: placement,
              )
        else {
            return nil
        }

        let movingWithinTargetSection = movingTab.placement == placement
            && (placement == .app || movingTab.spaceID == resolvedTargetSpaceID)
        let sourceSectionTabs = tabs(
            for: movingTab.placement,
            inSpaceID: movingTab.placement == .app ? nil : movingTab.spaceID,
        )
        let sourceSectionIndex = sourceSectionTabs.firstIndex(where: { $0.id == movingTabID })

        var updatedAppTabs = appTabs.filter { $0.id != movingTabID }
        var updatedSpacePinnedTabsBySpaceID = tabsBySpaceID(for: .spacePinned, removingTabID: movingTabID)
        var updatedTemporaryTabsBySpaceID = tabsBySpaceID(for: .temporary, removingTabID: movingTabID)
        var updatedTab = movingTab
        updatedTab.placement = placement
        if placement != .app {
            updatedTab.spaceID = resolvedTargetSpaceID
        }
        updatedTab.pinnedURLString = pinnedURLString(for: movingTab, movingTo: placement)
        updatedTab.pinnedFolderID = placement == .spacePinned ? targetPinnedFolderID : nil

        switch placement {
        case .app:
            let destinationIndex = adjustedSectionIndex(
                requestedSectionIndex,
                movingWithinTargetSection: movingWithinTargetSection,
                sourceSectionIndex: sourceSectionIndex,
                sectionCount: updatedAppTabs.count,
            )
            updatedAppTabs.insert(updatedTab, at: destinationIndex)
        case .spacePinned:
            var updatedSpacePinnedTabs = updatedSpacePinnedTabsBySpaceID[resolvedTargetSpaceID] ?? []
            let destinationIndex =
                if let targetPinnedFolderID {
                    pinnedFolderChildInsertionIndex(
                        requestedSectionIndex,
                        in: updatedSpacePinnedTabs,
                        folderID: targetPinnedFolderID,
                    )
                } else {
                    adjustedSectionIndex(
                        requestedSectionIndex,
                        movingWithinTargetSection: movingWithinTargetSection,
                        sourceSectionIndex: sourceSectionIndex,
                        sectionCount: updatedSpacePinnedTabs.count,
                    )
                }
            updatedSpacePinnedTabs.insert(updatedTab, at: destinationIndex)
            updatedSpacePinnedTabsBySpaceID[resolvedTargetSpaceID] = updatedSpacePinnedTabs
        case .temporary:
            var updatedTemporaryTabs = updatedTemporaryTabsBySpaceID[resolvedTargetSpaceID] ?? []
            let destinationIndex = adjustedSectionIndex(
                requestedSectionIndex,
                movingWithinTargetSection: movingWithinTargetSection,
                sourceSectionIndex: sourceSectionIndex,
                sectionCount: updatedTemporaryTabs.count,
            )
            updatedTemporaryTabs.insert(updatedTab, at: destinationIndex)
            updatedTemporaryTabsBySpaceID[resolvedTargetSpaceID] = updatedTemporaryTabs
        }

        return tabsByReplacingTabs(
            spacePinnedTabsBySpaceID: updatedSpacePinnedTabsBySpaceID,
            temporaryTabsBySpaceID: updatedTemporaryTabsBySpaceID,
            appTabs: updatedAppTabs,
        )
    }

    func reorderedTabs(
        movingTabIDs tabIDs: Set<String>,
        toPlacement placement: BrowserTabPlacement,
        requestedSectionIndex: Int,
        targetSpaceID: String? = nil,
        targetPinnedFolderID: String? = nil,
    ) -> [Tab]? {
        guard placement == .spacePinned else {
            return nil
        }

        let movingTabIDs = Set(tabIDs)
        let movingTabs = tabs.filter { movingTabIDs.contains($0.id) }
        guard movingTabs.count == movingTabIDs.count, movingTabs.count > 1 else {
            return nil
        }

        if targetSpaceID == nil,
           movingTabs.contains(where: { $0.placement != .app && $0.spaceID != selectedSpaceID })
        {
            return nil
        }

        let targetFolder = targetPinnedFolderID.flatMap { folderID in
            pinnedTabFolders.first { $0.id == folderID }
        }
        guard targetPinnedFolderID == nil || targetFolder != nil else {
            return nil
        }

        let resolvedTargetSpaceID = targetFolder?.spaceID ?? targetSpaceID ?? selectedSpaceID ?? movingTabs[0].spaceID
        guard spaces.contains(where: { $0.id == resolvedTargetSpaceID }), movingTabs.allSatisfy({ canMoveTab(
            $0,
            to: placement,
        ) }) else {
            return nil
        }

        let movingWithinTargetSection = movingTabs.allSatisfy {
            $0.placement == placement && $0.spaceID == resolvedTargetSpaceID
        }
        let sourceSectionTabs = tabs(for: placement, inSpaceID: resolvedTargetSpaceID)
        let sourceSectionIndices = sourceSectionTabs.enumerated().compactMap { index, tab -> Int? in
            movingTabIDs.contains(tab.id) ? index : nil
        }
        let removedBeforeTarget = movingWithinTargetSection
            ? sourceSectionIndices.count(where: { $0 < requestedSectionIndex })
            : 0

        var updatedSpacePinnedTabsBySpaceID = tabsBySpaceID(for: .spacePinned, removingTabIDs: movingTabIDs)
        var targetPinnedTabs = updatedSpacePinnedTabsBySpaceID[resolvedTargetSpaceID] ?? []
        let destinationIndex =
            if let targetPinnedFolderID {
                pinnedFolderChildInsertionIndex(
                    requestedSectionIndex,
                    in: targetPinnedTabs,
                    folderID: targetPinnedFolderID,
                )
            } else {
                min(max(requestedSectionIndex - removedBeforeTarget, 0), targetPinnedTabs.count)
            }
        let movedTabs = movingTabs.map { tab in
            var updatedTab = tab
            updatedTab.spaceID = resolvedTargetSpaceID
            updatedTab.placement = placement
            updatedTab.pinnedURLString = pinnedURLString(for: tab, movingTo: placement)
            updatedTab.pinnedFolderID = targetPinnedFolderID
            return updatedTab
        }
        targetPinnedTabs.insert(contentsOf: movedTabs, at: destinationIndex)
        updatedSpacePinnedTabsBySpaceID[resolvedTargetSpaceID] = targetPinnedTabs

        return tabsByReplacingTabs(
            spacePinnedTabsBySpaceID: updatedSpacePinnedTabsBySpaceID,
            temporaryTabsBySpaceID: tabsBySpaceID(for: .temporary, removingTabIDs: movingTabIDs),
            appTabs: appTabs.filter { !movingTabIDs.contains($0.id) },
        )
    }
}

@MainActor private extension BrowserChromeModel {
    func tabSwitcherEntries() -> [TabSwitcherEntry] {
        pruneTabSwitcherTracking()

        guard
            let selectedTabID,
            tabs.contains(where: { $0.id == selectedTabID }),
            !blocksTabInteraction(selectedTabID),
            !closedAppTabIDs.contains(selectedTabID),
            !closedPinnedTabIDs.contains(selectedTabID)
        else {
            return []
        }

        var seenTabIDs = Set<String>()
        var orderedTabIDs = [String]()

        func appendTabID(_ tabID: String) {
            guard
                !blocksTabInteraction(tabID),
                !closedAppTabIDs.contains(tabID),
                !closedPinnedTabIDs.contains(tabID),
                seenTabIDs.insert(tabID).inserted
            else {
                return
            }

            // A Split View is one card: its other panes are not listed again.
            seenTabIDs.formUnion(splitPaneTabIDs(forTabID: tabID))
            orderedTabIDs.append(tabID)
        }

        appendTabID(selectedTabID)
        recentlySelectedTabIDs.forEach(appendTabID)

        let fallbackTabs = tabs
            .filter {
                !seenTabIDs.contains($0.id)
                    && !blocksTabInteraction($0.id)
                    && !closedAppTabIDs.contains($0.id)
                    && !closedPinnedTabIDs.contains($0.id)
            }
            .sorted { lhs, rhs in
                lhs.lastActivityAt > rhs.lastActivityAt
            }
        fallbackTabs.map(\.id).forEach(appendTabID)

        return orderedTabIDs
            .compactMap { tabID in
                tabs.first { $0.id == tabID }
            }
            .prefix(Self.tabSwitcherMaximumEntries)
            .map { tab in
                let panes = splitPaneTabIDs(forTabID: tab.id)
                return TabSwitcherEntry(
                    tab: tab,
                    previewImage: tabPreviewImagesByID[tab.id],
                    splitPanes: panes.count > 1
                        ? panes.compactMap { id in
                            tabs.first { $0.id == id }.map { ($0, tabPreviewImagesByID[id]) }
                        }
                        : [],
                )
            }
    }

    func scheduleTabSwitcherPresentation() {
        tabSwitcherPresentationTask?.cancel()

        let sessionID = UUID()
        tabSwitcherSessionID = sessionID
        tabSwitcherPresentationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.tabSwitcherPresentationDelayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.presentTabSwitcher(sessionID: sessionID)
        }
    }

    func presentTabSwitcher(sessionID: UUID) {
        guard tabSwitcherSessionID == sessionID, var state = tabSwitcherState else {
            return
        }

        state.isVisible = true
        tabSwitcherState = state
    }

    func clearTabSwitcherState() {
        tabSwitcherPresentationTask?.cancel()
        tabSwitcherPresentationTask = nil
        tabSwitcherSessionID = UUID()
        tabSwitcherState = nil
    }

    func recordSelectedTab(_ tabID: String?) {
        guard
            let tabID,
            tabs.contains(where: { $0.id == tabID }),
            !blocksTabInteraction(tabID),
            !closedPinnedTabIDs.contains(tabID)
        else {
            return
        }

        recentlySelectedTabIDs.removeAll { $0 == tabID }
        recentlySelectedTabIDs.insert(tabID, at: 0)
        pruneTabSwitcherTracking()
    }

    func removeTabFromSwitcherTracking(_ tabID: String) {
        recentlySelectedTabIDs.removeAll { $0 == tabID }
        tabPreviewImagesByID.removeValue(forKey: tabID)

        guard var state = tabSwitcherState else {
            return
        }

        state.entries.removeAll { $0.id == tabID }
        if state.entries.isEmpty {
            clearTabSwitcherState()
        } else if !state.entries.contains(where: { $0.id == state.selectedTabID }) {
            state.selectedTabID = state.entries.first?.id ?? state.selectedTabID
            tabSwitcherState = state
        }
    }

    func pruneTabSwitcherTracking() {
        let openTabIDs = Set(tabs.map(\.id))
            .subtracting(closingTabIDs.filter { blocksTabInteraction($0) })
            .subtracting(closedAppTabIDs)
            .subtracting(closedPinnedTabIDs)
        recentlySelectedTabIDs.removeAll { !openTabIDs.contains($0) }

        for tabID in Array(tabPreviewImagesByID.keys) where !openTabIDs.contains(tabID) {
            tabPreviewImagesByID.removeValue(forKey: tabID)
        }
        let rowIDs = Set(tabs.map(\.id))
        if !movedPageTabIDs.isSubset(of: rowIDs) {
            movedPageTabIDs.formIntersection(rowIDs)
            movedPagePictures = movedPagePictures.filter { rowIDs.contains($0.key) }
        }
    }

    func captureSelectedTabPreviewIfNeeded() {
        guard
            let selectedTabID,
            !blocksTabInteraction(selectedTabID),
            !closedAppTabIDs.contains(selectedTabID),
            !closedPinnedTabIDs.contains(selectedTabID),
            let previewImage = BrowserTabPreviewCapture.image(for: hostView)
        else {
            return
        }

        tabPreviewImagesByID[selectedTabID] = previewImage
    }

    func tabCount(for placement: BrowserTabPlacement) -> Int {
        tabs(for: placement).count
    }

    func tabs(for placement: BrowserTabPlacement) -> [Tab] {
        tabs(for: placement, inSpaceID: selectedSpaceID)
    }

    func tabs(for placement: BrowserTabPlacement, inSpaceID spaceID: String?) -> [Tab] {
        switch placement {
        case .app:
            appTabs
        case .spacePinned:
            tabs.filter { $0.spaceID == spaceID && $0.placement == .spacePinned }
        case .temporary:
            tabs.filter { $0.spaceID == spaceID && $0.placement == .temporary }
        }
    }

    func canMoveTab(_ tab: Tab, to placement: BrowserTabPlacement) -> Bool {
        guard supportsAppTabs || placement != .app else {
            return false
        }

        guard placement == .app, tab.placement != .app else {
            return true
        }

        return appTabs.count < Self.appTabCapacity
    }

    func tabsBySpaceID(
        for placement: BrowserTabPlacement,
        removingTabID tabID: String,
    ) -> [String: [Tab]] {
        tabsBySpaceID(for: placement, removingTabIDs: [tabID])
    }

    func tabsBySpaceID(
        for placement: BrowserTabPlacement,
        removingTabIDs tabIDs: Set<String>,
    ) -> [String: [Tab]] {
        spaces.reduce(into: [:]) { result, space in
            result[space.id] = tabs(for: placement, inSpaceID: space.id)
                .filter { !tabIDs.contains($0.id) }
        }
    }

    func tabsBySpaceID(
        replacing replacementTabs: [Tab],
        for placement: BrowserTabPlacement,
        inSpaceID spaceID: String,
    ) -> [String: [Tab]] {
        var result = tabsBySpaceID(for: placement, removingTabIDs: [])
        result[spaceID] = replacementTabs
        return result
    }

    func tabsByReplacingTabs(
        spacePinnedTabsBySpaceID: [String: [Tab]],
        temporaryTabsBySpaceID: [String: [Tab]],
        appTabs: [Tab],
    ) -> [Tab] {
        var result = appTabs
        for space in spaces {
            result.append(contentsOf: spacePinnedTabsBySpaceID[space.id] ?? [])
            result.append(contentsOf: temporaryTabsBySpaceID[space.id] ?? [])
        }

        let knownSpaceIDs = Set(spaces.map(\.id))
        result.append(contentsOf: tabs.filter { !knownSpaceIDs.contains($0.spaceID) && $0.placement != .app })
        return result
    }

    func adjustedSectionIndex(
        _ requestedSectionIndex: Int,
        movingWithinTargetSection: Bool,
        sourceSectionIndex: Int?,
        sectionCount: Int,
    ) -> Int {
        var adjustedSectionIndex = max(requestedSectionIndex, 0)

        if
            movingWithinTargetSection,
            let sourceSectionIndex,
            sourceSectionIndex < adjustedSectionIndex
        {
            adjustedSectionIndex -= 1
        }

        return min(max(adjustedSectionIndex, 0), sectionCount)
    }

    func pinnedFolderChildInsertionIndex(
        _ requestedChildIndex: Int,
        in pinnedTabs: [Tab],
        folderID: String,
    ) -> Int {
        let childIndices = pinnedTabs.indices.filter { pinnedTabs[$0].pinnedFolderID == folderID }
        guard !childIndices.isEmpty else {
            return pinnedTabs.count
        }

        let clampedChildIndex = min(max(requestedChildIndex, 0), childIndices.count)
        if clampedChildIndex < childIndices.count {
            return childIndices[clampedChildIndex]
        }

        return childIndices[childIndices.count - 1] + 1
    }

    func descendantPinnedTabFolderIDs(including folderID: String) -> Set<String> {
        var result = Set<String>()

        func appendDescendants(of folderID: String) {
            guard !result.contains(folderID) else {
                return
            }

            result.insert(folderID)
            for childFolder in pinnedTabFolders where childFolder.parentFolderID == folderID {
                appendDescendants(of: childFolder.id)
            }
        }

        appendDescendants(of: folderID)
        return result
    }

    func uniquePinnedTabFolderID() -> String {
        var id = UUID().uuidString
        while pinnedTabFolders.contains(where: { $0.id == id }) {
            id = UUID().uuidString
        }
        return id
    }

    func removeInvalidPinnedTabFolderAssignments() {
        let folderSpaceIDsByID = Dictionary(uniqueKeysWithValues: pinnedTabFolders.map { ($0.id, $0.spaceID) })
        for index in pinnedTabFolders.indices {
            guard let parentFolderID = pinnedTabFolders[index].parentFolderID else {
                continue
            }

            guard parentFolderID != pinnedTabFolders[index].id,
                  folderSpaceIDsByID[parentFolderID] == pinnedTabFolders[index].spaceID,
                  !descendantPinnedTabFolderIDs(including: pinnedTabFolders[index].id).contains(parentFolderID)
            else {
                pinnedTabFolders[index].parentFolderID = nil
                continue
            }
        }

        // One write for all tabs, and none when every tab is already valid.
        var checkedTabs = tabs
        for index in checkedTabs.indices {
            checkedTabs[index].pinnedURLString =
                if checkedTabs[index].placement == .spacePinned {
                    effectivePinnedURLString(forPinnedTab: checkedTabs[index])
                } else {
                    nil
                }

            guard let folderID = checkedTabs[index].pinnedFolderID else {
                continue
            }

            guard
                checkedTabs[index].placement == .spacePinned,
                folderSpaceIDsByID[folderID] == checkedTabs[index].spaceID
            else {
                checkedTabs[index].pinnedFolderID = nil
                continue
            }
        }
        if checkedTabs != tabs {
            tabs = checkedTabs
        }
    }

    func sanitizedPinnedTabFolderTitle(from title: String?) -> String? {
        guard let title else {
            return nil
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? nil : trimmedTitle
    }

    func lastActivityDate(from snapshotTab: BrowserTabSessionSnapshotTab) -> Date? {
        guard let lastActivityTimestamp = snapshotTab.lastActivityTimestamp else {
            return nil
        }

        return Date(timeIntervalSince1970: lastActivityTimestamp)
    }
}

// MARK: - Command Bar Actions

extension BrowserCommandID {
    /// Pane position of a Switch to Split Pane command, counted from 0.
    var splitPaneIndex: Int {
        switch self {
        case .focusSplitPane2: 1
        case .focusSplitPane3: 2
        case .focusSplitPane4: 3
        default: 0
        }
    }

    var commandBarSearchAliases: [String] {
        switch self {
        case .openSettings:
            ["settings", "preferences", "app settings", "native settings"]
        case .setAsDefaultBrowser:
            ["default browser", "set default browser", "make default browser"]
        case .newTab:
            ["new tab", "open tab", "create tab"]
        case .openLocation:
            ["open location", "edit url", "edit address", "current url", "address bar"]
        case .restoreLastClosedTab:
            ["restore tab", "reopen tab", "reopen closed tab", "last closed tab", "undo close tab"]
        case .zoomIn:
            ["zoom in", "bigger", "larger text"]
        case .zoomOut:
            ["zoom out", "smaller", "smaller text"]
        case .resetZoom:
            ["actual size", "reset zoom", "zoom 100"]
        case .stopLoading:
            ["stop", "stop loading"]
        case .inspectElements:
            ["inspect", "inspect elements", "element picker"]
        case .javaScriptConsole:
            ["console", "javascript console", "js console"]
        case .manageSpaces:
            ["manage spaces", "spaces"]
        case .translatePage:
            ["translate", "translate page"]
        case .addBottomSplit:
            ["add bottom split", "split bottom"]
        case .addTopSplit:
            ["add top split", "split top"]
        case .addRightSplit:
            ["add right split", "split right"]
        case .addLeftSplit:
            ["add left split", "split left"]
        case .capturePortrait:
            ["portrait", "capture in portrait mode", "screenshot"]
        case .blankWindow:
            ["blank window", "new window"]
        case .viewMedia:
            ["media", "view media", "images"]
        case .networkInspector:
            ["network", "network inspector", "requests"]
        case .toggleDeveloperMode:
            ["developer mode", "dev mode", "developer"]
        case .editSpaceTheme:
            ["theme", "edit theme", "color"]
        case .togglePictureInPicture:
            ["picture in picture", "pip", "floating video"]
        case .muteAllTabs:
            ["mute all tabs", "silence", "sound off"]
        case .unmuteAllTabs:
            ["unmute all tabs", "sound on"]
        case .shareTab:
            ["share", "share page", "share tab"]
        case .developerTools:
            ["developer tools", "devtools", "inspect", "web inspector", "console"]
        case .viewSource:
            ["view source", "page source", "source code", "html"]
        case .newWindow:
            ["new window", "open window"]
        case .newIncognitoWindow:
            ["incognito", "private window", "new private window"]
        case .newLittleWindow:
            ["small window", "mini window", "new little window"]
        case .openHistory:
            ["history", "open history", "browser history"]
        case .toggleBookmark:
            ["bookmark", "add bookmark", "remove bookmark", "star"]
        case .archiveTab:
            ["archive tab", "close tab", "close current tab"]
        case .viewArchive:
            ["view archive", "open archive", "archived tabs", "restore closed tabs"]
        case .clearArchive:
            ["clear archive", "empty archive", "delete archived tabs"]
        case .savePage:
            ["save page", "save as", "download page"]
        case .printPage:
            ["print page", "print current page"]
        case .copyLink:
            ["copy link", "copy url", "copy address", "copy current url"]
        case .copyLinkAsMarkdown:
            ["copy markdown", "markdown link", "copy url as markdown", "copy link as markdown"]
        case .copyLinkAsQuote:
            ["copy quote", "quote link", "copy url as quote", "link to highlight", "link to text"]
        case .findInPage:
            ["find", "find in page", "search page"]
        case .findAndReplace:
            ["find replace", "find and replace", "replace"]
        case .findNext:
            ["find next", "next match", "next result"]
        case .findPrevious:
            ["find previous", "previous match", "previous result"]
        case .jumpToSelection:
            ["jump selection", "jump to selection"]
        case .clearTemporaryTabs:
            ["clear temporary tabs", "clear temp tabs", "temporary tabs"]
        case .viewDownloads:
            ["downloads", "view downloads", "show downloads", "downloaded files"]
        case .viewLibrary:
            ["library", "media", "view library", "manage spaces"]
        case .togglePinTab:
            ["pin tab", "unpin tab", "pin", "unpin"]
        case .duplicateTab:
            ["duplicate tab", "duplicate", "copy tab"]
        case .renameTab:
            ["rename tab", "rename"]
        case .resetTabToPinnedURL:
            ["reset tab", "original url", "pinned url", "back to pinned url"]
        case .resetSpaceTabs:
            ["reset tabs", "reset all tabs", "reset space", "original urls"]
        case .collapseAllFolders:
            ["collapse folders", "collapse all folders", "close folders"]
        case .expandAllFolders:
            ["expand folders", "expand all folders", "open folders"]
        case .newSpace:
            ["new space", "create space", "add space"]
        case .newFolder:
            ["new folder", "create folder", "folder"]
        case .captureFullPage:
            ["capture", "screenshot", "capture full page", "full page screenshot"]
        case .captureArea:
            ["capture area", "screenshot area", "capture part", "snip"]
        case .selectNextTab:
            ["next tab", "select next tab"]
        case .selectPreviousTab:
            ["previous tab", "select previous tab"]
        case .selectNextTabAlternate,
             .selectPreviousTabAlternate:
            []
        case .revealCurrentTab:
            ["reveal current tab", "reveal tab", "show tab in sidebar", "find tab in sidebar"]
        case .openExtensions:
            ["extensions", "open extensions", "site controls", "control center"]
        case .selectNextSpace:
            ["next space", "switch space"]
        case .selectPreviousSpace:
            ["previous space", "switch space"]
        case .goToSidebarItem1,
             .goToSidebarItem2,
             .goToSidebarItem3,
             .goToSidebarItem4,
             .goToSidebarItem5,
             .goToSidebarItem6,
             .goToSidebarItem7,
             .goToSidebarItem8:
            ["tab \(sidebarItemIndex + 1)", "sidebar item \(sidebarItemIndex + 1)", "go to tab"]
        case .goToLastSidebarItem:
            ["last tab", "last sidebar item"]
        case .goBack:
            ["back", "go back", "previous page"]
        case .goForward:
            ["forward", "go forward", "next page"]
        case .reload:
            ["reload", "refresh", "soft refresh"]
        case .forceReload:
            ["force reload", "force refresh", "hard reload", "hard refresh", "reload ignoring cache", "ignore cache"]
        case .clearCacheAndRefresh:
            ["clear cache", "clear cache refresh", "clear cache and refresh", "empty cache", "empty cache and refresh"]
        case .clearCookiesAndRefresh:
            [
                "clear cookies",
                "clear cookies refresh",
                "clear cookies and refresh",
                "delete cookies",
                "delete cookies and refresh",
            ]
        case .addSplitView:
            ["split view", "add split view", "new split", "split screen", "side by side"]
        case .closeSplitPane:
            ["close split pane", "close pane", "close split"]
        case .separateTabFromSplit:
            ["separate page", "separate tab", "remove from split", "unsplit tab"]
        case .separateSplitView:
            ["separate all tabs", "exit split view", "end split view", "unsplit"]
        case .toggleSplitOrientation:
            ["convert split", "vertical split", "horizontal split", "rotate split", "split orientation"]
        case .focusSplitPane1,
             .focusSplitPane2,
             .focusSplitPane3,
             .focusSplitPane4:
            ["split pane \(splitPaneIndex + 1)", "switch split pane", "focus pane"]
        case .focusNextSplitPane:
            ["next split pane", "next pane"]
        case .expandCurrentSplit:
            ["expand split", "maximize pane", "expand pane", "show all split panes"]
        case .focusPreviousSplitPane:
            ["previous split pane", "previous pane"]
        case .toggleSidebar:
            ["sidebar", "toggle sidebar", "show sidebar", "hide sidebar"]
        case .toggleSidebarPosition:
            ["sidebar right", "sidebar left", "move sidebar", "sidebar position", "right sidebar"]
        case .toggleBookmarksBar:
            ["bookmarks bar", "bookmark bar", "toggle bookmarks bar", "show bookmarks bar", "hide bookmarks bar"]
        case .toggleSiteToolbar:
            ["toolbar", "url bar", "address bar", "show toolbar", "hide toolbar"]
        case .customizeToolbar:
            ["customize toolbar", "edit toolbar", "toolbar buttons", "add button to toolbar"]
        }
    }

    var commandBarSystemImageName: String {
        switch self {
        case .openSettings:
            "gearshape"
        case .setAsDefaultBrowser:
            "globe"
        case .newTab:
            "plus"
        case .openLocation:
            "link"
        case .restoreLastClosedTab:
            "arrow.uturn.backward.circle"
        case .zoomIn:
            "plus.magnifyingglass"
        case .zoomOut:
            "minus.magnifyingglass"
        case .resetZoom:
            "1.magnifyingglass"
        case .stopLoading:
            "xmark"
        case .inspectElements:
            "cursorarrow.rays"
        case .javaScriptConsole:
            "terminal"
        case .manageSpaces:
            "square.on.square"
        case .translatePage:
            "character.book.closed"
        case .addBottomSplit:
            "rectangle.split.1x2"
        case .addTopSplit:
            "rectangle.split.1x2"
        case .addRightSplit:
            "rectangle.split.2x1"
        case .addLeftSplit:
            "rectangle.split.2x1"
        case .capturePortrait:
            "person.crop.rectangle"
        case .blankWindow:
            "macwindow.badge.plus"
        case .viewMedia:
            "photo.on.rectangle"
        case .networkInspector:
            "network"
        case .toggleDeveloperMode:
            "hammer"
        case .editSpaceTheme:
            "paintpalette"
        case .togglePictureInPicture:
            "pip"
        case .muteAllTabs:
            "speaker.slash"
        case .unmuteAllTabs:
            "speaker.wave.2"
        case .shareTab:
            "square.and.arrow.up"
        case .developerTools:
            "hammer"
        case .viewSource:
            "chevron.left.forwardslash.chevron.right"
        case .newWindow:
            "macwindow"
        case .newIncognitoWindow:
            "eye.slash"
        case .newLittleWindow:
            "macwindow.badge.plus"
        case .openHistory:
            "clock.arrow.circlepath"
        case .toggleBookmark:
            "star"
        case .archiveTab,
             .viewArchive:
            "archivebox"
        case .clearArchive:
            "trash"
        case .savePage:
            "square.and.arrow.down"
        case .printPage:
            "printer"
        case .copyLink:
            "link"
        case .copyLinkAsMarkdown:
            "text.badge.plus"
        case .copyLinkAsQuote:
            "text.quote"
        case .findInPage:
            "doc.text.magnifyingglass"
        case .findAndReplace:
            "arrow.triangle.2.circlepath"
        case .findNext:
            "chevron.down"
        case .findPrevious:
            "chevron.up"
        case .jumpToSelection:
            "text.cursor"
        case .clearTemporaryTabs:
            "xmark.circle"
        case .viewDownloads:
            "arrow.down.circle"
        case .viewLibrary:
            "books.vertical"
        case .togglePinTab:
            "pin"
        case .duplicateTab:
            "plus.square.on.square"
        case .renameTab:
            "pencil"
        case .resetTabToPinnedURL:
            "arrow.uturn.backward"
        case .resetSpaceTabs:
            "arrow.counterclockwise"
        case .collapseAllFolders:
            "folder"
        case .expandAllFolders:
            "folder.fill"
        case .newSpace:
            "plus.rectangle.on.rectangle"
        case .newFolder:
            "folder.badge.plus"
        case .captureFullPage:
            "camera.viewfinder"
        case .captureArea:
            "crop"
        case .selectNextTab:
            "arrow.down.square"
        case .selectPreviousTab,
             .selectPreviousTabAlternate:
            "arrow.up.square"
        case .selectNextTabAlternate:
            "arrow.down.square"
        case .revealCurrentTab:
            "scope"
        case .openExtensions:
            "puzzlepiece.extension"
        case .selectNextSpace:
            "arrow.right.square"
        case .selectPreviousSpace:
            "arrow.left.square"
        case .goToSidebarItem1,
             .goToSidebarItem2,
             .goToSidebarItem3,
             .goToSidebarItem4,
             .goToSidebarItem5,
             .goToSidebarItem6,
             .goToSidebarItem7,
             .goToSidebarItem8:
            "\(sidebarItemIndex + 1).circle"
        case .goToLastSidebarItem:
            "9.circle"
        case .goBack:
            "chevron.left"
        case .goForward:
            "chevron.right"
        case .reload:
            "arrow.clockwise"
        case .forceReload:
            "arrow.clockwise.circle"
        case .clearCacheAndRefresh:
            "externaldrive"
        case .clearCookiesAndRefresh:
            "trash"
        case .addSplitView:
            "rectangle.split.2x1"
        case .closeSplitPane:
            "xmark.rectangle"
        case .separateSplitView,
             .separateTabFromSplit:
            "rectangle.on.rectangle"
        case .toggleSplitOrientation:
            "rectangle.split.1x2"
        case .focusSplitPane1,
             .focusSplitPane2,
             .focusSplitPane3,
             .focusSplitPane4:
            "\(splitPaneIndex + 1).square"
        case .focusNextSplitPane:
            "arrow.right.square"
        case .expandCurrentSplit:
            "arrow.up.left.and.arrow.down.right"
        case .focusPreviousSplitPane:
            "arrow.left.square"
        case .toggleSidebar:
            "sidebar.left"
        case .toggleSidebarPosition:
            "sidebar.right"
        case .toggleBookmarksBar:
            "book"
        case .toggleSiteToolbar:
            "menubar.rectangle"
        case .customizeToolbar:
            "slider.horizontal.below.rectangle"
        }
    }
}

extension BrowserKeyboardShortcut {
    var commandBarSearchAliases: [String] {
        guard isAssigned else {
            return []
        }

        let modifierPhrases = commandBarModifierSearchPhrases
        let keyAliases = commandBarKeySearchAliases
        var aliases = [
            displayText,
            keyCaps.joined(separator: " "),
        ]

        for keyAlias in keyAliases {
            for modifierPhrase in modifierPhrases {
                aliases.append("\(modifierPhrase) \(keyAlias)")
                aliases.append("\(modifierPhrase)+\(keyAlias)")
            }
        }

        return aliases
    }

    private var commandBarModifierSearchPhrases: [String] {
        var phrases = [""]

        if modifiers.contains(.control) {
            phrases = phrases.appendingModifierSearchAliases(["control", "ctrl"])
        }

        if modifiers.contains(.option) {
            phrases = phrases.appendingModifierSearchAliases(["option", "alt"])
        }

        if modifiers.contains(.shift) {
            phrases = phrases.appendingModifierSearchAliases(["shift"])
        }

        if modifiers.contains(.command) {
            phrases = phrases.appendingModifierSearchAliases(["command", "cmd"])
        }

        return phrases.filter { !$0.isEmpty }
    }

    private var commandBarKeySearchAliases: [String] {
        switch keyEquivalent {
        case ",":
            [",", "comma"]
        case "[":
            ["[", "left bracket", "open bracket"]
        case "]":
            ["]", "right bracket", "close bracket"]
        case "♡":
            ["heart"]
        case "=":
            ["=", "equals", "plus"]
        case "-":
            ["-", "minus", "hyphen"]
        default:
            [keyEquivalent.lowercased()]
        }
    }
}

private extension [String] {
    func appendingModifierSearchAliases(_ aliases: [String]) -> [String] {
        flatMap { phrase in
            aliases.map { alias in
                phrase.isEmpty ? alias : "\(phrase) \(alias)"
            }
        }
    }
}

// MARK: - BrowserTabPreviewCapture

private enum BrowserTabPreviewCapture {
    // MARK: Private

    /// Twice the switcher's widest preview.
    private static let maximumPreviewPixelWidth: CGFloat = 480
    private static let minimumCaptureDimension: CGFloat = 24

    // MARK: Internal

    @MainActor static func image(for view: NSView) -> NSImage? {
        guard
            view.bounds.width >= minimumCaptureDimension,
            view.bounds.height >= minimumCaptureDimension
        else {
            return nil
        }

        return BrowserImageThumbnailer.viewSnapshot(of: view, maximumPixelWidth: maximumPreviewPixelWidth)
    }
}

// MARK: - BrowserQuoteLink

enum BrowserQuoteLink {
    // MARK: Internal

    /// Chromium links a highlight by its exact text up to this length.
    static let exactTextLimit = 300

    // MARK: Private

    /// Words at each end of a long quote; words, not spaces, so text without
    /// spaces such as Chinese or Japanese splits too.
    private static let edgeWordCount = 4
    /// Each end stays short even when its words are long.
    private static let edgeCharacterLimit = 60

    /// The page's address with a text fragment for the quote: its exact text,
    /// or its first and last words when it is long or spans paragraphs.
    /// Nil without words or for a page that is not on the web.
    static func urlString(pageURLString: String, quote: String) -> String? {
        let lines = quote.split(whereSeparator: \.isNewline)
            .map { line in line.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { line in !line.isEmpty }
        guard let first = lines.first, let last = lines.last,
              var components = URLComponents(string: pageURLString),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "")
        else { return nil }
        let text = lines.joined(separator: " ")
        let directive: String =
            if lines.count == 1, text.count <= exactTextLimit {
                encoded(text)
            } else if let start = edgeWords(of: first, fromStart: true),
                      let end = edgeWords(of: last, fromStart: false),
                      lines.count > 1 || start.upperBound <= end.lowerBound
            {
                encoded(String(first[start])) + "," + encoded(String(last[end]))
            } else {
                encoded(text)
            }
        // The page's own fragment stays; an earlier highlight does not.
        let fragment = components.percentEncodedFragment?.components(separatedBy: ":~:").first ?? ""
        components.percentEncodedFragment = fragment + ":~:text=" + directive
        return components.string
    }

    private static func edgeWords(of line: String, fromStart: Bool) -> Range<String.Index>? {
        var words = [Range<String.Index>]()
        line.enumerateSubstrings(in: line.startIndex..<line.endIndex, options: .byWords) { _, range, _, _ in
            words.append(range)
        }
        var edge = fromStart ? Array(words.prefix(edgeWordCount)) : Array(words.suffix(edgeWordCount))
        // Whole words only: a single long word stays.
        while edge.count > 1, let first = edge.first, let last = edge.last,
              line[first.lowerBound..<last.upperBound].count > edgeCharacterLimit
        {
            if fromStart {
                edge.removeLast()
            } else {
                edge.removeFirst()
            }
        }
        guard let first = edge.first, let last = edge.last else { return nil }
        return first.lowerBound..<last.upperBound
    }

    /// Percent-encodes the characters that separate text fragment parts.
    private static func encoded(_ text: String) -> String {
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "&,-#%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

// MARK: - BrowserMarkdownLink

enum BrowserMarkdownLink {
    /// A Markdown link whose title cannot end the link text early. An empty
    /// title falls back to the URL.
    static func text(title: String, urlString: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (trimmed.isEmpty ? urlString : trimmed)
            .replacing("\\", with: "\\\\")
            .replacing("[", with: "\\[")
            .replacing("]", with: "\\]")
        let destination = urlString
            .replacing("(", with: "%28")
            .replacing(")", with: "%29")
            .replacing(" ", with: "%20")
        return "[\(label)](\(destination))"
    }
}
