import AppKit
import Carbon
import IOKit
import LinkCore

/// The current keyboard layout, refreshed when the user switches input source. Main thread only.
final class KeyboardLayout {
    private var data: CFData?
    private var observer: NSObjectProtocol?
    private var cachedMap: KeyLayoutMap?

    /// A specific installed layout (for checks), not following the user's selection.
    init(layoutID: String) {
        let filter = [kTISPropertyInputSourceID as String: layoutID] as CFDictionary
        if let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource], let source = list.first,
           let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        }
    }
    init() {
        refresh()
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }

    private func refresh() {
        cachedMap = nil
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { data = nil; return }
        data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }

    /// The text a key produces with Shift/Option/Caps Lock; dead keys yield their own character.
    func text(for keyCode: UInt16, shift: Bool, option: Bool, capsLock: Bool = false) -> String? {
        guard let data, let bytes = CFDataGetBytePtr(data) else { return nil }
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let modifiers: UInt32 = (shift ? 0x02 : 0) | (capsLock ? 0x04 : 0) | (option ? 0x08 : 0) // Carbon modifiers >> 8
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                           OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// Character-to-key map for this layout, rebuilt after an input-source change.
    var map: KeyLayoutMap {
        if let cachedMap { return cachedMap }
        let map = KeyLayoutMap { code, shift, option in self.text(for: code, shift: shift, option: option) }
        cachedMap = map
        return map
    }
}

enum SystemState {
    /// The app holding macOS secure keyboard input (a password field, or Terminal's Secure Keyboard
    /// Entry). While it is on, macOS hides keystrokes from EtherLink's event tap on this Mac.
    static func secureInputOwner() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]] else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 {
                return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "process \(pid)"
            }
        }
        return nil
    }

    /// Whether this Mac's screen is locked (lock screen or screen saver with password).
    static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
