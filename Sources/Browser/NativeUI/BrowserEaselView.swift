// BrowserEaselView.swift

import AppKit
import UniformTypeIdentifiers

// MARK: - BrowserEaselView

/// An Easel on screen: the canvas scrolls down the page, the tools float at the
/// bottom leading corner and Share at the bottom trailing one.
@MainActor final class BrowserEaselView: NSView {
    override var isFlipped: Bool { true }

    // MARK: Internal

    let easelID: String
    let editor: BrowserEaselEditor?
    let canvas: BrowserEaselCanvasView

    /// The tab's title follows the Easel's.
    var onDocumentChange: ((BrowserEaselEditor) -> Void)?
    var onCapture: ((String) -> Void)?
    var onOpenCapture: ((BrowserEaselCapture) -> Void)?
    /// Asks the page of a live capture for a new picture.
    var refreshLiveCapture: ((BrowserEaselCapture, @escaping @MainActor (Data?) -> Void) -> Void)?

    // MARK: Private

    private let store: BrowserEaselStore
    private let scroll = NSScrollView()
    private let toolbar = BrowserEaselToolbar()
    /// Share sits on the same floating panel as the tools.
    private let sharePanel = BrowserEaselToolbar(tools: [], showsCapture: false)
    private let shareButton = BrowserEaselToolbarButton(
        symbol: "person.crop.circle.badge.plus",
        title: BrowserStrings.easelShare,
    )
    private let missingLabel = NSTextField(labelWithString: BrowserStrings.easelMissing)
    private var storeObserver: NSObjectProtocol?
    private var liveTimer: Timer?
    private var pendingLiveRefreshes = Set<String>()
    private lazy var offersTitle = editor.map { Self.isBrandNew($0.document) } ?? false

    init(easelID: String, store: BrowserEaselStore) {
        self.easelID = easelID
        self.store = store
        let document = store.document(id: easelID)
        self.editor = document.map { BrowserEaselEditor(document: $0) }
        self.canvas = BrowserEaselCanvasView(store: store)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = canvas
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        addSubview(toolbar)
        sharePanel.addSubview(shareButton)
        addSubview(sharePanel)
        missingLabel.alignment = .center
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.font = .systemFont(ofSize: 13)
        missingLabel.isHidden = editor != nil
        addSubview(missingLabel)
        toolbar.isHidden = editor == nil
        sharePanel.isHidden = editor == nil
        setAccessibilityIdentifier("browser.easel")

        canvas.editor = editor
        canvas.onToolChange = { [weak self] tool in self?.toolbar.selectedTool = tool }
        canvas.onDocumentChange = { [weak self] in self?.documentChanged() }
        canvas.onOpenCapture = { [weak self] capture in self?.onOpenCapture?(capture) }
        toolbar.onSelectTool = { [weak self] tool in self?.canvas.select(tool: tool) }
        toolbar.onCapture = { [weak self] in
            guard let self else { return }
            onCapture?(easelID)
        }
        shareButton.onClick = { [weak self] in self?.showShareMenu() }
        editor?.onChange = { [weak self] document in
            guard let self else { return }
            self.offersTitle = false
            store.save(document)
            documentChanged()
        }
        self.storeObserver = NotificationCenter.default.addObserver(
            forName: BrowserEaselStore.didChangeNotification,
            object: store,
            queue: .main,
        ) { [weak self] notification in
            let id = notification.userInfo?["id"] as? String
            MainActor.assumeIsolated {
                guard let self, id == self.easelID else { return }
                self.storeChanged()
            }
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        liveTimer?.invalidate()
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        canvas.layoutForWidth(scroll.contentSize.width, visibleHeight: scroll.contentSize.height)
        let toolbarSize = toolbar.fittingSize
        toolbar.frame = CGRect(
            x: 12,
            y: bounds.height - 12 - toolbarSize.height,
            width: toolbarSize.width,
            height: toolbarSize.height,
        )
        sharePanel.frame = CGRect(x: bounds.width - 12 - 44, y: bounds.height - 12 - 44, width: 44, height: 44)
        shareButton.frame = CGRect(x: 4, y: 4, width: 36, height: 36)
        missingLabel.frame = CGRect(x: 24, y: bounds.midY - 10, width: max(bounds.width - 48, 0), height: 20)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLiveTimer()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateLiveTimer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateLiveTimer()
    }

    private static func isBrandNew(_ document: BrowserEaselDocument) -> Bool {
        document.objects.count == 1 && document.createdAt == document.modifiedAt
            && Date().timeIntervalSince(document.createdAt) < 10
    }

    /// Gives the canvas the keyboard, unless a field of it has it already. A
    /// new Easel's title waits selected for typing until the first edit.
    func focusCanvas() {
        guard let window, !isHiddenOrHasHiddenAncestor else { return }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) { return }
        if offersTitle, let id = editor?.document.titleObject?.id {
            canvas.beginEditingText(id, selectsAll: true)
            return
        }
        window.makeFirstResponder(canvas)
    }

    /// Asks every live capture's page for a picture now.
    func refreshLiveCaptures() {
        guard let editor, let refreshLiveCapture else { return }
        for object in editor.document.objects {
            guard let capture = object.content.capture, capture.isLive, !pendingLiveRefreshes.contains(object.id)
            else { continue }
            pendingLiveRefreshes.insert(object.id)
            let objectID = object.id
            refreshLiveCapture(capture) { [weak self] data in
                guard let self else { return }
                pendingLiveRefreshes.remove(objectID)
                guard let data, NSImage(data: data) != nil else { return }
                store.writeImage(data, named: capture.fileName, easelID: easelID)
                canvas.needsDisplay = true
            }
        }
    }

    private func documentChanged() {
        canvas.documentDidChange()
        needsLayout = true
        updateLiveTimer()
        if let editor { onDocumentChange?(editor) }
    }

    private func storeChanged() {
        guard let editor, let newer = store.document(id: easelID), newer != editor.document else { return }
        editor.replaceDocument(newer)
        documentChanged()
    }

