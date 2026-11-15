import Foundation
import CoreGraphics

/// Which side of the keyboard Mac's desktop the other Mac's screen is on.
/// Coordinates are Core Graphics global display space: origin at the main display's top-left, y down.
public enum ScreenSide: String, Codable, CaseIterable {
    case left, right, top, bottom

    public var opposite: ScreenSide {
        switch self { case .left: return .right; case .right: return .left; case .top: return .bottom; case .bottom: return .top }
    }
    /// Pointer motion toward this side (positive) or away from it (negative).
    public func pressure(dx: Double, dy: Double) -> Double {
        switch self { case .left: return -dx; case .right: return dx; case .top: return -dy; case .bottom: return dy }
    }
}

public enum EdgeGeometry {
    /// The display whose `side` edge the point is on, when that edge is an outer edge of the desktop
    /// there: no other display continues beyond it at that point. Edges shared with another display
    /// never count, so a multi-monitor desk only crosses at its true outside edge.
    public static func outerEdgeDisplay(at point: CGPoint, side: ScreenSide, displays: [CGRect], tolerance: CGFloat = 1) -> CGRect? {
        guard let display = displays.first(where: { $0.contains(point) }) else { return nil }
        let atEdge: Bool
        let beyond: CGPoint
        switch side {
        case .left: atEdge = point.x <= display.minX + tolerance; beyond = CGPoint(x: display.minX - 1, y: point.y)
        case .right: atEdge = point.x >= display.maxX - 1 - tolerance; beyond = CGPoint(x: display.maxX + 1, y: point.y)
        case .top: atEdge = point.y <= display.minY + tolerance; beyond = CGPoint(x: point.x, y: display.minY - 1)
        case .bottom: atEdge = point.y >= display.maxY - 1 - tolerance; beyond = CGPoint(x: point.x, y: display.maxY + 1)
        }
        guard atEdge, !displays.contains(where: { $0.contains(beyond) }) else { return nil }
        return display
    }

    /// Position along the edge, 0 at the top/left end and 1 at the bottom/right end.
    public static func position(of point: CGPoint, on display: CGRect, side: ScreenSide) -> Double {
        let value: CGFloat
        switch side {
        case .left, .right: value = display.height > 1 ? (point.y - display.minY) / (display.height - 1) : 0
        case .top, .bottom: value = display.width > 1 ? (point.x - display.minX) / (display.width - 1) : 0
        }
        return Double(min(1, max(0, value)))
    }

    /// The display furthest toward `side` (for `.left`, the leftmost); the larger one wins ties.
    public static func extremeDisplay(side: ScreenSide, displays: [CGRect]) -> CGRect? {
        func reach(_ r: CGRect) -> CGFloat {
            switch side { case .left: return -r.minX; case .right: return r.maxX; case .top: return -r.minY; case .bottom: return r.maxY }
        }
        return displays.max { a, b in
            reach(a) != reach(b) ? reach(a) < reach(b) : a.width * a.height < b.width * b.height
        }
    }

    /// A point just inside the `side` edge of `display`, at `position` along it.
    public static func point(on display: CGRect, side: ScreenSide, position: Double, inset: CGFloat = 3) -> CGPoint {
        let p = CGFloat(min(1, max(0, position.isFinite ? position : 0.5)))
        let x = display.minX + p * (display.width - 1), y = display.minY + p * (display.height - 1)
        switch side {
        case .left: return CGPoint(x: display.minX + inset, y: y)
        case .right: return CGPoint(x: display.maxX - 1 - inset, y: y)
        case .top: return CGPoint(x: x, y: display.minY + inset)
        case .bottom: return CGPoint(x: x, y: display.maxY - 1 - inset)
        }
    }
}

/// Requires a deliberate push against an edge before switching, so brushing the edge, or throwing
/// the pointer at the menu bar or Dock, does nothing. Pressure counts only after the pointer has
/// stayed against the edge for `dwell`, and must reach `threshold` within the last `window` seconds.
public struct EdgePush {
    public let threshold: Double
    public let window: TimeInterval
    public let dwell: TimeInterval
    /// A pause longer than this between movements ends the contact with the edge.
    public static let contactGap: TimeInterval = 0.25
    private var contact: TimeInterval?
    private var last: TimeInterval = -.infinity
    private var samples: [(time: TimeInterval, amount: Double)] = []
    public init(threshold: Double = 40, window: TimeInterval = 0.35, dwell: TimeInterval = 0) {
        self.threshold = threshold; self.window = window; self.dwell = dwell
    }

