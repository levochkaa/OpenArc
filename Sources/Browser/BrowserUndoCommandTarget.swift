// BrowserUndoCommandTarget.swift

import AppKit

// MARK: - BrowserUndoCommandTarget

/// Target of Undo and Redo. A page field typed in after the latest tab action
/// undoes its own typing. Otherwise a page, and the browser window around it,
/// undoes browser actions such as closing, moving, renaming or splitting tabs;
/// a field a page focused by itself, like a search box, does not hold them up.
/// Native text fields and other windows keep AppKit's responder chain.
@MainActor final class BrowserUndoCommandTarget: NSObject, NSMenuItemValidation {
    // MARK: Internal

    enum Direction {
        case undo, redo

        var selector: Selector {
            switch self {
            case .undo: #selector(BrowserUndoCommandTarget.undo(_:))
            case .redo: #selector(BrowserUndoCommandTarget.redo(_:))
            }
        }
    }

    // MARK: Private

    private enum Route {
        case browser(UndoManager)
        case page(NSResponder)
        /// The responder chain of this window, or AppKit's own lookup without one.
        case appKit(NSWindow?)
    }

    private typealias TextInputTypeGetter = @convention(c) (AnyObject, Selector) -> Int32

    private static let textInputTypeSelector = NSSelectorFromString("textInputType")

    private var keyMonitor: Any?
    private weak var typedResponder: NSResponder?
    private var typedAt = Date.distantPast

    override init() {
        super.init()
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.noteTyping(event)
            return event
        }
    }

    /// The engine's page view reports the focused element's text input type;
    /// zero means none.
    private static func pageTextInputType(of responder: NSResponder) -> Int32? {
        guard responder.responds(to: textInputTypeSelector),
              let method = class_getInstanceMethod(type(of: responder), textInputTypeSelector)
        else { return nil }
        let getter = unsafeBitCast(method_getImplementation(method), to: TextInputTypeGetter.self)
        return getter(responder, textInputTypeSelector)
    }

    private static func run(_ direction: Direction, on manager: UndoManager) -> Bool {
        switch direction {
        case .undo:
            guard manager.canUndo else { return false }
            manager.undo()
        case .redo:
            guard manager.canRedo else { return false }
            manager.redo()
        }
        return true
    }

    /// The first responder of `window`, or one after it, that takes `selector`.
    private static func chainTarget(for selector: Selector, in window: NSWindow?) -> NSResponder? {
        var responder: NSResponder? = window?.firstResponder ?? window
        while let current = responder {
            if current.responds(to: selector) {
                return current
            }
            responder = current.nextResponder
        }
        return nil
    }

    @objc func undo(_ sender: Any?) {
        perform(.undo, sender: sender)
    }

    @objc func redo(_ sender: Any?) {
        perform(.redo, sender: sender)
    }

    @discardableResult func perform(_ direction: Direction, sender: Any?) -> Bool {
        switch route(direction) {
        case .browser(let manager):
            return Self.run(direction, on: manager)
        case .page(let view):
            return view.tryToPerform(direction.selector, with: sender)
        case .appKit(let window):
            guard let target = Self.chainTarget(for: direction.selector, in: window) else {
                return NSApp.sendAction(direction.selector, to: nil, from: sender)
            }
            // A window's own Undo goes straight to its manager: AppKit's version
            // does nothing while the app is in the background.
            if let window = target as? NSWindow,
               let manager = window.firstResponder?.undoManager ?? window.undoManager
            {
                return Self.run(direction, on: manager)
            }
            return NSApp.sendAction(direction.selector, to: target, from: sender)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let direction: Direction = item.action == Direction.redo.selector ? .redo : .undo
        switch route(direction) {
        case .browser(let manager):
            return validate(item, direction, with: manager)
        case .page:
            item.title = direction == .undo ? BrowserStrings.menuUndo : BrowserStrings.menuRedo
            return true
        case .appKit(let window):
            let target = Self.chainTarget(for: direction.selector, in: window)
                ?? NSApp.target(forAction: direction.selector, to: nil, from: item)
            if let window = target as? NSWindow,
               let manager = window.firstResponder?.undoManager ?? window.undoManager
            {
                return validate(item, direction, with: manager)
            }
            item.title = direction == .undo ? BrowserStrings.menuUndo : BrowserStrings.menuRedo
            if let validator = target as? NSUserInterfaceValidations {
                return validator.validateUserInterfaceItem(item)
            }
            return target != nil
        }
    }

    /// The key window, or the frontmost one while the app is in the
    /// background, for example when a menu item is pressed through accessibility.
    private func route(_ direction: Direction) -> Route {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.parent == nil }
        guard let window, let responder = window.firstResponder,
              let textInputType = Self.pageTextInputType(of: responder)
        else { return .appKit(window) }
        guard let manager = BrowserWindowCommandTarget.topLevelWindow(of: window)?.undoManager
            as? BrowserTabUndoManager
        else { return .page(responder) }
        if textInputType != 0 {
            let typedSince = typedResponder === responder && typedAt > manager.lastTabActionDate
            let browserCan = direction == .undo ? manager.canUndo : manager.canRedo
            if typedSince || !browserCan {
                return .page(responder)
            }
        }
        return .browser(manager)
    }

    /// Remembers the page field the user last typed in.
    private func noteTyping(_ event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let responder = event.window?.firstResponder,
              let type = Self.pageTextInputType(of: responder), type != 0
        else { return }
        typedResponder = responder
        typedAt = Date()
    }

    private func validate(_ item: NSMenuItem, _ direction: Direction, with manager: UndoManager) -> Bool {
        switch direction {
        case .undo:
            item.title = manager.canUndo ? manager.undoMenuItemTitle : BrowserStrings.menuUndo
            return manager.canUndo
        case .redo:
            item.title = manager.canRedo ? manager.redoMenuItemTitle : BrowserStrings.menuRedo
            return manager.canRedo
        }
    }
}
