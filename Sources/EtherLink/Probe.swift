import Foundation
import Darwin
import Combine
import LinkCore

/// Headless transport diagnostics. Secrets are read from the environment, never logged.
enum Probe {
    /// Checks the real keyboard layout: every key's character must resolve back to a key that types it.
    static func layoutCheck() {
        let layout = KeyboardLayout()
        let map = layout.map
        var checked = 0, failures: [String] = []
        for code in UInt16(0)..<128 {
            for (shift, option) in [(false, false), (true, false), (false, true), (true, true)] {
                guard let text = layout.text(for: code, shift: shift, option: option), KeyLayoutMap.isPrintable(text) else { continue }
                checked += 1
                guard let chord = map.resolve(text, original: code, shift: shift, option: option),
                      layout.text(for: chord.keyCode, shift: chord.shift, option: chord.option) == text else {
                    failures.append("key \(code) shift=\(shift) option=\(option) “\(text)”"); continue
                }
            }
        }
        let sample = [(UInt16(0), "a"), (6, "z"), (16, "y"), (18, "1")].map { code, _ in "\(code)=\(layout.text(for: code, shift: false, option: false) ?? "nil")" }
        print("Layout sample: \(sample.joined(separator: " ")); shift+2 = \(layout.text(for: 19, shift: true, option: false) ?? "nil")")
        print(failures.isEmpty ? "PASS: \(checked) characters on this Mac's layout resolve back to a key that types them" : "FAIL: \(failures.prefix(10))")
        // Cross-layout: type every character of this Mac's layout on a German (QWERTZ) Mac.
        let german = KeyboardLayout(layoutID: "com.apple.keylayout.German")
        let germanMap = german.map
        var typed = 0, unmappable = 0, wrong: [String] = []
        for code in UInt16(0)..<51 {
            for shift in [false, true] {
                guard let text = layout.text(for: code, shift: shift, option: false), KeyLayoutMap.isPrintable(text) else { continue }
                guard let chord = germanMap.resolve(text, original: code, shift: shift, option: false) else { unmappable += 1; continue }
                typed += 1
                if german.text(for: chord.keyCode, shift: chord.shift, option: chord.option) != text { wrong.append(text) }
            }
        }
        let z = germanMap.resolve("z", original: 6, shift: false, option: false)
        let at = germanMap.resolve("@", original: 19, shift: true, option: false)
        print("German: z -> key \(z.map { "\($0.keyCode)" } ?? "none"); @ -> key \(at.map { "\($0.keyCode) shift=\($0.shift) option=\($0.option)" } ?? "none")")
        print(wrong.isEmpty && typed > 0 ? "PASS: \(typed) main-keyboard characters from this layout type the same character on German QWERTZ (\(unmappable) not on that layout, sent as text)" : "FAIL: \(wrong.prefix(10)) typed=\(typed)")
        exit(failures.isEmpty && wrong.isEmpty && typed > 0 ? 0 : 1)
    }
    private static var discoveryTimer: DispatchSourceTimer?
    private static var roleObservers = Set<AnyCancellable>()
    static func run() {
        let args = CommandLine.arguments
        guard args.count == 6, let key = ProcessInfo.processInfo.environment["ETHERLINK_TEST_KEY"] else {
            fputs("Usage: ETHERLINK_TEST_KEY=<key> EtherLink --probe listen|connect interface localIPv4 peerIPv4\n", stderr)
            exit(2)
        }
        let session = LinkSession()
        let reconnect = ProcessInfo.processInfo.environment["ETHERLINK_PROBE_RECONNECT"] == "1"
        session.autoReconnectEnabled = reconnect
        var rounds = 0
        var stalled = false
        let stall = Double(ProcessInfo.processInfo.environment["ETHERLINK_PROBE_UI_STALL"] ?? "0") ?? 0
        let hold = Double(ProcessInfo.processInfo.environment["ETHERLINK_PROBE_HOLD"] ?? "2") ?? 2
        let roleChoice = ProcessInfo.processInfo.environment["ETHERLINK_PROBE_ROLE_CHOICE"]
        if let roleChoice {
            session.input.$rolePromptVisible.filter { $0 }.sink { _ in
                DispatchQueue.main.async {
                    print("ROLE PROMPT SHOWN"); fflush(stdout)
                    if roleChoice != "wait" { session.input.chooseKeyboardSource(here: roleChoice == "here") }
                }
            }.store(in: &roleObservers)
            session.input.$roleConfirmed.filter { $0 }.sink { _ in
                DispatchQueue.main.async {
                    print("ROLE CONFIRMED: \(session.input.keyboardMac ? "SOURCE" : "RECEIVER")"); fflush(stdout)
                }
            }.store(in: &roleObservers)
        }
        // Prints each status line, optionally stalls the UI queue once after pairing, and exits on stop.
        let printStatus: (String) -> Void = { message in
            print(message); fflush(stdout)
            if !stalled && stall > 0 && message.hasPrefix("Paired") {
                stalled = true; print("Pausing UI queue for \(stall) seconds"); fflush(stdout)
                Thread.sleep(forTimeInterval: stall)
                print("UI queue resumed"); fflush(stdout)
            }
            if !session.running && !reconnect { exit(1) }
        }
        session.onStatus = printStatus
        session.onHeartbeat = { count in
            if count == 3 {
                if roleChoice != nil && !session.input.roleConfirmed { return }
                rounds += 1
                print("PASS: authenticated heartbeats\n\(session.pathDescription)"); fflush(stdout)
                if !reconnect || rounds >= 2 {
                    if reconnect { print("PASS: automatically reconnected"); fflush(stdout) }
                    session.onHeartbeat = nil
                    session.onStatus = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + hold) { exit(0) }
                }
            }
        }
        var started = false
        let discover = DispatchSource.makeTimerSource(queue: .main)
        discover.schedule(deadline: .now() + 0.2, repeating: 0.2)
        discover.setEventHandler {
            guard !started, let adapter = session.adapters.first(where: { $0.name == args[3] && $0.address == args[4] }) else { return }
            started = true
            // start first resets the prior session, so ignore its initial Disconnected notice.
            session.onStatus = nil
            session.start(adapter: adapter, peer: args[5], secret: key, listen: args[2] == "listen")
            print(session.status); fflush(stdout)
            session.onStatus = printStatus
            if !session.running && !reconnect { exit(1) }
        }
        discoveryTimer = discover
        discover.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { fputs("Probe timed out. Available adapters: \(session.adapters.map(\.label)); \(session.discoveryStatus)\n", stderr); exit(3) }
        dispatchMain()
    }
}
