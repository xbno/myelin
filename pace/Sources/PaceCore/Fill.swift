import Foundation

public enum FillColor: Equatable {
    case used     // green: spent on schedule
    case unspent  // yellow: fill to tick, when behind
    case over     // red: tick to fill, when ahead
    case solid    // a model row's single color
}

/// A colored span of a bar, in percent of the budget.
public struct FillRange: Equatable {
    public let from: Double
    public let to: Double
    public let color: FillColor

    public init(from: Double, to: Double, color: FillColor) {
        self.from = from
        self.to = to
        self.color = color
    }
}

public enum Fill {
    /// A limit that has run out. The whole budget is red, tick or no tick: there is nothing
    /// left to pace, so the bar stops reporting a schedule and reports the block.
    public static let blocked = [FillRange(from: 0, to: 100, color: .over)]

    /// The three-color rule. Green covers 0 to min(used, tick). Exactly one of yellow or red
    /// follows, and it is as long as the miss.
    ///
    /// `exhausted` short-circuits all of it. Without that, a week spent to the last percent on
    /// its first day reads as green for the rest of the week, because the tick keeps catching
    /// up to a bar that cannot move — the one state where "on schedule" is exactly wrong.
    public static func pace(used: Double, tick: Double, exhausted: Bool = false) -> [FillRange] {
        if exhausted { return blocked }
        let u = min(100, max(0, used))
        let t = min(100, max(0, tick))
        var out: [FillRange] = []
        let green = min(u, t)
        if green > 0 { out.append(FillRange(from: 0, to: green, color: .used)) }
        if u < t {
            out.append(FillRange(from: u, to: t, color: .unspent))
        } else if u > t {
            out.append(FillRange(from: t, to: u, color: .over))
        }
        return out
    }

    /// A model row's single color — red once the pool it draws on is spent, for the same
    /// reason: a full bar in the model's own color says "full", not "blocked".
    public static func solid(used: Double, exhausted: Bool = false) -> [FillRange] {
        if exhausted { return blocked }
        let u = min(100, max(0, used))
        return u > 0 ? [FillRange(from: 0, to: u, color: .solid)] : []
    }
}

public enum PaceState: Equatable {
    case onPace
    case over(Int)
    case under(Int)
}

public enum Verdict {
    /// Signed gap in whole points, judged against the on-pace band.
    public static func state(used: Double, tick: Double, band: Double) -> PaceState {
        let d = Int((used - tick).rounded())
        if Double(abs(d)) <= band { return .onPace }
        return d > 0 ? .over(d) : .under(-d)
    }

    public static func text(_ state: PaceState) -> String {
        switch state {
        case .onPace: return "on pace"
        case .over(let d): return "+\(d) over"
        case .under(let d): return "\u{2212}\(d) under"
        }
    }
}
