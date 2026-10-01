import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey (no Accessibility permission needed).
/// Each instance installs its own handler and only claims events carrying its own id, so several
/// hotkeys can coexist (⌃⌥P and ⌃⌥N).
@MainActor
final class Hotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    fileprivate let hotkeyID: UInt32

    static let signature = OSType(0x4E48_5542) // 'NHUB'

    init?(keyCode: UInt32,
          modifiers: UInt32 = UInt32(controlKey | optionKey),
          id: UInt32,
          action: @escaping () -> Void) {
        self.action = action
        self.hotkeyID = id

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard status == noErr, pressed.signature == Hotkey.signature,
                      pressed.id == hotkey.hotkeyID else { return false }
                hotkey.fire()
                return true
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, context, &handlerRef)
        guard installed == noErr else { return nil }

        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let registered = RegisterEventHotKey(keyCode, modifiers, hkID,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    /// ⌃⌥P: start / pause the Pomodoro.
    static func pomodoro(_ action: @escaping () -> Void) -> Hotkey? {
        Hotkey(keyCode: UInt32(kVK_ANSI_P), id: 1, action: action)
    }

    /// ⌃⌥N: expand / collapse the notch panel.
    static func panel(_ action: @escaping () -> Void) -> Hotkey? {
        Hotkey(keyCode: UInt32(kVK_ANSI_N), id: 2, action: action)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    fileprivate func fire() { action() }
}
