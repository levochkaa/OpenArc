// BrowserStrings+Easels.swift

import Foundation

// MARK: - BrowserStrings + Easels

extension BrowserStrings {
    static let menuNewEasel = NSLocalizedString(
        "browser.menu.new_easel",
        comment: "Command and menu: create an Easel, a drawing canvas pinned in the sidebar.",
    )

    static let menuViewEasels = NSLocalizedString(
        "browser.menu.view_easels",
        comment: "Command and menu: open the Library's Easels.",
    )

    static let libraryEasels = NSLocalizedString(
        "browser.library.easels",
        comment: "Library section with Easels.",
    )

    static let libraryEmptyEasels = NSLocalizedString(
        "browser.library.empty_easels",
        comment: "Detail of the empty Easels section of the Library.",
    )

    static let easelUntitled = NSLocalizedString(
        "browser.easel.untitled",
        comment: "Name of an Easel whose title is empty.",
    )

    static let easelTextPlaceholder = NSLocalizedString(
        "browser.easel.text_placeholder",
        comment: "Placeholder of an empty text box on an Easel.",
    )

    static let easelPaletteVibrant = NSLocalizedString(
        "browser.easel.palette.vibrant",
        comment: "Easel color palette.",
    )

    static let easelPaletteChill = NSLocalizedString(
        "browser.easel.palette.chill",
        comment: "Easel color palette.",
    )

    static let easelToolPointer = NSLocalizedString(
        "browser.easel.tool.pointer",
        comment: "Easel tool tooltip.",
    )

    static let easelToolImage = NSLocalizedString(
        "browser.easel.tool.image",
        comment: "Easel tool tooltip.",
    )

    static let easelToolText = NSLocalizedString(
        "browser.easel.tool.text",
        comment: "Easel tool tooltip.",
    )

    static let easelToolCircle = NSLocalizedString(
        "browser.easel.tool.circle",
        comment: "Easel tool tooltip.",
    )

    static let easelToolRectangle = NSLocalizedString(
        "browser.easel.tool.rectangle",
        comment: "Easel tool tooltip.",
    )

    static let easelToolArrow = NSLocalizedString(
        "browser.easel.tool.arrow",
        comment: "Easel tool tooltip.",
    )

    static let easelToolPen = NSLocalizedString(
        "browser.easel.tool.pen",
        comment: "Easel tool tooltip.",
    )

    static let easelToolCapture = NSLocalizedString(
        "browser.easel.tool.capture",
        comment: "Easel toolbar button that captures part of a page into the Easel.",
    )