    private func updateLiveTimer() {
        let hasLive = editor?.document.objects.contains { $0.content.capture?.isLive == true } ?? false
        let shows = window != nil && !isHiddenOrHasHiddenAncestor && hasLive
        if shows, liveTimer == nil {
            let timer = Timer(
                timeInterval: BrowserChromeModel.easelLiveCaptureInterval,
                repeats: true,
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLiveCaptures() }
            }
            RunLoop.main.add(timer, forMode: .common)
            liveTimer = timer
            refreshLiveCaptures()
        } else if !shows {
            liveTimer?.invalidate()
            liveTimer = nil
        }
    }

    private func showShareMenu() {
        guard let editor else { return }
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus.add(BrowserStrings.easelShareVia, to: menu) { [weak self] in
            guard let self, let url = exportedImageURL(editor.document) else { return }
            NSSharingServicePicker(items: [url])
                .show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
        }
        BrowserNativeMenus.add(BrowserStrings.easelSaveImage, to: menu) { [weak self] in
            guard let self, let window, let png = pngData(editor.document) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = editor.document.title
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? png.write(to: url)
            }
        }
        BrowserNativeMenus.add(BrowserStrings.easelCopyImage, to: menu) { [weak self] in
            guard let self, let png = pngData(editor.document) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: shareButton.bounds.height + 4), in: shareButton)
    }

    private func pngData(_ document: BrowserEaselDocument) -> Data? {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return BrowserEaselRenderer.image(document, pixelWidth: 2000, isDark: isDark, store: store)?
            .representation(using: .png, properties: [:])
    }

    private func exportedImageURL(_ document: BrowserEaselDocument) -> URL? {
        guard let png = pngData(document) else { return nil }
        let name = document.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        return (try? png.write(to: url)) == nil ? nil : url
    }
}

// MARK: - BrowserEaselCanvasView

/// The page an Easel draws on. One Easel point is `scale` view points, so the
/// drawing grows and shrinks with the window's width.
@MainActor final class BrowserEaselCanvasView: NSView, NSTextViewDelegate, NSUserInterfaceValidations {
    // MARK: Private

    private enum Drag {
        case move(id: String, start: CGRect, from: CGPoint)
        case resize(id: String, handle: BrowserEaselHandle, start: BrowserEaselObject)
        case create(kind: BrowserEaselShapeKind, from: CGPoint, to: CGPoint)
        case draw(points: [CGPoint])
    }

    // MARK: Internal

