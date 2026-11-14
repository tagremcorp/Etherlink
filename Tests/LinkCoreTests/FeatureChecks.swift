import Foundation
import CoreGraphics
import LinkCore

extension CoreChecks {
    static func edgeChecks() throws {
        // A 1920×1080 display with a second to its right and a third below it.
        let a = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let b = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let c = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let displays = [a, b, c]
        try check(EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 1919.5, y: 500), side: .right, displays: displays) == nil, "edge shared with another display never crosses")
        try check(EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 3839, y: 500), side: .right, displays: displays) == b, "outer right edge crosses")
        try check(EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 3000, y: 500), side: .right, displays: displays) == nil, "middle of a display is not an edge")
        try check(EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 1000, y: 1079.5), side: .bottom, displays: displays) == nil, "bottom edge above another display never crosses")
        try check(EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 2500, y: 1079), side: .bottom, displays: displays) == b, "bottom edge with nothing below crosses")
        try check(EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 0, y: 1500), side: .left, displays: displays) == c, "left outer edge crosses")
        try check(EdgeGeometry.position(of: CGPoint(x: 3839, y: 0), on: b, side: .right) == 0, "edge position at the top")
        try check(EdgeGeometry.position(of: CGPoint(x: 3839, y: 1079), on: b, side: .right) == 1, "edge position at the bottom")
        try check(abs(EdgeGeometry.position(of: CGPoint(x: 960, y: 2159), on: c, side: .bottom) - 960.0 / 1919) < 1e-9, "edge position along a horizontal edge")
        try check(EdgeGeometry.extremeDisplay(side: .right, displays: displays) == b, "rightmost display")
        try check(EdgeGeometry.extremeDisplay(side: .bottom, displays: displays) == c, "lowest display")
        try check(EdgeGeometry.extremeDisplay(side: .left, displays: displays)?.minX == 0, "leftmost display")
        let entry = EdgeGeometry.point(on: b, side: .left, position: 0.5)
        try check(entry.x == 1923 && abs(entry.y - 539.5) < 1e-9 && b.contains(entry), "entry point is just inside the edge, at the matching height")
        try check(EdgeGeometry.outerEdgeDisplay(at: EdgeGeometry.point(on: b, side: .right, position: 0.3), side: .right, displays: displays) == nil, "a returned pointer is not left on the crossing edge")
        try check(ScreenSide.right.opposite == .left && ScreenSide.top.opposite == .bottom, "opposite sides")
        try check(ScreenSide.left.pressure(dx: -5, dy: 0) == 5 && ScreenSide.bottom.pressure(dx: 0, dy: -3) == -3, "pressure toward a side")
        var push = EdgePush(threshold: 40, window: 0.35)
        try check(!push.push(15, now: 1.0) && !push.push(15, now: 1.1), "a light touch does not switch")
        try check(push.push(15, now: 1.2), "a deliberate push switches")
        try check(!push.push(30, now: 2.0) && !push.push(30, now: 2.5), "pressure spread out over time does not add up")
        _ = push.push(30, now: 3.0)
        try check(!push.push(-1, now: 3.1) && !push.push(30, now: 3.2), "moving away resets the push")
        print("PASS screen-edge geometry, outer edges with multiple displays, positions and push threshold")
    }

    static func layoutChecks() throws {
        // Small fake layouts: US QWERTY and German QWERTZ swap Y/Z, and type @ differently.
        func layout(_ table: [UInt16: (String, String, String?)]) -> KeyLayoutMap {
            KeyLayoutMap { code, shift, option in
                guard let keys = table[code] else { return nil }
                if option { return shift ? nil : keys.2 }
                return shift ? keys.1 : keys.0
            }
        }
        let us = layout([6: ("z", "Z", "Ω"), 16: ("y", "Y", "¥"), 19: ("2", "@", "™"), 18: ("1", "!", "¡"), 37: ("l", "L", "¬"),
                         83: ("1", "1", nil), 36: ("\r", "\r", nil), 123: ("\u{F702}", "\u{F702}", nil)])
        let de = layout([6: ("y", "Y", "¥"), 16: ("z", "Z", "Ω"), 19: ("2", "\"", "“"), 18: ("1", "!", "¡"), 37: ("l", "L", "@")])
        try check(us.resolve("z", original: 16, shift: false, option: false) == KeyChord(keyCode: 6, shift: false, option: false), "German z types z on a US Mac")
        try check(us.resolve("Z", original: 16, shift: true, option: false) == KeyChord(keyCode: 6, shift: true, option: false), "shifted letters follow")
        try check(us.resolve("@", original: 37, shift: false, option: true) == KeyChord(keyCode: 19, shift: true, option: false), "German Option-L @ becomes US Shift-2")
        try check(de.resolve("@", original: 19, shift: true, option: false) == KeyChord(keyCode: 37, shift: false, option: true), "US Shift-2 @ becomes German Option-L")
        try check(us.resolve("y", original: 16, shift: false, option: false) == KeyChord(keyCode: 16, shift: false, option: false), "matching layouts keep the original key")
        try check(us.resolve("1", original: 50, shift: false, option: false)?.keyCode == 18, "the main row is preferred over the keypad")
        try check(us.resolve("1", original: 83, shift: false, option: false)?.keyCode == 83, "a keypad key stays a keypad key")
        try check(us.resolve("é", original: 14, shift: false, option: false) == nil, "a character the layout cannot type is reported")
        try check(!KeyLayoutMap.isPrintable("\r") && !KeyLayoutMap.isPrintable("\u{F702}") && !KeyLayoutMap.isPrintable(""), "Return, arrows and empty text are not translated")
        try check(KeyLayoutMap.isPrintable("é") && KeyLayoutMap.isPrintable(" ") && !KeyLayoutMap.isPrintable("abcde"), "printable text limits")
        print("PASS keyboard layout translation: swapped letters, symbols on different keys, keypad and unmappable characters")
    }

    static func wireFieldChecks() throws {
        func roundTrip(_ m: WireMessage) throws -> [WireMessage] {
            var m = m; m.sequence = 1
            var data = try JSONEncoder().encode(m); data.append(10)
            var decoder = WireDecoder(); return try decoder.append(data)
        }
        var take = WireMessage(.takeControl); take.edge = "right"; take.position = 0.25
        let decoded = try roundTrip(take)
        try check(decoded.first?.edge == "right" && decoded.first?.position == 0.25, "edge and position survive the wire")
        var key = InputPacket(kind: .keyDown); key.key = 6; key.text = "z"
        let keyText = try roundTrip(.init(.input, input: key)).first?.input?.text
        try check(keyText == "z", "key text survives the wire")
        var denied = WireMessage(.denied); denied.reason = "Not ready"
        let reason = try roundTrip(denied).first?.reason
        try check(reason == "Not ready", "reason survives the wire")
        let legacy = Data("{\"version\":3,\"sequence\":1,\"kind\":\"takeControl\"}\n".utf8)
        var legacyDecoder = WireDecoder()
        let legacyMessages = try legacyDecoder.append(legacy)
        try check(legacyMessages.count == 1 && legacyMessages[0].edge == nil, "messages from 0.3.x without the new fields still decode")
        var badEdge = WireMessage(.takeControl); badEdge.edge = "diagonal"
        try rejects("unknown edge") { _ = try roundTrip(badEdge) }
        var badPosition = WireMessage(.returnControl); badPosition.position = 1.5
        try rejects("edge position outside 0...1") { _ = try roundTrip(badPosition) }
        var badText = InputPacket(kind: .move); badText.text = "a"
        try rejects("text on a mouse packet") { _ = try roundTrip(.init(.input, input: badText)) }
        var controlText = InputPacket(kind: .keyDown); controlText.text = "\n"
        try rejects("control character as key text") { _ = try roundTrip(.init(.input, input: controlText)) }
        var longReason = WireMessage(.granted); longReason.reason = String(repeating: "x", count: 241)
        try rejects("oversized reason") { _ = try roundTrip(longReason) }
        print("PASS edge, key text and reason fields: round trip, 0.3.x compatibility and validation")
    }
}