    static let easelUndoInsert = NSLocalizedString(
        "browser.easel.undo.insert",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoDelete = NSLocalizedString(
        "browser.easel.undo.delete",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoArrange = NSLocalizedString(
        "browser.easel.undo.arrange",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoMove = NSLocalizedString(
        "browser.easel.undo.move",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoResize = NSLocalizedString(
        "browser.easel.undo.resize",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoColor = NSLocalizedString(
        "browser.easel.undo.color",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoTyping = NSLocalizedString(
        "browser.easel.undo.typing",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoTextStyle = NSLocalizedString(
        "browser.easel.undo.text_style",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoTitle = NSLocalizedString(
        "browser.easel.undo.title",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoLive = NSLocalizedString(
        "browser.easel.undo.live",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoPalette = NSLocalizedString(
        "browser.easel.undo.palette",
        comment: "Undo action name on an Easel.",
    )

    static let easelUndoGuides = NSLocalizedString(
        "browser.easel.undo.guides",
        comment: "Undo action name on an Easel.",
    )

    static let easelBringToFront = NSLocalizedString(
        "browser.easel.bring_to_front",
        comment: "Easel object menu item.",
    )

    static let easelSendToBack = NSLocalizedString(
        "browser.easel.send_to_back",
        comment: "Easel object menu item.",
    )

    static let easelDuplicate = NSLocalizedString(
        "browser.easel.duplicate",
        comment: "Easel object menu item.",
    )

    static let easelDeleteObject = NSLocalizedString(
        "browser.easel.delete_object",
        comment: "Easel object menu item.",
    )

    static let easelMakeTitle = NSLocalizedString(
        "browser.easel.make_title",
        comment: "Easel text menu item: the text names the Easel.",
    )

    static let easelLiveCapture = NSLocalizedString(
        "browser.easel.live_capture",
        comment: "Easel capture menu item: refresh the picture from its open page while the Easel is shown.",
    )

    static let easelOpenPage = NSLocalizedString(
        "browser.easel.open_page",
        comment: "Easel capture menu item.",
    )

    static let easelCopyPageLink = NSLocalizedString(
        "browser.easel.copy_page_link",
        comment: "Easel capture menu item.",
    )

    static let easelColorPalette = NSLocalizedString(
        "browser.easel.color_palette",
        comment: "Easel canvas menu item with the palettes.",
    )

    static let easelUseAlignmentGuides = NSLocalizedString(
        "browser.easel.use_alignment_guides",
        comment: "Easel canvas menu toggle.",
    )

    static let easelShare = NSLocalizedString(
        "browser.easel.share",
        comment: "Easel share button tooltip.",
    )

    static let easelShareVia = NSLocalizedString(
        "browser.easel.share_via",
        comment: "Easel share menu item.",
    )

    static let easelSaveImage = NSLocalizedString(
        "browser.easel.save_image",
        comment: "Easel share menu item.",
    )

    static let easelCopyImage = NSLocalizedString(
        "browser.easel.copy_image",
        comment: "Easel share menu item.",
    )

    static let easelMissing = NSLocalizedString(
        "browser.easel.missing",
        comment: "Shown on an Easel tab that came through sync without its drawing.",
    )

    static let easelLiveBadge = NSLocalizedString(
        "browser.easel.live_badge",
        comment: "Badge on a capture that updates from its page.",
    )

    static let easelCanvasLabel = NSLocalizedString(
        "browser.easel.canvas_label",
        comment: "Accessibility label of the Easel canvas.",
    )

    static let easelRemoveFromSidebar = NSLocalizedString(
        "browser.easel.remove_from_sidebar",
        comment: "Sidebar row menu item; the Easel stays in the Library.",
    )

    static let easelDeleteMenu = NSLocalizedString(
        "browser.easel.delete_menu",
        comment: "Sidebar row and Library menu item.",
    )

    static let easelDeleteTitle = NSLocalizedString(
        "browser.easel.delete_title",
        comment: "Delete Easel confirmation title.",
    )

    static let easelDeleteMessage = NSLocalizedString(
        "browser.easel.delete_message",
        comment: "Delete Easel confirmation message.",
    )

    static let easelDeleteConfirm = NSLocalizedString(
        "browser.easel.delete_confirm",
        comment: "Delete Easel confirmation button.",
    )

    static let easelOpenMenu = NSLocalizedString(
        "browser.easel.open_menu",
        comment: "Library Easel menu item.",
    )

    static let captureToastNewEasel = NSLocalizedString(
        "browser.capture.toast_new_easel",
        comment: "Tooltip of the capture note's Easel button.",
    )

    static let easelTextLarger = NSLocalizedString(
        "browser.easel.text_larger",
        comment: "Easel text menu button.",
    )

    static let easelTextSmaller = NSLocalizedString(
        "browser.easel.text_smaller",
        comment: "Easel text menu button.",
    )

    static let easelTextFont = NSLocalizedString(
        "browser.easel.text_font",
        comment: "Easel text menu button.",
    )

    static let easelFileName = NSLocalizedString(
        "browser.easel.file_name",
        comment: "Default file name of a saved Easel picture.",
    )

    static func easelEdited(_ date: Date) -> String {
        String(
            format: NSLocalizedString("browser.easel.edited", comment: "Library Easel detail with the date it was last edited."),
            date.formatted(date: .abbreviated, time: .shortened),
        )
    }
}