    static let pasteboardType = NSPasteboard.PasteboardType("com.levochkaa.OpenArc.easel-object")
    static let selectionColor = NSColor(srgbRed: 108 / 255, green: 186 / 255, blue: 217 / 255, alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    weak var editor: BrowserEaselEditor? {
        didSet {
            editor?.onSelectionChange = { [weak self] in self?.selectionChanged() }
            documentDidChange()
        }
    }

    var onToolChange: ((BrowserEaselTool) -> Void)?
    var onDocumentChange: (() -> Void)?
    var onOpenCapture: ((BrowserEaselCapture) -> Void)?

    private let store: BrowserEaselStore
    private let colorPicker = BrowserEaselColorPicker()
    private let textMenu = BrowserEaselTextMenu()
    private var visibleHeight: CGFloat = 0
    private var drag: Drag?
    /// The document while a drag or typing changes it, before the change is saved.
    private var liveDocument: BrowserEaselDocument?
    private var guides: (verticals: [CGFloat], horizontals: [CGFloat]) = ([], [])
    private var hoveredObjectID: String?
    private var trackingArea: NSTrackingArea?
    private var editingTextID: String?
    private var editingOriginal: BrowserEaselObject?
    private var textView: BrowserEaselTextView?
    private let textUndoManager = UndoManager()

    /// View points per Easel point.
    var scale: CGFloat { max(bounds.width, 1) / BrowserEaselDocument.width }

    private var canPaste: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.availableType(from: [Self.pasteboardType, .png, .tiff, .string]) != nil
            || pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    init(store: BrowserEaselStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(BrowserStrings.easelCanvasLabel)
        setAccessibilityIdentifier("browser.easel.canvas")
        colorPicker.isHidden = true
        colorPicker.onPick = { [weak self] color in
            guard let self, let editor, let id = editor.selectedObjectID else { return }
            editor.setColor(color, of: id)
        }
        addSubview(colorPicker)
        textMenu.isHidden = true
        textMenu.onLarger = { [weak self] in self?.stepTextStyle(larger: true) }
        textMenu.onSmaller = { [weak self] in self?.stepTextStyle(larger: false) }
        textMenu.onFont = { [weak self] in
            guard let self, let editor, let id = editor.selectedObjectID else { return }
            editor.cycleFont(of: id)
        }
        addSubview(textMenu)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        BrowserEaselRenderer.background(isDark: isDark).setFill()
        dirtyRect.fill()
        guard let editor else { return }
        let document = liveDocument ?? editor.document
        BrowserEaselRenderer.draw(
            document,
            scale: scale,
            isDark: isDark,
            store: store,
            hiddenObjectID: editingTextID,
            placeholderObjectID: editor.selectedObjectID,
        )
        for object in document.objects {
            if let capture = object.content.capture {
                drawCaptureChrome(capture, rect: viewRect(object.frame), hovered: object.id == hoveredObjectID)
            }
        }
        drawGuides()
        drawPending(document: document, isDark: isDark)
        if let id = editor.selectedObjectID, let object = document.object(id) {
            drawSelection(object)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let editor else { return }
        let point = documentPoint(event)
        if editingTextID != nil {
            endEditingText(commit: true)
        }
        switch editor.tool {
        case .pointer:
            if event.clickCount == 2, let id = hitObject(at: point), editor.document.object(id)?.content.text != nil {
                beginEditingText(id, selectsAll: false)
                return
            }
            if let selected = editor.selectedObject, let handle = handle(at: point, of: selected) {
                drag = .resize(id: selected.id, handle: handle, start: selected)
                return
            }
            if let id = hitObject(at: point), let object = editor.document.object(id) {
                editor.selectedObjectID = id
                if event.clickCount == 1, object.content.capture != nil, captureOpenRect(object.frame).contains(point) {
                    if let capture = object.content.capture { onOpenCapture?(capture) }
                    return
                }
                drag = .move(id: id, start: object.frame, from: point)
            } else {
                editor.selectedObjectID = nil
            }
        case .text:
            let id = editor.insertText(at: point)
            setTool(.pointer)
            beginEditingText(id, selectsAll: false)
        case .freehand:
            drag = .draw(points: [point])
        case .arrow, .circle, .rectangle:
            drag = .create(kind: editor.tool.shapeKind ?? .rectangle, from: point, to: point)
        case .image:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let editor, let drag else { return }
        let point = documentPoint(event)
        switch drag {
        case .move(let id, let start, let from):
            var frame = start.offsetBy(dx: point.x - from.x, dy: point.y - from.y)
            guides = ([], [])
            if editor.document.usesAlignmentGuides, !event.modifierFlags.contains(.command) {
                let others = editor.document.objects.filter { $0.id != id }.map(\.frame)
                let snap = BrowserEaselEditor.snapOffset(for: frame, among: others, distance: 6 / scale)
                frame = frame.offsetBy(dx: snap.offset.x, dy: snap.offset.y)
                guides = (snap.verticals, snap.horizontals)
            }
            setLiveFrame(frame, of: id)
        case .resize(let id, let handle, let start):
            if case .shape(let shape) = start.content, shape.kind == .arrow,
               handle == .arrowStart || handle == .arrowEnd
            {
                let (frame, moved) = BrowserEaselEditor.movedArrow(
                    frame: start.frame,
                    shape: shape,
                    handle: handle,
                    to: point,
                )
                setLive(id) { $0.frame = frame
                    $0.content = .shape(moved)
                }
            } else {
                let keepsAspect = event.modifierFlags.contains(.shift) || start.content.fileNames.isEmpty == false
                var frame = BrowserEaselEditor.resizedFrame(
                    start.frame,
                    handle: handle,
                    to: point,
                    keepsAspect: keepsAspect,
                )
                if let text = start.content.text {
                    frame.size.height = BrowserEaselEditor.textHeight(text, width: frame.width)
                    frame.origin.y = start.frame.minY
                }
                setLiveFrame(frame, of: id)
            }
        case .create(let kind, let from, _):
            self.drag = .create(kind: kind, from: from, to: point)
        case .draw(var points):
            points.append(point)
            self.drag = .draw(points: points)
        }
        layoutAccessories()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let editor, let drag else { return }
        self.drag = nil
        guides = ([], [])
        switch drag {
        case .move(let id, let start, _):
            if let frame = liveDocument?.object(id)?.frame, frame != start {
                editor.setFrame(frame, of: id)
            }
        case .resize(let id, _, _):
            if let object = liveDocument?.object(id) {
                editor.change(BrowserStrings.easelUndoResize) { document in
                    guard let index = document.index(of: id) else { return }
                    document.objects[index] = object
                }
            }
        case .create(let kind, let from, let to):
            _ = editor.insertShape(kind, from: from, to: to, keepsSquare: event.modifierFlags.contains(.shift))
            setTool(.pointer)
        case .draw(let points):
            // The pen stays on for the next stroke.
            editor.insertDrawing(points)
        }
        liveDocument = nil
        layoutAccessories()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let editor else { return }
        let point = documentPoint(event)
        let hovered = hitObject(at: point)
            .flatMap { id in editor.document.object(id)?.content.capture != nil ? id : nil }
        if hovered != hoveredObjectID {
            hoveredObjectID = hovered
            needsDisplay = true
        }
        cursor(at: point).set()
    }

    override func mouseExited(with _: NSEvent) {
        if hoveredObjectID != nil {
            hoveredObjectID = nil
            needsDisplay = true
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: documentPoint(event)).set()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let editor else { return nil }
        endEditingText(commit: true)
        let point = documentPoint(event)
        if let id = hitObject(at: point) {
            editor.selectedObjectID = id
            return objectMenu(id)
        }
        editor.selectedObjectID = nil
        return canvasMenu()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let editor else { return super.keyDown(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 51, 117:
            editor.deleteSelection()
            return
        case 53:
            if editor.tool != .pointer {
                setTool(.pointer)
            } else {
                editor.selectedObjectID = nil
            }
            needsDisplay = true
            return
        case 36, 76:
            if let id = editor.selectedObjectID, editor.document.object(id)?.content.text != nil {
                beginEditingText(id, selectsAll: false)
                return
            }
        case 123, 124, 125, 126:
            if let object = editor.selectedObject {
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let delta =
                    switch event.keyCode {
                    case 123: CGPoint(x: -step, y: 0)
                    case 124: CGPoint(x: step, y: 0)
                    case 125: CGPoint(x: 0, y: step)
                    default: CGPoint(x: 0, y: -step)
                    }
                editor.setFrame(object.frame.offsetBy(dx: delta.x, dy: delta.y), of: object.id)
                return
            }
        default:
            break
        }
        if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
           let tool = BrowserEaselTool.allCases.first(where: { $0.key == key })
        {
            select(tool: tool)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Drag and drop

    override func draggingEntered(_: NSDraggingInfo) -> NSDragOperation {
        editor == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = documentPoint(convert(sender.draggingLocation, from: nil))
        return insertImages(from: sender.draggingPasteboard, at: point)
    }

    func layoutForWidth(_ width: CGFloat, visibleHeight: CGFloat) {
        self.visibleHeight = visibleHeight
        let scale = max(width, 1) / BrowserEaselDocument.width
        let bottom = (editor?.document.contentBottom ?? 0) + 400
        let height = max(bottom * scale, visibleHeight)
        if frame.size != CGSize(width: width, height: height) {
            setFrameSize(CGSize(width: width, height: height))
            // The text being typed keeps its field, at the new scale.
            if let id = editingTextID, let view = textView,
               let text = (liveDocument ?? editor?.document)?.object(id)?.content.text
            {
                applyTextStyle(text, to: view)
                positionTextView(for: id)
            }
        }
        layoutAccessories()
        needsDisplay = true
    }

    func documentDidChange() {
        layoutForWidth(bounds.width, visibleHeight: visibleHeight)
        if let editingTextID, editor?.document.object(editingTextID) == nil {
            endEditingText(commit: false)
        }
        layoutAccessories()
        needsDisplay = true
    }

    func select(tool: BrowserEaselTool) {
        endEditingText(commit: true)
        if tool == .image {
            chooseImages()
            setTool(.pointer)
            return
        }
        setTool(tool)
        if tool != .pointer { editor?.selectedObjectID = nil }
        window?.makeFirstResponder(self)
    }

    // MARK: Edit menu

    @objc func undo(_: Any?) {
        endEditingText(commit: true)
        editor?.undoManager.undo()
    }

    @objc func redo(_: Any?) {
        editor?.undoManager.redo()
    }

    @objc func copy(_: Any?) {
        guard let object = editor?.selectedObject else { return }
        write([object])
    }

    @objc func cut(_: Any?) {
        guard let editor, let object = editor.selectedObject else { return }
        write([object])
        editor.deleteSelection()
    }

    @objc func delete(_: Any?) {
        editor?.deleteSelection()
    }

    @objc func paste(_: Any?) {
        paste(at: nil)
    }

    @objc func duplicate(_: Any?) {
        editor?.duplicateSelection()
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let editor else { return false }
        switch item.action {
        case #selector(undo(_:)): return editor.undoManager.canUndo
        case #selector(redo(_:)): return editor.undoManager.canRedo
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)):
            return editor.selectedObjectID != nil
        case #selector(paste(_:)): return canPaste
        default: return true
        }
    }

    // MARK: Text editing

    func beginEditingText(_ id: String, selectsAll: Bool) {
        guard let editor, let object = editor.document.object(id), let text = object.content.text else { return }
        endEditingText(commit: true)
        editor.selectedObjectID = id
        editingTextID = id
        editingOriginal = object
        let view = BrowserEaselTextView()
        view.delegate = self
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.insertionPointColor = Self.selectionColor
        view.onEscape = { [weak self] in self?.endEditingText(commit: true) }
        textView = view
        applyTextStyle(text, to: view)
        view.string = text.string
        addSubview(view, positioned: .below, relativeTo: colorPicker)
        positionTextView(for: id)
        window?.makeFirstResponder(view)
        if selectsAll { view.selectAll(nil) }
        layoutAccessories()
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, let id = editingTextID,
              var object = liveDocument?.object(id) ?? editor?.document.object(id), var text = object.content.text
        else { return }
        text.string = view.string
        object.content = .text(text)
        object.frame.size.height = BrowserEaselEditor.textHeight(text, width: object.frame.width)
        setLive(id) { $0 = object }
        positionTextView(for: id)
        layoutAccessories()
    }

    /// Typing has its own Undo: the window's manager records only whole browser actions.
    func undoManager(for _: NSTextView) -> UndoManager? {
        textUndoManager
    }

    func textDidEndEditing(_: Notification) {
        endEditingText(commit: true, restoresFocus: false)
    }

    func endEditingText(commit: Bool, restoresFocus: Bool = true) {
        guard let id = editingTextID, let view = textView, let editor else { return }
        editingTextID = nil
        textView = nil
        let string = view.string
        view.delegate = nil
        view.removeFromSuperview()
        // The whole edit becomes one step of the Easel's Undo.
        textUndoManager.removeAllActions()
        let original = editingOriginal
        editingOriginal = nil
        liveDocument = nil
        if commit, let original, var text = original.content.text {
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.isTitle {
                editor.change(BrowserStrings.easelUndoTyping) { $0.objects.removeAll { $0.id == id } }
                editor.selectedObjectID = nil
            } else if string != text.string {
                text.string = string
                let height = BrowserEaselEditor.textHeight(text, width: original.frame.width)
                editor.change(BrowserStrings.easelUndoTyping) { document in
                    guard let index = document.index(of: id) else { return }
                    document.objects[index].content = .text(text)
                    document.objects[index].frame.size.height = height
                }
            }
        }
        if restoresFocus, window?.firstResponder == nil || window?.firstResponder === view {
            window?.makeFirstResponder(self)
        }
        layoutAccessories()
        needsDisplay = true
    }

    private func setTool(_ tool: BrowserEaselTool) {
        editor?.tool = tool
        onToolChange?(tool)
        window?.invalidateCursorRects(for: self)
    }

    private func documentPoint(_ event: NSEvent) -> CGPoint {
        documentPoint(convert(event.locationInWindow, from: nil))
    }

    private func documentPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / scale, y: point.y / scale)
    }

    private func viewRect(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
    }

    private func hitObject(at point: CGPoint) -> String? {
        guard let editor else { return nil }
        return BrowserEaselEditor.hitObject(at: point, in: editor.document, tolerance: 8 / scale)
    }

    private func setLiveFrame(_ frame: CGRect, of id: String) {
        setLive(id) { $0.frame = frame }
    }

    private func setLive(_ id: String, _ body: (inout BrowserEaselObject) -> Void) {
        guard let editor else { return }
        var document = liveDocument ?? editor.document
        guard let index = document.index(of: id) else { return }
        body(&document.objects[index])
        liveDocument = document
        needsDisplay = true
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        guard let editor else { return .arrow }
        switch editor.tool {
        case .pointer:
            if let selected = editor.selectedObject, handle(at: point, of: selected) != nil { return .crosshair }
            if let id = hitObject(at: point), let object = editor.document.object(id) {
                if object.content.capture != nil, captureOpenRect(object.frame).contains(point) { return .pointingHand }
                return .openHand
            }
            return .arrow
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    private func handlePoints(of object: BrowserEaselObject) -> [(BrowserEaselHandle, CGPoint)] {
        let frame = object.frame
        if case .shape(let shape) = object.content, shape.kind == .arrow {
            return [
                (
                    .arrowStart,
                    CGPoint(
                        x: frame.minX + shape.arrowStart.x * frame.width,
                        y: frame.minY + shape.arrowStart.y * frame.height,
                    ),
                ),
                (
                    .arrowEnd,
                    CGPoint(
                        x: frame.minX + shape.arrowEnd.x * frame.width,
                        y: frame.minY + shape.arrowEnd.y * frame.height,
                    ),
                ),
            ]
        }
        let pad = 4 / scale
        let box = frame.insetBy(dx: -pad, dy: -pad)
        return [
            (.topLeft, CGPoint(x: box.minX, y: box.minY)),
            (.topRight, CGPoint(x: box.maxX, y: box.minY)),
            (.bottomLeft, CGPoint(x: box.minX, y: box.maxY)),
            (.bottomRight, CGPoint(x: box.maxX, y: box.maxY)),
        ]
    }

    private func handle(at point: CGPoint, of object: BrowserEaselObject) -> BrowserEaselHandle? {
        let reach = 7 / scale
        return handlePoints(of: object).first { hypot($0.1.x - point.x, $0.1.y - point.y) <= reach }?.0
    }

    private func drawSelection(_ object: BrowserEaselObject) {
        Self.selectionColor.setStroke()
        if object.content.shape?.kind != .arrow {
            let box = viewRect(object.frame).insetBy(dx: -4, dy: -4)
            let outline = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            outline.lineWidth = 2
            outline.stroke()
        }
        for (_, point) in handlePoints(of: object) {
            let center = CGPoint(x: point.x * scale, y: point.y * scale)
            let dot = NSBezierPath(ovalIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
            BrowserEaselRenderer
                .background(isDark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                .setFill()
            dot.fill()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func drawGuides() {
        guard !guides.verticals.isEmpty || !guides.horizontals.isEmpty else { return }
        let path = NSBezierPath()
        for x in guides.verticals {
            path.move(to: CGPoint(x: x * scale, y: 0))
            path.line(to: CGPoint(x: x * scale, y: bounds.height))
        }
        for y in guides.horizontals {
            path.move(to: CGPoint(x: 0, y: y * scale))
            path.line(to: CGPoint(x: bounds.width, y: y * scale))
        }
        path.lineWidth = 1
        path.setLineDash([4, 4], count: 2, phase: 0)
        Self.selectionColor.setStroke()
        path.stroke()
    }

    private func drawPending(document: BrowserEaselDocument, isDark: Bool) {
        switch drag {
        case .create(let kind, let from, let to):
            let rect = CGRect(
                x: min(from.x, to.x),
                y: min(from.y, to.y),
                width: abs(to.x - from.x),
                height: abs(to.y - from.y),
            )
            var shape = BrowserEaselShape(kind: kind, color: kind.defaultColor)
            if kind == .arrow {
                shape.arrowStart = CGPoint(x: from.x <= to.x ? 0 : 1, y: from.y <= to.y ? 0 : 1)
                shape.arrowEnd = CGPoint(x: 1 - shape.arrowStart.x, y: 1 - shape.arrowStart.y)
            }
            BrowserEaselRenderer.drawShape(
                shape,
                in: viewRect(rect),
                scale: scale,
                palette: document.palette,
                isDark: isDark,
            )
        case .draw(let points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
            for point in points.dropFirst() {
                path.line(to: CGPoint(x: point.x * scale, y: point.y * scale))
            }
            path.lineWidth = BrowserEaselRenderer.strokeWidth * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            BrowserEaselColor.black.color(palette: document.palette, isDark: isDark).setStroke()
            path.stroke()
        default:
            break
        }
    }

    /// The page's name and an open arrow along the bottom of a hovered capture;
    /// a live one shows a badge.
    private func drawCaptureChrome(_ capture: BrowserEaselCapture, rect: CGRect, hovered: Bool) {
        if capture.isLive {
            let badge = NSAttributedString(string: BrowserStrings.easelLiveBadge, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            let size = badge.size()
            let pill = CGRect(x: rect.minX + 8, y: rect.minY + 8, width: size.width + 12, height: 18)
            NSColor(srgbRed: 0.85, green: 0.2, blue: 0.2, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
            badge.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + (18 - size.height) / 2))
        }
        guard hovered, rect.width > 80, rect.height > 50 else { return }
        let bar = CGRect(x: rect.minX + 6, y: rect.maxY - 42, width: rect.width - 12, height: 36)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark ? NSColor(srgbRed: 0.145, green: 0.157, blue: 0.196, alpha: 1) : .white).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 8, yRadius: 8).fill()
        let title = NSAttributedString(string: capture.title.isEmpty ? capture.urlString : capture.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                return style
            }(),
        ])
        title.draw(in: CGRect(x: bar.minX + 12, y: bar.minY + 9, width: bar.width - 50, height: 18))
        let open = CGRect(x: bar.maxX - 29, y: bar.minY + 6.5, width: 23, height: 23)
        (isDark ? NSColor(white: 0.96, alpha: 0.11) : NSColor(white: 0.035, alpha: 0.07)).setFill()
        NSBezierPath(roundedRect: open, xRadius: 5, yRadius: 5).fill()
        if let symbol = NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: nil) {
            let configured = symbol.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) ?? symbol
            let size = configured.size
            configured.draw(in: CGRect(
                x: open.midX - size.width / 2,
                y: open.midY - size.height / 2,
                width: size.width,
                height: size.height,
            ))
        }
    }

    /// The open arrow's place on a capture, in Easel points.
    private func captureOpenRect(_ frame: CGRect) -> CGRect {
        let rect = viewRect(frame)
        guard rect.width > 80, rect.height > 50 else { return .null }
        let open = CGRect(x: rect.maxX - 6 - 29, y: rect.maxY - 42 + 6.5, width: 23, height: 23)
        return CGRect(
            x: open.minX / scale,
            y: open.minY / scale,
            width: open.width / scale,
            height: open.height / scale,
        )
    }

    private func selectionChanged() {
        layoutAccessories()
        needsDisplay = true
    }

    /// The color picker sits above a selected shape; the text menu left of selected text.
    private func layoutAccessories() {
        guard let editor, drag == nil, let id = editor.selectedObjectID,
              let object = (liveDocument ?? editor.document).object(id)
        else {
            colorPicker.isHidden = true
            textMenu.isHidden = true
            return
        }
        let rect = viewRect(object.frame)
        if let shape = object.content.shape {
            colorPicker.selectedColor = shape.color
            colorPicker.palette = editor.document.palette
            let size = colorPicker.fittingSize
            var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - 10 - size.height)
            if origin.y < 4 { origin.y = rect.maxY + 10 }
            origin.x = min(max(origin.x, 4), max(bounds.width - size.width - 4, 4))
            colorPicker.frame = CGRect(origin: origin, size: size)
            colorPicker.isHidden = false
            colorPicker.needsDisplay = true
        } else {
            colorPicker.isHidden = true
        }
        if let text = object.content.text {
            let size = textMenu.fittingSize
            textMenu.frame = CGRect(
                x: max(rect.minX - 10 - size.width, 4),
                y: rect.minY - 4,
                width: size.width,
                height: size.height,
            )
            textMenu.canGrow = text.style.larger != nil
            textMenu.canShrink = text.style.smaller != nil
            textMenu.isHidden = false
        } else {
            textMenu.isHidden = true
        }
    }

    private func stepTextStyle(larger: Bool) {
        guard let editor, let id = editor.selectedObjectID else { return }
        let wasEditing = editingTextID == id
        endEditingText(commit: true)
        editor.stepTextStyle(of: id, larger: larger)
        if wasEditing { beginEditingText(id, selectsAll: false) }
    }

    private func applyTextStyle(_ text: BrowserEaselText, to view: NSTextView) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette = editor?.document.palette ?? .vibrant
        let attributes = BrowserEaselRenderer.textAttributes(
            text,
            font: text.font.font(style: text.style, scale: scale),
            color: BrowserEaselColor.black.color(palette: palette, isDark: isDark),
        )
        view.typingAttributes = attributes
        view.font = attributes[.font] as? NSFont
        view.textColor = attributes[.foregroundColor] as? NSColor
        view.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        view.alignment = text.style == .body ? .left : .center
        view.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: view.textStorage?.length ?? 0))
    }

    private func positionTextView(for id: String) {
        guard let view = textView, let object = (liveDocument ?? editor?.document)?.object(id) else { return }
        if view.superview == nil { addSubview(view, positioned: .below, relativeTo: colorPicker) }
        let rect = viewRect(object.frame)
        let inset = BrowserEaselRenderer.textInset * scale
        view.frame = CGRect(
            x: rect.minX + inset,
            y: rect.minY,
            width: max(rect.width - 2 * inset, 10),
            height: max(rect.height, 10),
        )
    }

    private func objectMenu(_ id: String) -> NSMenu {
        let menu = BrowserNativeMenus.menu()
        guard let editor, let object = editor.document.object(id) else { return menu }
        if let capture = object.content.capture {
            BrowserNativeMenus
                .add(BrowserStrings.easelOpenPage, to: menu) { [weak self] in self?.onOpenCapture?(capture) }
            BrowserNativeMenus.add(BrowserStrings.easelCopyPageLink, to: menu) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(capture.urlString, forType: .string)
            }
            let live = BrowserNativeMenus.add(BrowserStrings.easelLiveCapture, to: menu) { [weak editor] in
                editor?.setLive(!capture.isLive, of: id)
            }
            live.state = capture.isLive ? .on : .off
            menu.addItem(.separator())
        }
        if let text = object.content.text, !text.isTitle {
            BrowserNativeMenus.add(BrowserStrings.easelMakeTitle, to: menu) { [weak editor] in editor?.makeTitle(id) }
            menu.addItem(.separator())
        }
        BrowserNativeMenus.add(BrowserStrings.easelBringToFront, to: menu) { [weak editor] in editor?.bringToFront(id) }
        BrowserNativeMenus.add(BrowserStrings.easelSendToBack, to: menu) { [weak editor] in editor?.sendToBack(id) }
        BrowserNativeMenus.add(BrowserStrings.easelDeleteObject, to: menu) { [weak editor] in
            editor?.selectedObjectID = id
            editor?.deleteSelection()
        }
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.menuCut, to: menu) { [weak self] in self?.cut(nil) }
        BrowserNativeMenus.add(BrowserStrings.menuCopy, to: menu) { [weak self] in self?.copy(nil) }
        BrowserNativeMenus
            .add(BrowserStrings.menuPaste, to: menu, enabled: canPaste) { [weak self] in self?.paste(nil) }
        menu.addItem(.separator())
        BrowserNativeMenus
            .add(BrowserStrings.easelDuplicate, to: menu) { [weak editor] in editor?.duplicateSelection() }
        return menu
    }

    private func canvasMenu() -> NSMenu {
        let menu = BrowserNativeMenus.menu()
        guard let editor else { return menu }
        let point = window.map { documentPoint(convert($0.mouseLocationOutsideOfEventStream, from: nil)) }
        BrowserNativeMenus.add(BrowserStrings.menuPaste, to: menu, enabled: canPaste) { [weak self] in
            self?.paste(at: point)
        }
        menu.addItem(.separator())
        let palettes = BrowserNativeMenus.submenu(BrowserStrings.easelColorPalette, in: menu)
        for palette in BrowserEaselPalette.allCases {
            let item = BrowserNativeMenus
                .add(palette.title, to: palettes) { [weak editor] in editor?.setPalette(palette) }
            item.state = editor.document.palette == palette ? .on : .off
        }
        let guides = BrowserNativeMenus.add(BrowserStrings.easelUseAlignmentGuides, to: menu) { [weak editor] in
            guard let editor else { return }
            editor.setUsesAlignmentGuides(!editor.document.usesAlignmentGuides)
        }
        guides.state = editor.document.usesAlignmentGuides ? .on : .off
        return menu
    }

    private func write(_ objects: [BrowserEaselObject]) {
        guard let editor else { return }
        var payload = [[String: Any]]()
        for object in objects {
            guard let data = try? JSONEncoder().encode(object) else { continue }
            var entry: [String: Any] = ["object": data]
            for name in object.content.fileNames {
                if let image = store.imageData(named: name, easelID: editor.document.id) {
                    entry["image"] = image
                }
            }
            payload.append(entry)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: payload, requiringSecureCoding: false) {
            pasteboard.setData(data, forType: Self.pasteboardType)
        }
        if let object = objects.first {
            switch object.content {
            case .text(let text): pasteboard.setString(text.string, forType: .string)
            case .capture, .image:
                if let name = object.content.fileNames.first,
                   let data = store.imageData(named: name, easelID: editor.document.id)
                {
                    pasteboard.setData(data, forType: .png)
                }
            case .shape: break
            }
        }
    }

    private func paste(at point: CGPoint?) {
        guard let editor else { return }
        endEditingText(commit: true)
        let pasteboard = NSPasteboard.general
        let center = point ?? visibleCenter()
        if let data = pasteboard.data(forType: Self.pasteboardType),
           let payload = try? NSKeyedUnarchiver.unarchivedObject(
               ofClasses: [NSArray.self, NSDictionary.self, NSString.self, NSData.self],
               from: data,
           ) as? [[String: Any]]
        {
            for entry in payload {
                guard let objectData = entry["object"] as? Data,
                      var object = try? JSONDecoder().decode(BrowserEaselObject.self, from: objectData)
                else { continue }
                object.id = UUID().uuidString
                object.frame.origin = CGPoint(
                    x: center.x - object.frame.width / 2,
                    y: center.y - object.frame.height / 2,
                )
                if let image = entry["image"] as? Data {
                    let name = store.addImage(image, toEaselID: editor.document.id)
                    switch object.content {
                    case .image(var picture):
                        picture.fileName = name
                        object.content = .image(picture)
                    case .capture(var capture):
                        capture.fileName = name
                        object.content = .capture(capture)
                    default: break
                    }
                }
                if case .text(var text) = object.content {
                    text.isTitle = false
                    object.content = .text(text)
                }
                editor.insert(object)
            }
            return
        }
        if insertImages(from: pasteboard, at: center) { return }
        if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty
        {
            let id = editor.insertText(at: CGPoint(x: center.x - 150, y: center.y), string: string)
            editor.fitTextHeight(of: id)
        }
    }

    @discardableResult private func insertImages(from pasteboard: NSPasteboard, at point: CGPoint) -> Bool {
        guard let editor else { return false }
        var datas = [Data]()
        if let urls = pasteboard
            .readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        {
            datas += urls.compactMap { url in
                guard let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image) else { return nil }
                return try? Data(contentsOf: url)
            }
        }
        if datas.isEmpty, let png = pasteboard.data(forType: .png) {
            datas.append(png)
        } else if datas.isEmpty, let tiff = pasteboard.data(forType: .tiff),
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        {
            datas.append(png)
        }
        var offset: CGFloat = 0
        for data in datas {
            // Pictures keep at most 2400 pixels on their long side.
            guard let image = BrowserImageThumbnailer.image(data: data, maximumPixelSize: 2400),
                  let png = image.tiffRepresentation
                    .flatMap({ NSBitmapImageRep(data: $0) })?
                    .representation(using: .png, properties: [:])
            else { continue }
            let name = store.addImage(png, toEaselID: editor.document.id)
            let rep = image.representations.first
            let size = CGSize(
                width: CGFloat(rep?.pixelsWide ?? Int(image.size.width)) / 2,
                height: CGFloat(rep?.pixelsHigh ?? Int(image.size.height)) / 2,
            )
            editor.insertImage(fileName: name, size: size, center: CGPoint(x: point.x + offset, y: point.y + offset))
            offset += 20
        }
        return !datas.isEmpty
    }

    private func chooseImages() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        let center = visibleCenter()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("BrowserEaselImagePicker"))
            pasteboard.clearContents()
            pasteboard.writeObjects(panel.urls as [NSURL])
            insertImages(from: pasteboard, at: center)
        }
    }

    private func visibleCenter() -> CGPoint {
        let visible = visibleRect.isEmpty ? bounds : visibleRect
        return documentPoint(CGPoint(x: visible.midX, y: visible.midY))
    }
}

