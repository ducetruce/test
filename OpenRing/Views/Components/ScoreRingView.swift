import SwiftUI

/// The circular 0-100 gauge used for each of the three headline scores.
struct ScoreRingView: View {
    var score: Int?
    var kind: ScoreKind
    var lineWidth: CGFloat = 12
    var showsLabel: Bool = true

    private var fraction: Double {
        guard let score else { return 0 }
        return Double(score) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.color(for: kind).opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    Theme.color(for: kind),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)

            VStack(spacing: 2) {
                if let score {
                    Text("\(score)")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if showsLabel {
                    Text(kind.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.title)
        .accessibilityValue(score.map { "\($0) out of 100" } ?? "No data")
    }
}

/// Small horizontal bar for a single contributor inside a score breakdown.
struct ContributorRow: View {
    var contributor: Contributor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(contributor.label)
                    .font(.subheadline)
                Spacer()
                Text("\(contributor.rounded)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tint(forScore: contributor.rounded))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Theme.tint(forScore: contributor.rounded))
                        .frame(width: proxy.size.width * min(max(contributor.score / 100, 0), 1))
                }
            }
            .frame(height: 6)
            Text(contributor.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
