import Carbon
import Foundation

private let hermesHotKeySignature: OSType = 0x484D4F4E // HMON
private let hermesHotKeyIdentifier: UInt32 = 1

private let hermesHotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID(signature: 0, id: 0)
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let controller = Unmanaged<GlobalHotKeyController>
        .fromOpaque(userData)
        .takeUnretainedValue()
    Task { @MainActor in
        controller.handle(hotKeyID: hotKeyID)
    }
    return noErr
}

enum GlobalHotKeyRegistrationError: LocalizedError {
    case installHandler(OSStatus)
    case registerHotKey(OSStatus)

    var errorDescription: String? {
        switch self {
        case .installHandler(let status):
            return "Could not install the global hotkey handler (OSStatus \(status))."
        case .registerHotKey(let status):
            return "Could not register the configured global hotkey (OSStatus \(status))."
        }
    }
}

@MainActor
final class GlobalHotKeyController {
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let action: () -> Void
    private let preference: MonitorHotKeyPreference

    init(
        defaults: UserDefaults = .standard,
        action: @escaping () -> Void
    ) {
        self.preference = MonitorPreferences.hotKey(defaults: defaults)
        self.action = action
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register() throws {
        guard hotKey == nil, eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hermesHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            eventHandler = nil
            throw GlobalHotKeyRegistrationError.installHandler(handlerStatus)
        }

        let hotKeyID = EventHotKeyID(
            signature: hermesHotKeySignature,
            id: hermesHotKeyIdentifier
        )
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKey
        )
        guard registrationStatus == noErr else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
            }
            eventHandler = nil
            hotKey = nil
            throw GlobalHotKeyRegistrationError.registerHotKey(registrationStatus)
        }
    }

    fileprivate func handle(hotKeyID: EventHotKeyID) {
        guard hotKeyID.signature == hermesHotKeySignature,
              hotKeyID.id == hermesHotKeyIdentifier else {
            return
        }
        action()
    }

    private var keyCode: UInt32 {
        switch preference.key {
        case "J": return UInt32(kVK_ANSI_J)
        case "K": return UInt32(kVK_ANSI_K)
        case "L": return UInt32(kVK_ANSI_L)
        case "M": return UInt32(kVK_ANSI_M)
        default: return UInt32(kVK_ANSI_H)
        }
    }

    private var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if preference.usesCommand { modifiers |= UInt32(cmdKey) }
        if preference.usesShift { modifiers |= UInt32(shiftKey) }
        if preference.usesOption { modifiers |= UInt32(optionKey) }
        if preference.usesControl { modifiers |= UInt32(controlKey) }
        return modifiers
    }
}
