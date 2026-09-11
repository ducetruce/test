import SwiftUI

struct SectionCard<Content: View>: View {
    var title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color?
    var content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        symbol: String? = nil,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint ?? Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background((tint ?? Color.accentColor).opacity(0.13), in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        }
    }
}

struct StatTile: View {
    var label: String
    var value: String
    var caption: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Compact headline card for one of the three daily scores. It carries enough context to
/// stand alone without exposing the full contributor calculation up front.
struct ScoreSummaryCard: View {
    var score: Score?
    var kind: ScoreKind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: symbol)
                    .foregroundStyle(Theme.color(for: kind))
            }

            HStack(spacing: 12) {
                ScoreRingView(score: score?.value, kind: kind, lineWidth: 8, showsLabel: false)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(score?.label ?? "No data")
                        .font(.headline)
                    if let score, score.isPartial {
                        Text("Partial · \(Int((score.coverage * 100).rounded()))% inputs")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("View contributors")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 190, alignment: .leading)
        .padding(16)
        .background(Theme.gradient(for: kind), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.color(for: kind).opacity(0.2), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch kind {
        case .sleep: return "moon.stars.fill"
        case .readiness: return "heart.text.square.fill"
        case .activity: return "figure.walk"
        }
    }
}

struct DailySignalCard: View {
    var title: String
    var detail: String
    var score: Int
    var tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: score >= 70 ? "sparkles" : "scope")
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Text("\(score)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(18)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.divider, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A page-level score treatment that keeps the headline prominent and the full
/// calculation available without making every contributor compete for attention.
struct ScoreDetailCard: View {
    var score: Score
    @State private var showsContributors = false

    var body: some View {
        SectionCard(
            "\(score.kind.title) score",
            subtitle: scoreSubtitle,
            symbol: symbol,
            tint: Theme.color(for: score.kind)
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    ScoreRingView(score: score.value, kind: score.kind, lineWidth: 9, showsLabel: false)
                        .frame(width: 88, height: 88)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(score.label)
                            .font(.title2.weight(.semibold))
                        Text(score.isPartial
                             ? "Based on \(Int((score.coverage * 100).rounded()))% of expected inputs"
                             : "Based on \(score.availableContributorCount) contributors")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsContributors.toggle()
                    }
                } label: {
                    HStack {
                        Text(showsContributors ? "Hide contributors" : "See contributors")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(showsContributors ? 180 : 0))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.color(for: score.kind))
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)

                if showsContributors {
                    Divider()
                    if score.isPartial {
                        Label(
                            "Missing inputs are re-weighted, so compare this score with care.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 14) {
                        ForEach(score.contributors) { ContributorRow(contributor: $0) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var scoreSubtitle: String {
        guard let cloudValue = score.cloudValue, cloudValue != score.value else {
            return score.isPartial ? "Partial estimate" : "Today's estimate"
        }
        return "Local estimate · Oura reports \(cloudValue)"
    }

    private var symbol: String {
        switch score.kind {
        case .sleep: return "moon.stars.fill"
        case .readiness: return "heart.text.square.fill"
        case .activity: return "figure.walk"
        }
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