// MARK: - BrowserEaselTextView

private final class BrowserEaselTextView: NSTextView {
    var onEscape: () -> Void = {}

    override func cancelOperation(_: Any?) {
        onEscape()
    }
}

// MARK: - BrowserEaselToolbar

/// The tools in a row, then the capture button after a divider.
@MainActor final class BrowserEaselToolbar: NSView {
    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let tools = CGFloat(tools.count) * 38
        return NSSize(width: tools + 51, height: 44)
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: Internal

    var onSelectTool: ((BrowserEaselTool) -> Void)?
    var onCapture: (() -> Void)?

    var selectedTool = BrowserEaselTool.pointer {
        didSet {
            for (tool, button) in buttons {
                button.isSelected = tool == selectedTool
                button.showsKey = tool == selectedTool && tool == .freehand
            }
        }
    }

    // MARK: Private

    private let tools: [BrowserEaselTool]
    private var buttons = [BrowserEaselTool: BrowserEaselToolbarButton]()
    private let captureButton = BrowserEaselToolbarButton(
        symbol: "plus.rectangle.on.rectangle",
        title: BrowserStrings.easelToolCapture,
    )
    private let divider = NSView()

    init(tools: [BrowserEaselTool] = BrowserEaselTool.allCases, showsCapture: Bool = true) {
        self.tools = tools
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        captureButton.isHidden = !showsCapture
        divider.isHidden = !showsCapture
        for tool in tools {
            let button = BrowserEaselToolbarButton(
                symbol: tool.symbol,
                title: tool.title,
                key: tool.key?.uppercased(),
            )
            button.onClick = { [weak self] in self?.onSelectTool?(tool) }
            button.setAccessibilityIdentifier("browser.easel.tool.\(tool.rawValue)")
            buttons[tool] = button
            addSubview(button)
        }
        captureButton.onClick = { [weak self] in self?.onCapture?() }
        captureButton.setAccessibilityIdentifier("browser.easel.capture")
        addSubview(captureButton)
        divider.wantsLayer = true
        addSubview(divider)
        self.selectedTool = .pointer
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        var x: CGFloat = 4
        for tool in tools {
            buttons[tool]?.frame = CGRect(x: x, y: 4, width: 36, height: 36)
            x += 38
        }
        divider.frame = CGRect(x: x + 1, y: 10, width: 1, height: 24)
        captureButton.frame = CGRect(x: x + 5, y: 4, width: 36, height: 36)
    }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (isDark ? NSColor.black : NSColor.white).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (isDark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.06)).cgColor
        layer?.shadowOpacity = isDark ? 0 : 0.08
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        divider.layer?.backgroundColor = (isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1))
            .cgColor
    }

    override func mouseDown(with _: NSEvent) {}
}

