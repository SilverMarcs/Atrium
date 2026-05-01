import AppKit
import Carbon

@safe final class QuickPanelHotKey {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private let signature: UInt32 = 0x41545251 // "ATRQ"
    private let hotKeyID: UInt32 = 1
    private let callback: () -> Void

    static var shared: QuickPanelHotKey?

    init(callback: @escaping () -> Void) {
        self.callback = callback
        register()
    }

    deinit {
        if let hotKeyRef = unsafe hotKeyRef {
            unsafe UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler = unsafe eventHandler {
            unsafe RemoveEventHandler(eventHandler)
        }
    }

    private func register() {
        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        let err = unsafe RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey),
            id,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard err == noErr else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        unsafe InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, _) -> OSStatus in
                var pressedID = EventHotKeyID()
                let err = unsafe GetEventParameter(
                    event,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                if err == noErr {
                    QuickPanelHotKey.shared?.callback()
                    return noErr
                }
                return OSStatus(eventNotHandledErr)
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }
}
