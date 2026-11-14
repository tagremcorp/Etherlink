import Foundation

public struct InputPacket: Codable {
    public enum Kind: String, Codable { case keyDown, keyUp, flags, move, drag, buttonDown, buttonUp, scroll }
    public var kind: Kind
    public var key: UInt16 = 0
    public var flags: UInt64 = 0
    public var dx: Double = 0
    public var dy: Double = 0
    public var button: Int = 0
    public var clicks: Int = 1
    public var precise: Bool = false
    public var autorepeat: Bool = false
    public var phase: Int64 = 0
    public var momentum: Int64 = 0
    public init(kind: Kind) { self.kind = kind }
    public var isValid: Bool {
        key <= 255 && (0...31).contains(button) && (0...4).contains(clicks)
        && dx.isFinite && dy.isFinite && abs(dx) <= 100_000 && abs(dy) <= 100_000
        && (0...255).contains(phase) && (0...255).contains(momentum)
    }
}

public struct WireMessage: Codable {
    public enum Kind: String, Codable { case hello, heartbeat, takeControl, granted, releaseControl, returnControl, input, denied
        case roleSetupRequest, rolePrompt, roleChoice, roleAssignment, roleAck, roleConfirmed, roleCancel }
    public var version = 3
    public var sequence: UInt64 = 0
    public var kind: Kind
    public var deviceID: String?
    public var deviceName: String?
    public var roleRound: String?
    public var assignmentID: String?
    public var sourceDeviceID: String?
    public var input: InputPacket?
    public init(_ kind: Kind, input: InputPacket? = nil) {
        self.kind = kind; self.input = input
    }
}

public struct WireDecoder {
    private let json = JSONDecoder()
    private var buffer = Data()
    private var lastSequence: UInt64 = 0
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [WireMessage] {
        var result: [WireMessage] = []
        for byte in bytes {
            if byte != 10 {
                guard buffer.count < 2048 else { throw LinkError.invalid("Oversized message.") }
                buffer.append(byte); continue
            }
            let message = try json.decode(WireMessage.self, from: buffer)
            buffer.removeAll(keepingCapacity: true)
            guard message.version == 3 else { throw LinkError.invalid("Install the same EtherLink version on both Macs.") }
            guard message.sequence > lastSequence else { throw LinkError.invalid("Out-of-order message.") }
            guard message.input?.isValid != false,
                  (message.kind == .input) == (message.input != nil),
                  message.kind != .hello || (message.deviceID != nil && message.deviceName != nil) else { throw LinkError.invalid("Invalid input message.") }
            lastSequence = message.sequence; result.append(message)
        }
        return result
    }
}

extension InputPacket {
    /// Combines a queued, not-yet-sent motion packet with the next one so a brief stall cannot
    /// fill the send queue. Moves merge with moves, drags with drags of the same button, and
    /// scrolls only mid-gesture (no begin/end/cancel boundary) with matching phase and units.
    /// Returns nil when the two packets must stay separate.
    public func merged(with next: InputPacket) -> InputPacket? {
        guard kind == next.kind else { return nil }
        switch kind {
        case .move: break
        case .drag: guard button == next.button else { return nil }
        case .scroll:
            // CGScrollPhase 0 = none, 2 = changed; CGMomentumScrollPhase 0 = none, 2 = continue.
            guard precise == next.precise, phase == next.phase, momentum == next.momentum,
                  phase == 0 || phase == 2, momentum == 0 || momentum == 2 else { return nil }
        default: return nil
        }
        var result = next
        result.dx = min(100_000, max(-100_000, dx + next.dx))
        result.dy = min(100_000, max(-100_000, dy + next.dy))
        return result
    }
}

/// Only currently held state is retained, never a keystroke history.
public struct PressedInputState {
    private var keys = Set<UInt16>()
    private var buttons = Set<Int>()
    public init() {}
    public mutating func record(_ p: InputPacket) {
        switch p.kind {
        case .keyDown: keys.insert(p.key)
        case .keyUp: keys.remove(p.key)
        case .buttonDown: buttons.insert(p.button)
        case .buttonUp: buttons.remove(p.button)
        case .flags:
            let mask: UInt64
            switch p.key {
            case 54, 55: mask = 1 << 20
            case 56, 60: mask = 1 << 17
            case 58, 61: mask = 1 << 19
            case 59, 62: mask = 1 << 18
            case 63: mask = 1 << 23
            default: mask = 0
            }
            if mask != 0 && p.flags & mask != 0 { keys.insert(p.key) }
            else { keys.remove(p.key) }
        default: break
        }
    }
    public mutating func drain() -> [InputPacket] {
        let releases = keys.sorted().map { key -> InputPacket in
            var p = InputPacket(kind: .keyUp); p.key = key; return p
        } + buttons.sorted().map { button -> InputPacket in
            var p = InputPacket(kind: .buttonUp); p.button = button; return p
        }
        keys.removeAll(); buttons.removeAll()
        return releases
    }
}

extension WireMessage.Kind {
    public var isRoleMessage: Bool {
        switch self {
        case .hello, .roleSetupRequest, .rolePrompt, .roleChoice, .roleAssignment, .roleAck, .roleConfirmed, .roleCancel: return true
        default: return false
        }
    }
}
