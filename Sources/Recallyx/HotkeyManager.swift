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

/// Which hotkey fired. ⌘⇧V (default) opens the history panel; ⌃⇧V (default)
/// grabs the current selection and opens its actions. Both rebindable in
/// Settings.
enum HotkeyAction: CaseIterable {
    case showHistory
    case transformSelection
}

/// Carbon global-hotkey registration, driven by the two `Shortcut`s in
/// `AppSettings`. All changes flow through `apply` (one registration path);
/// the app delegate is the single mutation point that pairs `apply` with the
/// settings write.
@MainActor
final class HotkeyManager {
    /// Per-hotkey outcome of `apply`. `.failed(-9878)` = combo registered
    /// globally by another app (eventHotKeyExistsErr).
    enum ApplyResult: Equatable {
        case ok
        case disabled
        case failed(OSStatus)
    }

    private let onTrigger: @MainActor (HotkeyAction) -> Void
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    private nonisolated static let signature: UInt32 = 0x52584C58 // "RXLX"

    nonisolated static func id(for action: HotkeyAction) -> UInt32 {
        switch action {
        case .showHistory: return 1
        case .transformSelection: return 2
        }
    }

    nonisolated static func action(for id: UInt32) -> HotkeyAction {
        id == Self.id(for: .transformSelection) ? .transformSelection : .showHistory
    }

    init(onTrigger: @escaping @MainActor (HotkeyAction) -> Void) {
        self.onTrigger = onTrigger
        installEventHandler()
    }

    deinit {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Re-register one hotkey: drop the existing ref (if any), then register
    /// the new combo unless the shortcut is disabled.
    func apply(_ action: HotkeyAction, _ shortcut: Shortcut) -> ApplyResult {
        let id = Self.id(for: action)
        if let existing = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(existing)
        }
        guard shortcut.enabled else {
            Log.info("hotkey \(String(describing: action)) disabled")
            return .disabled
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs[id] = ref
            Log.info("RegisterEventHotKey \(shortcut.glyphs.joined()) ok")
            return .ok
        }
        Log.error("RegisterEventHotKey \(shortcut.glyphs.joined()) failed status=\(status) (eventHotKeyExistsErr=-9878, paramErr=-50)")
        return .failed(status)
    }

    /// Unregister both hotkeys while the Settings recorder captures keys —
    /// Carbon swallows a registered combo before the app's local NSEvent
    /// monitor sees it, so recording the current bindings would fire them
    /// instead of capturing.
    func suspend() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        Log.debug("hotkeys suspended for recording")
    }

    /// Re-apply both bindings after recording ends (commit or cancel).
    func resume(searchHistory: Shortcut, transformSelection: Shortcut) {
        _ = apply(.showHistory, searchHistory)
        _ = apply(.transformSelection, transformSelection)
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
        let action = Self.action(for: hkID.id)
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
}
