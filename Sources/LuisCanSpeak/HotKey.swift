import Carbon
import Foundation

/// A system-wide hotkey. Carbon's RegisterEventHotKey works without the
/// Accessibility permission, which an event tap would need.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// keyCode is a virtual key code (for example kVK_Space).
    /// modifiers uses Carbon flags (controlKey, optionKey, cmdKey, shiftKey).
    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.action() }
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4356_4F43), id: 1)  // "CVOC"
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
