import AppKit
import Carbon.HIToolbox

// MARK: - BrowserGlobalHotKey

/// A shortcut that works while another app is active, such as
/// Option-Command-N for the small window. Carbon hot keys need no Accessibility
/// permission; the system delivers them on the main thread.
@MainActor final class BrowserGlobalHotKey {
    // MARK: Lifecycle

    /// Nil when another app already holds the key combination.
    init?(keyCode: UInt32, carbonModifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                let hotKey = Unmanaged<BrowserGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    guard pressed.signature == BrowserGlobalHotKey.signature, pressed.id == hotKey.identifier else {
                        return OSStatus(eventNotHandledErr)
                    }
                    hotKey.action()
                    return noErr
                }
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        Self.nextIdentifier += 1
        self.identifier = Self.nextIdentifier
        let registerStatus = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: identifier),
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard handlerStatus == noErr, registerStatus == noErr else {
            unregister()
            return nil
        }
    }

    isolated deinit {
        unregister()
    }

    // MARK: Internal

    /// New Small Window from any app.
    static func newLittleWindow(action: @escaping () -> Void) -> BrowserGlobalHotKey? {
        BrowserGlobalHotKey(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: UInt32(cmdKey | optionKey), action: action)
    }

    // MARK: Private

    /// 'TBHK'
    private static let signature: OSType = 0x5442_484B
    private static var nextIdentifier: UInt32 = 0

    private let action: () -> Void
    private var identifier: UInt32 = 0
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
        hotKey = nil
        handler = nil
    }
}
