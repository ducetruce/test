import SwiftUI
import Charts

struct SleepView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedDay: Day?

    private var day: Day { selectedDay ?? model.selectedDay }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    DayStrip(
                        selection: Binding(get: { day }, set: { selectedDay = $0 }),
                        days: model.recentDays(14, endingAt: Day.today)
                    )

                    if let night = model.database.mainSleep(on: day) {
                        if let score = model.dayScores(for: day).sleep {
                            ScoreDetailCard(score: score)
                        }
                        stagesCard(night)
                        vitalsCard(night)
                        recentNightsCard
                    } else {
                        EmptyStateView(
                            symbol: "bed.double",
                            title: "No sleep recorded",
                            message: "Nothing was recorded for \(Format.dayLabel(day))."
                        )
                        recentNightsCard
                    }
                }
                .padding(16)
            }
            .background(Theme.canvas)
            .navigationTitle("Sleep")
            .refreshable { await model.sync() }
        }
    }

    private func stagesCard(_ night: SleepPeriod) -> some View {
        SectionCard(
            Format.duration(night.totalSleep) + " asleep",
            subtitle: "\(Format.clockTime(night.bedtimeStart)) – \(Format.clockTime(night.bedtimeEnd)) · \(Format.duration(night.timeInBed)) in bed",
            symbol: "bed.double.fill",
            tint: Theme.sleep
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Hypnogram(stages: night.stages, start: night.bedtimeStart, end: night.bedtimeEnd)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatTile(label: "Deep", value: Format.duration(night.deep), caption: share(night.deep, of: night.totalSleep), tint: Theme.color(for: .deep))
                    StatTile(label: "REM", value: Format.duration(night.rem), caption: share(night.rem, of: night.totalSleep), tint: Theme.color(for: .rem))
                    StatTile(label: "Light", value: Format.duration(night.light), caption: share(night.light, of: night.totalSleep), tint: Theme.color(for: .light))
                    StatTile(label: "Awake", value: Format.duration(night.awake), caption: share(night.awake, of: night.timeInBed), tint: Theme.color(for: .awake))
                }
            }
        }
    }

    @ViewBuilder
    private func vitalsCard(_ night: SleepPeriod) -> some View {
        if let heartRate = night.heartRate, !heartRate.isEmpty {
            SectionCard("Heart rate", subtitle: night.lowestHeartRate.map { "Lowest \(Int($0.rounded())) bpm" }, symbol: "heart.fill", tint: Theme.readiness) {
                Chart(heartRate.points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("bpm", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.readiness)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 140)
            }
        }
        if let hrv = night.hrv, !hrv.isEmpty {
            SectionCard("Heart rate variability", subtitle: night.averageHRV.map { "Average \(Int($0.rounded())) ms" }, symbol: "waveform.path.ecg", tint: Theme.sleep) {
                Chart(hrv.points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("ms", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.sleep.opacity(0.25))
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("ms", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.sleep)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 140)
            }
        }
    }

    private var recentNightsCard: some View {
        SectionCard("Last 14 nights", subtitle: "Hours asleep", symbol: "chart.bar.fill", tint: Theme.sleep) {
            Chart(model.trend(.sleepDuration, days: 14)) { entry in
                BarMark(
                    x: .value("Day", entry.day.startOfDay(), unit: .day),
                    y: .value("Hours", entry.value)
                )
                .foregroundStyle(Theme.sleep)
                .cornerRadius(4)
            }
            .chartYAxisLabel("h")
            .frame(height: 150)
        }
    }

    private func share(_ part: TimeInterval, of whole: TimeInterval) -> String? {
        guard whole > 0 else { return nil }
        return "\(Int((part / whole * 100).rounded()))%"
    }
}
