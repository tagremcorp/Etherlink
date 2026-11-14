import Foundation
import LinkCore

// Standalone test executable: works with Command Line Tools without XCTest/Xcode.
@main
struct CoreChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw LinkError.invalid("FAIL: \(message)") }
    }
    static func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw LinkError.invalid("FAIL: \(label) was accepted")
    }
    static func mergeChecks() throws {
        func packet(_ kind: InputPacket.Kind, dx: Double = 1, dy: Double = 2, button: Int = 0, phase: Int64 = 0, momentum: Int64 = 0, precise: Bool = true) -> InputPacket {
            var p = InputPacket(kind: kind); p.dx = dx; p.dy = dy; p.button = button
            p.phase = phase; p.momentum = momentum; p.precise = precise; return p
        }
        let moves = packet(.move).merged(with: packet(.move, dx: 3, dy: -5))
        try check(moves?.dx == 4 && moves?.dy == -3, "moves merge by summing deltas")
        let drags = packet(.drag, button: 1).merged(with: packet(.drag, dx: 2, dy: 2, button: 1))
        try check(drags?.dx == 3 && drags?.dy == 4 && drags?.button == 1, "drags with the same button merge")
        try check(packet(.drag, button: 0).merged(with: packet(.drag, button: 1)) == nil, "drags with different buttons stay separate")
        try check(packet(.move).merged(with: packet(.drag)) == nil, "move and drag stay separate")
        let scroll = packet(.scroll, phase: 2).merged(with: packet(.scroll, dx: 0, dy: 7, phase: 2))
        try check(scroll?.dy == 9 && scroll?.phase == 2, "mid-gesture scrolls merge")
        try check(packet(.scroll, momentum: 2).merged(with: packet(.scroll, momentum: 2)) != nil, "momentum scrolls merge")
        try check(packet(.scroll, precise: false).merged(with: packet(.scroll, precise: false)) != nil, "wheel line scrolls merge")
        for (a, b) in [(1, 2), (2, 4), (2, 8), (4, 4)] as [(Int64, Int64)] {
            try check(packet(.scroll, phase: a).merged(with: packet(.scroll, phase: b)) == nil, "scroll begin/end/cancel boundaries stay separate")
        }
        try check(packet(.scroll, momentum: 1).merged(with: packet(.scroll, momentum: 2)) == nil, "momentum begin stays separate")
        try check(packet(.scroll, momentum: 2).merged(with: packet(.scroll, momentum: 3)) == nil, "momentum end stays separate")
        try check(packet(.scroll, precise: true).merged(with: packet(.scroll, precise: false)) == nil, "pixel and line scrolls stay separate")
        for kind in [InputPacket.Kind.keyDown, .keyUp, .flags, .buttonDown, .buttonUp] {
            try check(packet(kind).merged(with: packet(kind)) == nil, "keys and buttons never merge")
        }
        let capped = packet(.move, dx: 99_999).merged(with: packet(.move, dx: 99_999))
        try check(capped?.dx == 100_000 && capped?.isValid == true, "merged deltas stay within the wire limit")
        print("PASS input queue coalescing for moves, drags and scrolls")
    }
    static func main() throws {
        try check(Validation.ipv4("172.16.1.5"), "valid IPv4")
        for invalid in ["example.com", "172.16.1.999", "::1", "", "172.16.1.5:123"] {
            try check(!Validation.ipv4(invalid), "reject invalid IPv4")
        }
        print("PASS IPv4 validation")
        let decoded = try Validation.secret(String(repeating: "a1", count: 32))
        try check(decoded == Data(repeating: 0xa1, count: 32), "key decoding")
        try rejects("short key") { _ = try Validation.secret("123456") }
        try rejects("non-hex key") { _ = try Validation.secret(String(repeating: "z", count: 64)) }
        print("PASS pairing key validation")
        // Framing checks run against WireDecoder, the decoder the transport actually uses.
        func frame(_ kind: WireMessage.Kind, _ sequence: UInt64, version: Int = 3) throws -> Data {
            var m = WireMessage(kind); m.sequence = sequence; m.version = version
            var b = try JSONEncoder().encode(m); b.append(10); return b
        }
        var decoder = WireDecoder()
        let first = try frame(.heartbeat, 1), second = try frame(.heartbeat, 2)
        let partial = try decoder.append(first.prefix(5))
        try check(partial.isEmpty, "partial frame")
        let messages = try decoder.append(first.dropFirst(5) + second)
        try check(messages.map(\.sequence) == [1, 2] && messages.allSatisfy { $0.kind == .heartbeat }, "fragmented and coalesced frames")
        print("PASS fragmented and coalesced messages")
        for input in [Data("garbage\n".utf8), Data(repeating: 0x78, count: 2049), try frame(.heartbeat, 1, version: 2),
                      Data("{\"version\":3,\"sequence\":1,\"kind\":\"bogus\"}\n".utf8)] {
            try rejects("malformed, oversized or incompatible frame") {
                var decoder = WireDecoder()
                _ = try decoder.append(input)
            }
        }
        var roomy = WireDecoder()
        let roomyFrames = try roomy.append(Data(repeating: 0x20, count: 2000) + first)
        try check(roomyFrames.count == 1, "frame below the size limit accepted")
        print("PASS malformed, oversized and incompatible message rejection")
        try rejects("replayed sequence") {
            var decoder = WireDecoder()
            _ = try decoder.append(first)
            _ = try decoder.append(first)
        }
        try rejects("older sequence") {
            var decoder = WireDecoder()
            _ = try decoder.append(second)
            _ = try decoder.append(first)
        }
        print("PASS replay rejection")
        var health = LinkHealth(now: 100)
        try check(!health.expired(now: 105), "watchdog boundary")
        try check(health.expired(now: 105.01), "watchdog expiration")
        health.received(now: 106)
        try check(!health.expired(now: 110), "watchdog reset")
        try check(health.expired(now: 112), "watchdog subsequent expiration")
        print("PASS heartbeat watchdog expiration and reset")
        var input = InputPacket(kind: .keyDown)
        input.key = 12; input.flags = 1 << 20
        var wire = WireMessage(.input, input: input); wire.sequence = 1
        var bytes = try JSONEncoder().encode(wire); bytes.append(10)
        var wireDecoder = WireDecoder()
        let split = bytes.count / 2
        let before = try wireDecoder.append(bytes.prefix(split))
        try check(before.isEmpty, "fragmented input must wait for a full frame")
        let after = try wireDecoder.append(bytes.suffix(bytes.count - split))
        try check(after.count == 1 && after[0].input?.key == 12, "physical keycode round trip")
        try rejects("replayed input") { _ = try wireDecoder.append(bytes) }
        try rejects("invalid input packet") {
            var bad = InputPacket(kind: .move); bad.dx = 100_001
            var m = WireMessage(.input, input: bad); m.sequence = 1
            var b = try JSONEncoder().encode(m); b.append(10)
            var d = WireDecoder(); _ = try d.append(b)
        }
        try rejects("input kind without payload") {
            var m = WireMessage(.input); m.sequence = 1
            var b = try JSONEncoder().encode(m); b.append(10)
            var d = WireDecoder(); _ = try d.append(b)
        }
        print("PASS input wire fragmentation, physical keycodes, replay and payload validation")
        var held = PressedInputState()
        var down = InputPacket(kind: .keyDown); down.key = 12
        held.record(down); held.record(down) // autorepeat must not create duplicate releases
        var modifier = InputPacket(kind: .flags); modifier.key = 55; modifier.flags = 1 << 20
        held.record(modifier)
        var button = InputPacket(kind: .buttonDown); button.button = 3
        held.record(button)
        let cleanup = held.drain()
        try check(cleanup.count == 3 && cleanup.allSatisfy { $0.flags == 0 }, "disconnect clears each held key, modifier and extra button once")
        try check(held.drain().isEmpty, "cleanup is idempotent across disconnect and return-control")
        held.record(modifier); modifier.flags = 0; held.record(modifier)
        try check(held.drain().isEmpty, "released modifiers are not retained")
        print("PASS held keys, modifiers and buttons cleanup")
        try SwitchShortcut.defaultShortcut.validate()
        let custom = SwitchShortcut(keyCode: 40, modifiers: SwitchShortcut.command | SwitchShortcut.shift)
        try custom.validate()
        try check(custom.matches(keyCode: 40, modifiers: 12), "custom Command–Shift–K")
        try check(!custom.matches(keyCode: 40, modifiers: 8), "missing modifiers must not switch")
        try check(!custom.matches(keyCode: 40, modifiers: 13), "extra modifiers must not switch")
        try check(!custom.matches(keyCode: 41, modifiers: 12), "different physical key must not switch")
        try rejects("reserved emergency shortcut") { try SwitchShortcut.emergency.validate() }
        try rejects("plain typing shortcut") { try SwitchShortcut(keyCode: 0, modifiers: 0).validate() }
        try rejects("shift-only typing shortcut") { try SwitchShortcut(keyCode: 0, modifiers: SwitchShortcut.shift).validate() }
        try rejects("modifier-only shortcut") { try SwitchShortcut(keyCode: 55, modifiers: SwitchShortcut.control).validate() }
        try rejects("unknown modifier bits") { try SwitchShortcut(keyCode: 100, modifiers: 16).validate() }
        try SwitchShortcut(keyCode: 100, modifiers: 0).validate()
        try check(SwitchShortcut.emergency.matches(keyCode: 53, modifiers: 3), "emergency return stays fixed independently of custom switching")
        print("PASS configurable shortcut matching, defaults and emergency reservation")
        try mergeChecks()
        try roleChecks()
        print("All 11 check groups passed")
    }
}
