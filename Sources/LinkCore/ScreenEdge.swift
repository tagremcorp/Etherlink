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

/// Requires a deliberate push against an edge before switching, so brushing the edge does nothing.
public struct EdgePush {
    public let threshold: Double
    public let window: TimeInterval
    private var accumulated = 0.0
    private var last: TimeInterval = -.infinity
    public init(threshold: Double = 40, window: TimeInterval = 0.35) { self.threshold = threshold; self.window = window }

    /// Adds pointer motion toward the edge. Returns true once enough has built up within the window.
    public mutating func push(_ amount: Double, now: TimeInterval) -> Bool {
        guard amount.isFinite else { return false }
        if amount < 0 { reset(); return false }
        if now - last > window { accumulated = 0 }
        last = now
        accumulated += amount
        guard accumulated >= threshold else { return false }
        reset()
        return true
    }
    public mutating func reset() { accumulated = 0; last = -.infinity }
}
