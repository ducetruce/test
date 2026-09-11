import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedKind: ScoreKind?

    private var day: Day { model.selectedDay }
    private var dayScores: DayScores { model.dayScores(for: day) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DayStrip(selection: $model.selectedDay, days: model.recentDays(14, endingAt: Day.today))

                    if dayScores.sleep == nil && dayScores.readiness == nil && dayScores.activity == nil {
                        EmptyStateView(
                            symbol: "moon.zzz",
                            title: "No data for \(Format.dayLabel(day))",
                            message: model.isConnected
                                ? "Pull down to sync. Oura publishes a night once the ring has synced with your phone."
                                : "Add your Oura personal access token in Settings to start syncing."
                        )
                    } else {
                        ringRow
                        ForEach(ScoreKind.allCases, id: \.self) { kind in
                            if let score = score(for: kind) {
                                breakdownCard(score)
                            }
                        }
                        highlights
                        napsAndWorkouts
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(Format.dayLabel(day))
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await model.sync() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isSyncing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await model.sync() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Sync now")
                    }
                }
            }
        }
    }

    private var ringRow: some View {
        HStack(spacing: 12) {
            ForEach(ScoreKind.allCases, id: \.self) { kind in
                ScoreRingView(score: score(for: kind)?.value, kind: kind)
                    .frame(height: 108)
            }
        }
        .padding(.vertical, 4)
    }

    private func breakdownCard(_ score: Score) -> some View {
        SectionCard(score.kind.title, subtitle: subtitle(for: score)) {
            VStack(spacing: 14) {
                if score.isPartial {
                    Label(
                        "Missing inputs are re-weighted, so this is not directly comparable to a full day's score.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(visibleContributors(of: score)) { contributor in
                    ContributorRow(contributor: contributor)
                }
                if score.contributors.count > 3 {
                    Button(expandedKind == score.kind ? "Show less" : "Show all \(score.contributors.count) contributors") {
                        withAnimation { expandedKind = expandedKind == score.kind ? nil : score.kind }
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func visibleContributors(of score: Score) -> [Contributor] {
        if expandedKind == score.kind { return score.contributors }
        return Array(score.contributors.sorted { $0.score < $1.score }.prefix(3))
    }

    private func subtitle(for score: Score) -> String {
        var text = "\(score.value) · \(score.label)"
        if score.isPartial {
            // Say so rather than letting a number built from a third of its inputs read
            // like one built from all of them.
            text += " · partial, \(Int((score.coverage * 100).rounded()))% of inputs"
        }
        if let cloud = score.cloudValue, cloud != score.value {
            text += " · Oura says \(cloud)"
        }
        return text
    }

    @ViewBuilder
    private var highlights: some View {
        let night = model.database.mainSleep(on: day)
        let activity = model.database.activityDay(day)
        let spo2 = model.database.spo2Day(day)
        let readiness = model.database.readinessDay(day)

        SectionCard("Highlights") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                if let night {
                    StatTile(label: "Time asleep", value: Format.duration(night.totalSleep), caption: "\(Format.clockTime(night.bedtimeStart)) – \(Format.clockTime(night.bedtimeEnd))", tint: Theme.sleep)
                    if let rhr = night.lowestHeartRate {
                        StatTile(label: "Resting HR", value: "\(Int(rhr.rounded())) bpm", caption: baselineCaption(value: rhr, baseline: baselines.restingHeartRate, unit: "bpm"), tint: Theme.readiness)
                    }
                    if let hrv = night.averageHRV {
                        StatTile(label: "Average HRV", value: "\(Int(hrv.rounded())) ms", caption: baselineCaption(value: hrv, baseline: baselines.hrv, unit: "ms"), tint: Theme.readiness)
                    }
                    if let breath = night.averageBreath {
                        StatTile(label: "Respiratory rate", value: Format.number(breath, decimals: 1) + " /min", caption: nil, tint: Theme.readiness)
                    }
                }
                if let deviation = readiness?.temperatureDeviation {
                    StatTile(label: "Temperature", value: String(format: "%+.2f °C", deviation), caption: "Deviation from baseline", tint: Theme.readiness)
                }
                if let spo2 = spo2?.averagePercentage {
                    StatTile(label: "Blood oxygen", value: Format.number(spo2, decimals: 1) + "%", caption: nil, tint: Theme.readiness)
                }
                if let activity {
                    StatTile(label: "Steps", value: Format.integer(activity.steps), caption: nil, tint: Theme.activity)
                    StatTile(label: "Active calories", value: "\(Int(activity.activeCalories.rounded())) kcal", caption: "Target \(Int(activity.targetCalories.rounded()))", tint: Theme.activity)
                }
            }
        }
    }

    private var baselines: ScoreEngine.Baselines {
        ScoreEngine().baselines(before: day, in: model.database)
    }

    private func baselineCaption(value: Double, baseline: Double?, unit: String) -> String? {
        guard let baseline else { return "Building baseline" }
        let delta = value - baseline
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(Int(delta.rounded())) \(unit) vs baseline"
    }

    @ViewBuilder
    private var napsAndWorkouts: some View {
        let naps = model.database.naps(on: day)
        let workouts = model.database.workoutSessions(day)

        if !naps.isEmpty || !workouts.isEmpty {
            SectionCard("Also today") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(naps) { nap in
                        LabeledContent {
                            Text(Format.duration(nap.totalSleep))
                                .monospacedDigit()
                        } label: {
                            Label("Nap at \(Format.clockTime(nap.bedtimeStart))", systemImage: "zzz")
                        }
                    }
                    ForEach(workouts) { workout in
                        LabeledContent {
                            Text(Format.duration(workout.duration))
                                .monospacedDigit()
                        } label: {
                            Label(workout.label ?? workout.activity.capitalized, systemImage: "figure.run")
                        }
                    }
                }
                .font(.subheadline)
            }
        }
    }

    private func score(for kind: ScoreKind) -> Score? {
        switch kind {
        case .sleep: return dayScores.sleep
        case .readiness: return dayScores.readiness
        case .activity: return dayScores.activity
        }
    }
}

/// Horizontally scrolling day selector pinned to the top of Today.
struct DayStrip: View {
    @Binding var selection: Day
    var days: [Day]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days) { day in
                        Button {
                            selection = day
                        } label: {
                            VStack(spacing: 2) {
                                Text(shortWeekday(day))
                                    .font(.caption2)
                                Text("\(day.day)")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }
                            .frame(width: 44, height: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(day == selection ? Color.accentColor.opacity(0.2) : Theme.cardBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.accentColor, lineWidth: day == selection ? 1.5 : 0)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(day)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .trailing) }
        }
    }

    private func shortWeekday(_ day: Day) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: day.startOfDay())
    }
}
