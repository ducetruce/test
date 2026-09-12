import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedKind: ScoreKind?

    private var day: Day { model.selectedDay }
    private var dayScores: DayScores { model.dayScores(for: day) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    dashboardHeader
                    DayStrip(selection: $model.selectedDay, days: model.allSyncedDays())

                    if dayScores.sleep == nil && dayScores.readiness == nil && dayScores.activity == nil {
                        EmptyStateView(
                            symbol: "moon.zzz",
                            title: "No data for \(Format.dayLabel(day))",
                            message: model.isConnected
                                ? "Pull down to sync. Oura publishes a night once the ring has synced with your phone."
                                : "Connect to Oura in Settings to start syncing."
                        )
                    } else {
                        scoreCarousel
                        if let signal = dailySignal {
                            DailySignalCard(
                                title: signal.contributor.rounded < 70
                                    ? "Worth watching: \(signal.contributor.label)"
                                    : "Steady signal: \(signal.contributor.label)",
                                detail: signal.contributor.detail,
                                score: signal.contributor.rounded,
                                tint: Theme.color(for: signal.kind)
                            )
                        }
                        if let expandedKind, let expandedScore = score(for: expandedKind) {
                            breakdownCard(expandedScore)
                        }
                        highlights
                        napsAndWorkouts
                    }
                }
                .padding(16)
            }
            .clearsTabBar()
            .background(Theme.canvas)
            .navigationTitle("Overview")
            .navigationBarTitleDisplayMode(.inline)
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

    private var dashboardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Format.dayLabel(day))
                    .font(.largeTitle.weight(.bold))
                Text(syncStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if day == Day.today {
                Image(systemName: model.isSyncing ? "arrow.triangle.2.circlepath" : "checkmark.icloud")
                    .foregroundStyle(model.isSyncing ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var syncStatus: String {
        if model.isSyncing { return "Updating your data…" }
        if let lastSync = model.lastSync { return "Last updated \(Format.relative(lastSync))" }
        return "Not synced yet"
    }

    private var scoreCarousel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your scores")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ScoreKind.allCases, id: \.self) { kind in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedKind = expandedKind == kind ? nil : kind
                            }
                        } label: {
                            ScoreSummaryCard(score: score(for: kind), kind: kind)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the score contributors")
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private func breakdownCard(_ score: Score) -> some View {
        SectionCard(
            "\(score.kind.title) details",
            subtitle: subtitle(for: score),
            symbol: "list.bullet.rectangle",
            tint: Theme.color(for: score.kind)
        ) {
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
                ForEach(score.contributors) { contributor in
                    ContributorRow(contributor: contributor)
                }
                Button("Close details") {
                    withAnimation { expandedKind = nil }
                }
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

        SectionCard("Highlights", subtitle: "Measurements behind today's scores", symbol: "waveform.path.ecg") {
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
                if let stress = model.database.stressDay(day) {
                    if let high = stress.stressHigh {
                        StatTile(label: "Stressful time", value: Format.duration(high), caption: stress.summary?.replacingOccurrences(of: "_", with: " ").capitalized, tint: Theme.activity)
                    }
                    if let recovery = stress.recoveryHigh {
                        StatTile(label: "Restorative time", value: Format.duration(recovery), caption: nil, tint: Theme.readiness)
                    }
                }
                if let resilience = model.database.resilienceDay(day), let level = resilience.level {
                    StatTile(label: "Resilience", value: level.replacingOccurrences(of: "_", with: " ").capitalized, caption: nil, tint: Theme.readiness)
                }
                if let cva = model.database.latestCardiovascularAge?.vascularAge {
                    StatTile(label: "Cardiovascular age", value: "\(Int(cva.rounded())) yrs", caption: ageCaption(cva), tint: Theme.readiness)
                }
                if let vo2 = model.database.latestVO2Max?.vo2Max {
                    StatTile(label: "VO₂ max", value: Format.number(vo2, decimals: 1), caption: "ml/kg/min", tint: Theme.activity)
                }
                if let window = model.database.sleepTimeDay(day)?.window {
                    StatTile(label: "Ideal bedtime", value: "\(window.start)–\(window.end)", caption: nil, tint: Theme.sleep)
                }
            }
        }
    }

    private var baselines: ScoreEngine.Baselines {
        ScoreEngine().baselines(before: day, in: model.database)
    }

    /// Cardiovascular age only means something next to actual age.
    private func ageCaption(_ vascularAge: Double) -> String? {
        guard let age = model.database.personalInfo?.age else { return nil }
        let delta = Int(vascularAge.rounded()) - age
        if delta == 0 { return "Same as your age" }
        return delta < 0 ? "\(-delta) yrs younger than you" : "\(delta) yrs older than you"
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
        let sessions = model.database.sessionsOn(day)
        let tags = model.database.tagsOn(day)

        if !naps.isEmpty || !workouts.isEmpty || !sessions.isEmpty || !tags.isEmpty {
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
                    ForEach(sessions) { session in
                        LabeledContent {
                            Text(Format.duration(session.duration))
                                .monospacedDigit()
                        } label: {
                            Label(session.type.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "wind")
                        }
                    }
                    ForEach(tags) { tag in
                        Label(
                            tag.labels.joined(separator: ", ") + (tag.comment.map { " — \($0)" } ?? ""),
                            systemImage: "tag"
                        )
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

    private var dailySignal: (kind: ScoreKind, contributor: Contributor)? {
        ScoreKind.allCases
            .compactMap { kind in score(for: kind).map { (kind, $0) } }
            .flatMap { kind, score in score.contributors.map { (kind: kind, contributor: $0) } }
            .min { $0.contributor.score < $1.contributor.score }
    }
}

/// Horizontally scrolling day selector pinned to the top of Today.
///
/// `days` now spans the full synced history rather than a fixed recent window (see
/// `AppModel.allSyncedDays`), so this can be handed several hundred entries — lazy, not
/// eager, so scrolling doesn't have to build every button up front.
struct DayStrip: View {
    @Binding var selection: Day
    var days: [Day]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
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
