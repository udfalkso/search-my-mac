import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotKeyController {
    static let shared = GlobalHotKeyController()
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func start() {
        guard hotKey == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
                    NotificationCenter.default.post(name: .focusSearchMyMacField, object: nil)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        let signature = OSType(0x534D4D43) // SMMC
        let identifier = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }
}
