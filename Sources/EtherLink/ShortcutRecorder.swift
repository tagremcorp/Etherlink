import AppKit
import SwiftUI
import LinkCore

struct ShortcutRecorder: NSViewRepresentable {
    var onRecorded: (SwitchShortcut, String) -> Void
    var onError: (String) -> Void
    var onRecordingChanged: (Bool) -> Void
    func makeNSView(context: Context) -> RecorderButton { RecorderButton(frame: .zero) }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onRecorded = onRecorded; view.onError = onError; view.onRecordingChanged = onRecordingChanged
        view.isEnabled = context.environment.isEnabled
        if !view.isEnabled { view.finish() }
    }
    static func dismantleNSView(_ view: RecorderButton, coordinator: ()) { view.finish() }
}

final class RecorderButton: NSButton {
    var onRecorded: ((SwitchShortcut, String) -> Void)?
    var onError: ((String) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var monitor: Any?
    private var recording = false
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Record custom shortcut…"; bezelStyle = .rounded
        target = self; action = #selector(beginRecording)
        setAccessibilityLabel("Record custom switching shortcut")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    @objc private func beginRecording() {
        guard !recording else { finish(); return }
        guard window?.makeFirstResponder(self) == true else { return }
        recording = true; title = "Press shortcut (Esc cancels)…"
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording, self.window?.isKeyWindow == true,
                  self.window?.firstResponder === self else { return event }
            let modifiers = Self.modifiers(event.modifierFlags)
            if event.keyCode == 53 && modifiers == 0 { self.finish(); return nil }
            let shortcut = SwitchShortcut(keyCode: event.keyCode, modifiers: modifiers)
            do {
                try shortcut.validate()
                let name = Self.keyName(event)
                self.finish(); self.onRecorded?(shortcut, name)
            } catch {
                self.onError?(error.localizedDescription)
            }
            return nil
        }
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    func finish() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if recording { recording = false; onRecordingChanged?(false) }
        title = "Record custom shortcut…"
    }
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.control) ? SwitchShortcut.control : 0)
        | (flags.contains(.option) ? SwitchShortcut.option : 0)
        | (flags.contains(.shift) ? SwitchShortcut.shift : 0)
        | (flags.contains(.command) ? SwitchShortcut.command : 0)
    }
    private static func keyName(_ event: NSEvent) -> String {
        let names: [UInt16: String] = [36:"Return",48:"Tab",49:"Space",51:"Delete",53:"Escape",71:"Clear",76:"Keypad Enter",115:"Home",116:"Page Up",117:"Forward Delete",119:"End",121:"Page Down",123:"Left Arrow",124:"Right Arrow",125:"Down Arrow",126:"Up Arrow",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        if let name = names[event.keyCode] { return name }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
           !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return characters.uppercased() }
        return "Key \(event.keyCode)"
    }
}