    /// Adds pointer motion toward the edge. Returns true once enough has built up.
    public mutating func push(_ amount: Double, now: TimeInterval) -> Bool {
        guard amount.isFinite else { return false }
        if amount < 0 { reset(); return false }
        if now - last > Self.contactGap { reset() }
        last = now
        let began = contact ?? now
        contact = began
        guard now - began >= dwell else { return false }
        samples.append((now, amount))
        samples.removeAll { now - $0.time > window }
        guard samples.reduce(0, { $0 + $1.amount }) >= threshold else { return false }
        reset()
        return true
    }
    public mutating func reset() { samples.removeAll(keepingCapacity: true); contact = nil; last = -.infinity }
}

/// How hard the pointer must be pushed against the edge. Top and bottom edges need more, because
/// the menu bar and Dock are there.
public enum EdgePushLevel: String, Codable, CaseIterable {
    case light, medium, firm

    public func push(for side: ScreenSide) -> EdgePush {
        let vertical = side == .top || side == .bottom
        switch self {
        case .light: return vertical ? EdgePush(threshold: 60, dwell: 0.10) : EdgePush(threshold: 40, dwell: 0)
        case .medium: return vertical ? EdgePush(threshold: 100, dwell: 0.20) : EdgePush(threshold: 60, dwell: 0.08)
        case .firm: return vertical ? EdgePush(threshold: 200, dwell: 0.35) : EdgePush(threshold: 120, dwell: 0.15)
        }
    }
}

extension EdgeGeometry {
    /// The ends of an edge never switch, so hot corners and corner clicks keep working.
    public static let cornerMargin = 0.04
    public static func inCorner(_ position: Double) -> Bool { position < cornerMargin || position > 1 - cornerMargin }
}

/// What macOS reports about a monitor's hardware. Two Macs plugged into the same monitor
/// (for example in PBP mode) usually see the same values.
public struct DisplayIdentity: Codable, Equatable, Hashable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public init(vendor: UInt32, model: UInt32, serial: UInt32) { self.vendor = vendor; self.model = model; self.serial = serial }
    /// Same vendor and model; serial numbers must agree when both are known (many monitors report 0).
    public func matches(_ other: DisplayIdentity) -> Bool {
        vendor == other.vendor && model == other.model && vendor != 0
            && (serial == other.serial || serial == 0 || other.serial == 0)
    }
}

/// A display the user chose for edge switching, saved so it survives restarts: the system's
/// display UUID, plus the hardware identity as a fallback when the UUID changes.
public struct DisplayChoice: Equatable {
    public var key: String
    public var identity: DisplayIdentity
    public init(key: String, identity: DisplayIdentity) { self.key = key; self.identity = identity }
    public init?(stored: String) {
        let parts = stored.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, !parts[0].isEmpty, let v = UInt32(parts[1]), let m = UInt32(parts[2]), let s = UInt32(parts[3]) else { return nil }
        self.init(key: String(parts[0]), identity: DisplayIdentity(vendor: v, model: m, serial: s))
    }
    public var stored: String { "\(key)|\(identity.vendor)|\(identity.model)|\(identity.serial)" }
}

/// Decides which of this Mac's displays adjoins the other Mac's screen.
public enum SharedDisplay {
    public enum Resolution: Equatable {
        /// Only this display's edge switches (index into the local list).
        case display(Int)
        /// Not known: any outer edge on the chosen side switches, as in 0.4.0.
        case any
        /// The chosen display is not connected, so edge switching is paused.
        case unavailable
    }
    /// How `resolve` reached its answer, for the settings caption.
    public enum Source: Equatable { case chosen, onlyDisplay, matchedPeer, undetected, missing }

    public static func resolve(choice: DisplayChoice?, local: [(key: String, identity: DisplayIdentity)],
                               peer: [DisplayIdentity]) -> (resolution: Resolution, source: Source) {
        if let choice {
            if let index = local.firstIndex(where: { $0.key == choice.key }) { return (.display(index), .chosen) }
            let same = local.indices.filter { local[$0].identity == choice.identity }
            if same.count == 1 { return (.display(same[0]), .chosen) }
            if local.count == 1 { return (.display(0), .onlyDisplay) }
            return (.unavailable, .missing)
        }
        if local.count == 1 { return (.display(0), .onlyDisplay) }
        let matched = local.indices.filter { index in peer.contains { $0.matches(local[index].identity) } }
        if matched.count == 1 { return (.display(matched[0]), .matchedPeer) }
        return (.any, .undetected)
    }
}
