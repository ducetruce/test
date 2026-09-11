import SwiftUI

enum Theme {
    static let sleep = Color(red: 0.42, green: 0.55, blue: 0.95)
    static let readiness = Color(red: 0.36, green: 0.78, blue: 0.68)
    static let activity = Color(red: 0.95, green: 0.62, blue: 0.31)

    static func color(for kind: ScoreKind) -> Color {
        switch kind {
        case .sleep: return sleep
        case .readiness: return readiness
        case .activity: return activity
        }
    }

    static func color(for stage: SleepStage) -> Color {
        switch stage {
        case .deep: return Color(red: 0.20, green: 0.29, blue: 0.71)
        case .light: return Color(red: 0.47, green: 0.60, blue: 0.95)
        case .rem: return Color(red: 0.60, green: 0.46, blue: 0.90)
        case .awake: return Color(red: 0.95, green: 0.68, blue: 0.42)
        }
    }

    /// Traffic-light tint for a 0...100 score.
    static func tint(forScore score: Int) -> Color {
        switch score {
        case 85...: return Color(red: 0.30, green: 0.78, blue: 0.55)
        case 70..<85: return Color(red: 0.45, green: 0.72, blue: 0.95)
        case 60..<70: return Color(red: 0.95, green: 0.75, blue: 0.35)
        default: return Color(red: 0.93, green: 0.45, blue: 0.42)
        }
    }

    static let canvas = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    static let insetBackground = Color.primary.opacity(0.055)
    static let divider = Color.primary.opacity(0.08)
    static let cardRadius: CGFloat = 20

    static func gradient(for kind: ScoreKind) -> LinearGradient {
        LinearGradient(
            colors: [color(for: kind).opacity(0.24), color(for: kind).opacity(0.07)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
