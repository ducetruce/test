import Foundation

/// Piecewise-linear mapping used by every contributor: a handful of control points
/// (input value -> 0...100 score) with linear interpolation between them and clamping
/// outside the ends. Keeping the shape of each metric in one readable table makes the
/// scoring auditable instead of a black box.
enum Curve {
    static func score(_ value: Double, _ points: [(x: Double, y: Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if value <= first.x { return first.y }
        if value >= last.x { return last.y }
        for index in 1..<points.count {
            let lower = points[index - 1]
            let upper = points[index]
            if value <= upper.x {
                let span = upper.x - lower.x
                guard span > 0 else { return upper.y }
                let t = (value - lower.x) / span
                return lower.y + t * (upper.y - lower.y)
            }
        }
        return last.y
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double> = 0...100) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum Stats {
    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1, let average = mean(values) else { return nil }
        let variance = values.reduce(0) { $0 + pow($1 - average, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }
}
