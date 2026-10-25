// BrowserBeforeUnloadConfirmationTests.swift

import AppKit
import Testing

// MARK: - BrowserBeforeUnloadConfirmationTests

@Suite(.serialized)
@MainActor struct BrowserBeforeUnloadConfirmationTests {
    @Test func confirmationKeepsTabByDefaultAndResolvesOnce() throws {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        let presenter = BeforeUnloadPresenter()
        var results = [Bool]()
        let confirmation = BrowserBeforeUnloadConfirmation(window: window, presenter: presenter.present) {
            results.append($0)
        }
        confirmation.present()
        confirmation.present()
        #expect(presenter.presentations == 1)
        let alert = try #require(presenter.alert)
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].title == BrowserStrings.beforeUnloadKeepTab)
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].title == BrowserStrings.beforeUnloadCloseTab)
        #expect(alert.buttons[1].keyEquivalent.isEmpty)
        #expect(results.isEmpty)
        presenter.reply?(.alertFirstButtonReturn)
        presenter.reply?(.alertSecondButtonReturn)
        confirmation.cancel()
        #expect(results == [false])
    }

    @Test func explicitConfirmationResolvesTrueAndLateCancellationCannotChangeIt() {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        let presenter = BeforeUnloadPresenter()
        var results = [Bool]()
        let confirmation = BrowserBeforeUnloadConfirmation(window: window, presenter: presenter.present) {
            results.append($0)
        }
        confirmation.present()
        presenter.reply?(.alertSecondButtonReturn)
        confirmation.cancel()
        presenter.reply?(.alertFirstButtonReturn)
        #expect(results == [true])
    }

    @Test func supersededPromptCannotConfirmFromLateNativeReply() {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        let presenter = BeforeUnloadPresenter()
        var results = [Bool]()
        let confirmation = BrowserBeforeUnloadConfirmation(window: window, presenter: presenter.present) {
            results.append($0)
        }
        confirmation.present()
        confirmation.cancel()
        confirmation.cancel()
        presenter.reply?(.alertSecondButtonReturn)
        #expect(results == [false])
        #expect(presenter.presentations == 1)
    }

    @Test func escapeCancelsOnlyItsOwnSheetAndReturnRemainsTheSafeDefault() {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        let presenter = BeforeUnloadPresenter()
        var results = [Bool]()
        let confirmation = BrowserBeforeUnloadConfirmation(window: window, presenter: presenter.present) {
            results.append($0)
        }
        confirmation.present()
        // An offscreen NSAlert deliberately has no WindowServer number. Supply
        // the event's owner directly instead of showing the sheet to obtain one.
        let foreignEscape = BeforeUnloadKeyEvent(window: window, code: 53)
        let modifiedEscape = BeforeUnloadKeyEvent(window: confirmation.alert.window, code: 53, modifiers: .command)
        let enter = BeforeUnloadKeyEvent(window: confirmation.alert.window, code: 36)
        let escape = BeforeUnloadKeyEvent(window: confirmation.alert.window, code: 53)
        #expect(escape.window === confirmation.alert.window)
        #expect(!confirmation.handleKeyEvent(foreignEscape))
        #expect(!confirmation.handleKeyEvent(modifiedEscape))
        #expect(!confirmation.handleKeyEvent(enter))
        #expect(confirmation.alert.buttons[0].keyEquivalent == "\r")
        #expect(results.isEmpty)
        #expect(confirmation.handleKeyEvent(escape))
        presenter.reply?(.alertSecondButtonReturn)
        #expect(results == [false])
        #expect(!confirmation.handleKeyEvent(escape))
    }

    @Test func missingWindowFailsClosedWithoutPresenting() {
        let presenter = BeforeUnloadPresenter()
        var results = [Bool]()
        let confirmation = BrowserBeforeUnloadConfirmation(window: nil, presenter: presenter.present) {
            results.append($0)
        }
        confirmation.present()
        confirmation.present()
        #expect(results == [false])
        #expect(presenter.presentations == 0)
    }
}

// MARK: - BeforeUnloadPresenter

@MainActor private final class BeforeUnloadPresenter {
    private(set) var presentations = 0
    private(set) var alert: NSAlert?
    private(set) var reply: (@MainActor (NSApplication.ModalResponse) -> Void)?

    func present(_ alert: NSAlert, _: NSWindow, reply: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        presentations += 1
        self.alert = alert
        self.reply = reply
    }
}

// MARK: - BeforeUnloadKeyEvent

/// The production monitor reads these public NSEvent properties. Overriding
/// `window` avoids WindowServer lookup for the deliberately unpresented sheet.
private final class BeforeUnloadKeyEvent: NSEvent {
    // MARK: Internal

    override var window: NSWindow? { ownerWindow }
    override var type: NSEvent.EventType { .keyDown }
    override var keyCode: UInt16 { code }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }

    // MARK: Private

    private let ownerWindow: NSWindow
    private let code: UInt16
    private let modifiers: NSEvent.ModifierFlags

    init(window: NSWindow, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.ownerWindow = window
        self.code = code
        self.modifiers = modifiers
        super.init()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
