import AppKit
import Carbon.HIToolbox
import Foundation

private func hotkeyCarbonCallback(
    _ callRef: EventHandlerCallRef?,
    _ eventRef: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    return manager.handleHotkeyEvent(eventRef)
}

/// Which hotkey fired. ⌘⇧V opens the history panel; ⌃⇧V (wired in a later
/// commit) grabs the current selection and opens its actions.
enum HotkeyAction {
    case showHistory
    case transformSelection
}

@MainActor
final class HotkeyManager {
    private let onTrigger: @MainActor (HotkeyAction) -> Void
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    private nonisolated static let signature: UInt32 = 0x52584C58 // "RXLX"
    private nonisolated static let historyID: UInt32 = 1
    private nonisolated static let selectionID: UInt32 = 2

    /// `registerSelection` is gated so ⌃⇧V isn't grabbed before its handler
    /// exists (it lands in the transform-selection commit).
    init(registerSelection: Bool = false, onTrigger: @escaping @MainActor (HotkeyAction) -> Void) {
        self.onTrigger = onTrigger
        installEventHandler()
        register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), id: Self.historyID, label: "⌘⇧V")
        if registerSelection {
            register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey), id: Self.selectionID, label: "⌃⇧V")
        }
    }

    deinit {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    nonisolated func handleHotkeyEvent(_ eventRef: EventRef?) -> OSStatus {
        var hkID = EventHotKeyID()
        if let eventRef {
            GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
        }
        let action: HotkeyAction = hkID.id == Self.selectionID ? .transformSelection : .showHistory
        Task { @MainActor in
            Log.debug("hotkey fired id=\(hkID.id)")
            self.onTrigger(action)
        }
        return noErr
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyCarbonCallback,
            1,
            &spec,
            context,
            &handlerRef
        )
        Log.info("InstallEventHandler status=\(status) (noErr=0)")
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, label: String) {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
            Log.info("RegisterEventHotKey \(label) ok")
        } else {
            Log.error("RegisterEventHotKey \(label) failed status=\(status) (eventHotKeyExistsErr=-9878, paramErr=-50)")
        }
    }
}
