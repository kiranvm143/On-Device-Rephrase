import AppKit
import Carbon.HIToolbox

/// System-wide hotkey via Carbon's RegisterEventHotKey (no Accessibility needed for this part).
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        HotKey.installHandlerOnce()
        let id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.handlers[id] = handler

        var carbonMods: UInt32 = 0
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5250_4852) /* "RPHR" */, id: id)
        isRegistered = RegisterEventHotKey(keyCode, carbonMods, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    /// False if another app already owns this shortcut.
    private(set) var isRegistered = false

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            Log.write("hotkey: pressed id=\(hkID.id)")
            DispatchQueue.main.async { HotKey.handlers[hkID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
