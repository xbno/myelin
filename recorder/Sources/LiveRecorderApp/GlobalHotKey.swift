import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon (no Accessibility permission, no dependency).
/// ONE event handler dispatches to actions by hotkey id — registering multiple
/// hotkeys with a single handler and distinct ids (the earlier bug: duplicate
/// ids + one handler per key made events collide/double-fire).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                if err == noErr {
                    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                    center.actions[hkID.id]?()
                }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Register a hotkey. Returns false if the OS rejected it (e.g. taken).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandler()
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C52_4B59), id: id)  // 'LRKY'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        actions[id] = action
        refs.append(ref)
        return true
    }
}
