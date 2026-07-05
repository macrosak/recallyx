import AppKit
import Carbon.HIToolbox
import Foundation
import RecallyxCore

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

/// Pure bookkeeping for per-action hotkey ids — no Carbon. Tracks which saved
/// action (by its `Action.id.uuidString` token) owns which Carbon `EventHotKeyID`
/// numeric id, assigning a deterministic base id per token and linear-probing on
/// the astronomically-unlikely hash collision. Keyed only on the token, so the
/// mapping is stable across launches and action-list reorders. Unit-tested; the
/// `HotkeyManager` layers the real Carbon refs on top of it (the "registerless
/// seam" so the bookkeeping is testable without registering global hotkeys).
struct HotkeyIDRegistry {
    private(set) var tokenByID: [UInt32: String] = [:]
    private(set) var idByToken: [String: UInt32] = [:]

    /// Deterministic base id for a token: an FNV-1a hash folded above the two
    /// reserved builtin ids (1, 2). Same token → same id, every time.
    static func baseID(forToken token: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261 // FNV-1a offset basis
        for byte in token.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return 100 + (hash % 0x00FF_FF00) // ≥100, clear of ids 1/2
    }

    /// Assign (or return the existing) id for `token`. Linear-probes past any id
    /// already owned by a different token.
    mutating func assign(_ token: String) -> UInt32 {
        if let existing = idByToken[token] { return existing }
        var id = Self.baseID(forToken: token)
        while let owner = tokenByID[id], owner != token {
            id = (id == UInt32.max) ? 100 : id &+ 1
        }
        tokenByID[id] = token
        idByToken[token] = id
        return id
    }

    mutating func remove(_ token: String) {
        if let id = idByToken.removeValue(forKey: token) { tokenByID[id] = nil }
    }

    mutating func removeAll() {
        tokenByID.removeAll()
        idByToken.removeAll()
    }

    func token(forID id: UInt32) -> String? { tokenByID[id] }
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
    /// Fired with a saved action's `id.uuidString` when its bound global hotkey
    /// is pressed. The app delegate maps it back to the `Action` and runs it on
    /// the current selection.
    private let onActionTrigger: @MainActor (String) -> Void
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    /// Live Carbon refs for the per-action hotkeys, keyed by action token.
    private var actionHotKeyRefs: [String: EventHotKeyRef] = [:]
    /// Pure token↔id bookkeeping backing `actionHotKeyRefs`.
    private var registry = HotkeyIDRegistry()
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

    init(
        onTrigger: @escaping @MainActor (HotkeyAction) -> Void,
        onActionTrigger: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.onTrigger = onTrigger
        self.onActionTrigger = onActionTrigger
        installEventHandler()
    }

    deinit {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        for ref in actionHotKeyRefs.values { UnregisterEventHotKey(ref) }
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

    /// Re-register one per-action hotkey (keyed by the action's id token): drop
    /// any existing ref, then register the new combo unless disabled/unset. Same
    /// Carbon-first contract as `apply` — the app delegate writes settings only on
    /// success.
    @discardableResult
    func applyAction(token: String, _ shortcut: Shortcut) -> ApplyResult {
        if let existing = actionHotKeyRefs.removeValue(forKey: token) {
            UnregisterEventHotKey(existing)
        }
        registry.remove(token)
        guard shortcut.enabled, shortcut.keyCode != 0 else {
            return .disabled
        }

        let id = registry.assign(token)
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
            actionHotKeyRefs[token] = ref
            Log.info("RegisterEventHotKey action \(shortcut.glyphs.joined()) ok")
            return .ok
        }
        // Registration failed — release the id assignment we just made.
        registry.remove(token)
        Log.error("RegisterEventHotKey action \(shortcut.glyphs.joined()) failed status=\(status)")
        return .failed(status)
    }

    /// Re-register ALL per-action hotkeys from a token→shortcut map. Drops every
    /// prior action registration first (so a deleted/renamed/rebound action
    /// releases its combo), then registers each enabled binding. Used at launch
    /// and on every settings change.
    func applyAllActions(_ shortcuts: [String: Shortcut]) {
        for ref in actionHotKeyRefs.values { UnregisterEventHotKey(ref) }
        actionHotKeyRefs.removeAll()
        registry.removeAll()
        for (token, shortcut) in shortcuts { _ = applyAction(token: token, shortcut) }
    }

    /// Unregister every hotkey while the Settings recorder captures keys —
    /// Carbon swallows a registered combo before the app's local NSEvent
    /// monitor sees it, so recording the current bindings would fire them
    /// instead of capturing.
    func suspend() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        for ref in actionHotKeyRefs.values { UnregisterEventHotKey(ref) }
        actionHotKeyRefs.removeAll()
        registry.removeAll()
        Log.debug("hotkeys suspended for recording")
    }

    /// Re-apply all bindings after recording ends (commit or cancel).
    func resume(searchHistory: Shortcut, transformSelection: Shortcut, actionShortcuts: [String: Shortcut]) {
        _ = apply(.showHistory, searchHistory)
        _ = apply(.transformSelection, transformSelection)
        applyAllActions(actionShortcuts)
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
        let firedID = hkID.id
        Task { @MainActor in
            Log.debug("hotkey fired id=\(firedID)")
            if firedID == Self.id(for: .showHistory) {
                self.onTrigger(.showHistory)
            } else if firedID == Self.id(for: .transformSelection) {
                self.onTrigger(.transformSelection)
            } else if let token = self.registry.token(forID: firedID) {
                self.onActionTrigger(token)
            }
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