// MARK: - BrowserEaselToolbarButton

@MainActor final class BrowserEaselToolbarButton: NSView {
    override var wantsUpdateLayer: Bool { true }

    // MARK: Internal

    var onClick: () -> Void = {}

    var isSelected = false { didSet { needsDisplay = true
        updateLayer()
    } }

    var showsKey = false { didSet { keyLabel.isHidden = !showsKey } }

    // MARK: Private

    private let key: String?
    private let image = NSImageView()
    private let keyLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    private var isPressed = false

    init(symbol: String, title: String, key: String? = nil) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        image.imageScaling = .scaleNone
        image.contentTintColor = .labelColor
        addSubview(image)
        keyLabel.font = .systemFont(ofSize: 9, weight: .bold)
        keyLabel.textColor = .labelColor
        keyLabel.stringValue = key?.lowercased() ?? ""
        keyLabel.isHidden = true
        addSubview(keyLabel)
        toolTip = key.map { "\(title) (\($0))" } ?? title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        image.frame = bounds
        keyLabel.frame = CGRect(x: bounds.width - 12, y: 2, width: 10, height: 12)
    }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fill: NSColor =
            if isPressed {
                isDark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.12)
            } else if isSelected {
                isDark ? NSColor(white: 40 / 255, alpha: 1) : NSColor(white: 0, alpha: 0.07)
            } else if isHovered {
                isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.04)
            } else {
                .clear
            }
        layer?.backgroundColor = fill.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
        ))
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        updateLayer()
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        updateLayer()
    }

    override func mouseDown(with _: NSEvent) {
        isPressed = true
        updateLayer()
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        updateLayer()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

// MARK: - BrowserEaselColorPicker

/// Two rows of palette colors above a selected shape; the shape's own has a check.
@MainActor final class BrowserEaselColorPicker: NSView {
    // MARK: Internal

    static let dot: CGFloat = 16
    static let pitch: CGFloat = 21

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let gap: CGFloat = Self.pitch - Self.dot
        let width: CGFloat = 24 + 6 * Self.pitch - gap
        let height: CGFloat = 20 + 2 * Self.pitch - gap
        return NSSize(width: width, height: height)
    }

    var onPick: (BrowserEaselColor) -> Void = { _ in }
    var selectedColor = BrowserEaselColor.black
    var palette = BrowserEaselPalette.vibrant

    override func draw(_: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark ? NSColor.black : NSColor.white).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        if !isDark {
            NSColor(white: 0, alpha: 0.08).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
        }
        for (color, rect) in dots() {
            let fill = color.color(palette: palette, isDark: isDark)
            fill.setFill()
            let path = NSBezierPath(ovalIn: rect)
            path.fill()
            if color == .white || color == .black {
                NSColor(white: 0.5, alpha: 0.4).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            if color == selectedColor, let check = NSImage(
                systemSymbolName: "checkmark",
                accessibilityDescription: nil,
            )?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
            {
                let tinted = NSImage(size: check.size, flipped: false) { bounds in
                    check.draw(in: bounds)
                    (fill.brightnessComponentIsLight ? NSColor.black : NSColor.white).set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: CGRect(
                    x: rect.midX - check.size.width / 2,
                    y: rect.midY - check.size.height / 2,
                    width: check.size.width,
                    height: check.size.height,
                ))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let color = dots().first(where: { $0.1.insetBy(dx: -2, dy: -2).contains(point) })?.0 {
            selectedColor = color
            needsDisplay = true
            onPick(color)
        }
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    // MARK: Private

    private func dots() -> [(BrowserEaselColor, CGRect)] {
        var result = [(BrowserEaselColor, CGRect)]()
        for (row, colors) in BrowserEaselColor.pickerRows.enumerated() {
            let rowWidth = CGFloat(colors.count) * Self.pitch - (Self.pitch - Self.dot)
            let startX = (bounds.width - rowWidth) / 2
            for (column, color) in colors.enumerated() {
                result.append((color, CGRect(
                    x: startX + CGFloat(column) * Self.pitch,
                    y: 10 + CGFloat(row) * Self.pitch,
                    width: Self.dot,
                    height: Self.dot,
                )))
            }
        }
        return result
    }
}

// MARK: - BrowserEaselTextMenu

/// +, Aa and − beside selected text: larger style, next font, smaller style.
@MainActor final class BrowserEaselTextMenu: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override var fittingSize: NSSize { NSSize(width: 28, height: 84) }

    // MARK: Internal

    var onLarger: () -> Void = {}
    var onSmaller: () -> Void = {}
    var onFont: () -> Void = {}

    var canGrow = true { didSet { larger.isEnabled = canGrow } }
    var canShrink = true { didSet { smaller.isEnabled = canShrink } }

    // MARK: Private

    private let larger = NSButton()
    private let font = NSButton()
    private let smaller = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        for (button, title) in [
            (larger, BrowserStrings.easelTextLarger),
            (font, BrowserStrings.easelTextFont),
            (smaller, BrowserStrings.easelTextSmaller),
        ] {
            button.isBordered = false
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.contentTintColor = .labelColor
            addSubview(button)
        }
        larger.image = NSImage(systemSymbolName: "plus", accessibilityDescription: BrowserStrings.easelTextLarger)
        smaller.image = NSImage(systemSymbolName: "minus", accessibilityDescription: BrowserStrings.easelTextSmaller)
        font.title = "Aa"
        font.font = NSFont(descriptor: NSFont.systemFont(ofSize: 13).fontDescriptor.withDesign(.serif)!, size: 13)
        larger.target = self
        larger.action = #selector(growPressed)
        smaller.target = self
        smaller.action = #selector(shrinkPressed)
        font.target = self
        font.action = #selector(fontPressed)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        larger.frame = CGRect(x: 0, y: 2, width: 28, height: 26)
        font.frame = CGRect(x: 0, y: 29, width: 28, height: 26)
        smaller.frame = CGRect(x: 0, y: 56, width: 28, height: 26)
    }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (isDark ? NSColor.black : NSColor.white).cgColor
        layer?.borderWidth = isDark ? 0 : 1
        layer?.borderColor = NSColor(white: 0, alpha: 0.08).cgColor
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    @objc private func growPressed() { onLarger() }
    @objc private func shrinkPressed() { onSmaller() }
    @objc private func fontPressed() { onFont() }
}

private extension NSColor {
    /// Light enough for black marks on it.
    var brightnessComponentIsLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return true }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.6
    }
}

// MARK: - BrowserEaselDialogs

@MainActor enum BrowserEaselDialogs {
    /// Delete Easel asks first: the drawing cannot come back.
    static func confirmDelete(in window: NSWindow?, delete: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = BrowserStrings.easelDeleteTitle
        alert.informativeText = BrowserStrings.easelDeleteMessage
        let confirm = alert.addButton(withTitle: BrowserStrings.easelDeleteConfirm)
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: BrowserStrings.cancelAction)
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { delete() }
        }
        if let window = window?.sheetParent ?? window?.parent ?? window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
