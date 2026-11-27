import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Arbor's answer to Win+E: a system-wide shortcut that opens a new Arbor window from any app.
/// Uses Carbon's RegisterEventHotKey, which needs no Accessibility permission and works sandboxed.
enum HotKeyChoice: String, CaseIterable {
    case off, optionCommandE, controlOptionE, controlCommandE, optionCommandSpace

    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .optionCommandE: return "⌥⌘E"
        case .controlOptionE: return "⌃⌥E"
        case .controlCommandE: return "⌃⌘E"
        case .optionCommandSpace: return String(localized: "⌥⌘Space")
        }
    }

    fileprivate var keyAndModifiers: (UInt32, UInt32)? {
        switch self {
        case .off: return nil
        case .optionCommandE: return (UInt32(kVK_ANSI_E), UInt32(optionKey | cmdKey))
        case .controlOptionE: return (UInt32(kVK_ANSI_E), UInt32(controlKey | optionKey))
        case .controlCommandE: return (UInt32(kVK_ANSI_E), UInt32(controlKey | cmdKey))
        case .optionCommandSpace: return (UInt32(kVK_Space), UInt32(optionKey | cmdKey))
        }
    }
}

final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?

    private init() {}

    /// Registers the shortcut chosen in Folder Options. Returns false if another app already owns it.
    @discardableResult
    func apply(_ choice: HotKeyChoice) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let (key, modifiers) = choice.keyAndModifiers else { return true }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4152_4252), id: 1)  // 'ARBR'
        let status = RegisterEventHotKey(key, modifiers, id, GetEventDispatcherTarget(), 0, &hotKey)
        return status == noErr
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// "Open Arbor at login", so the hotkey works right after you log in.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message when macOS refuses (for example, the app isn't in /Applications).
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
