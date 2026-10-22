import AppKit
import Carbon.HIToolbox

/// Global shortcuts registered through the Carbon hotkey API, which — unlike an
/// event tap — needs no Accessibility permission.
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x4E4F5459   // 'NOTY'

    private init() {}

    func register(newNote: @escaping () -> Void,
                  showDeck: @escaping () -> Void) {
        installHandler()
        add(id: 1, key: UInt32(kVK_ANSI_N), mods: UInt32(optionKey | cmdKey), action: newNote)
        add(id: 2, key: UInt32(kVK_ANSI_A), mods: UInt32(optionKey | cmdKey), action: showDeck)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return noErr }
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.actions[hkID.id]?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func add(id: UInt32, key: UInt32, mods: UInt32, action: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(key, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            actions[id] = action
            refs.append(ref)
        } else {
            NSLog("Noty: hotkey \(id) unavailable (status \(status)) — another app may own it")
        }
    }

    func unregisterAll() {
        refs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }
}
