import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey via Carbon RegisterEventHotKey (the only stable API for
/// global shortcuts). Does not require Accessibility permission.
final class GlobalHotKey {
    static let keyR = UInt32(kVK_ANSI_R)
    // Distinct modifier bits, so addition equals bitwise-or (avoids the pipe character).
    static let controlShift = UInt32(controlKey) + UInt32(shiftKey)

    private var ref: EventHotKeyRef?
    private let action: () -> Void
    private let id: UInt32

    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = Self.nextID
        Self.nextID += 1
        Self.installHandlerIfNeeded()
        Self.registry[id] = self

        let hotKeyID = EventHotKeyID(signature: OSType(0x50415050), id: id)  // 'PAPP'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        AppLog.log("RegisterEventHotKey status=\(status) registered=\(ref != nil)")
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.registry[id] = nil
    }

    fileprivate func fire() { AppLog.log("hotkey fired"); action() }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async { GlobalHotKey.registry[hkID.id]?.fire() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
