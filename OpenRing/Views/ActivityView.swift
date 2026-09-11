import SwiftUI
import Charts

struct ActivityView: View {
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

                    if let activity = model.database.activityDay(day) {
                        if let score = model.dayScores(for: day).activity {
                            ScoreDetailCard(score: score)
                        }
                        summaryCard(activity)
                        intensityCard(activity)
                        workoutsCard
                        stepsTrendCard
                    } else {
                        EmptyStateView(
                            symbol: "figure.walk",
                            title: "No activity recorded",
                            message: "Nothing was recorded for \(Format.dayLabel(day))."
                        )
                        stepsTrendCard
                    }
                }
                .padding(16)
            }
            .background(Theme.canvas)
            .navigationTitle("Activity")
            .refreshable { await model.sync() }
        }
    }

    private func summaryCard(_ activity: ActivityDay) -> some View {
        SectionCard(Format.integer(activity.steps) + " steps", subtitle: "Today's movement", symbol: "figure.walk", tint: Theme.activity) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(label: "Active calories", value: "\(Int(activity.activeCalories.rounded()))", caption: "Target \(Int(activity.targetCalories.rounded()))", tint: Theme.activity)
                StatTile(label: "Total calories", value: "\(Int(activity.totalCalories.rounded()))", caption: nil, tint: Theme.activity)
                StatTile(label: "Walking equivalent", value: Format.number(activity.equivalentWalkingDistance / 1000, decimals: 1) + " km", caption: nil, tint: Theme.activity)
                StatTile(label: "Inactivity alerts", value: "\(activity.inactivityAlerts)", caption: String(format: "%.1f h sedentary", activity.sedentaryTime / 3600), tint: Theme.activity)
            }
        }
    }

    @ViewBuilder
    private func intensityCard(_ activity: ActivityDay) -> some View {
        SectionCard("Intensity", subtitle: "Minutes by level", symbol: "flame.fill", tint: Theme.activity) {
            VStack(alignment: .leading, spacing: 14) {
                Chart {
                    BarMark(x: .value("Minutes", activity.highActivityMinutes), y: .value("Level", "High"))
                        .foregroundStyle(Theme.activity)
                    BarMark(x: .value("Minutes", activity.mediumActivityMinutes), y: .value("Level", "Medium"))
                        .foregroundStyle(Theme.activity.opacity(0.7))
                    BarMark(x: .value("Minutes", activity.lowActivityMinutes), y: .value("Level", "Low"))
                        .foregroundStyle(Theme.activity.opacity(0.45))
                }
                .frame(height: 120)

                if let met = activity.met, !met.isEmpty {
                    Text("MET through the day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart(met.points) { point in
                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value("MET", point.value)
                        )
                        .foregroundStyle(Theme.activity.opacity(0.3))
                    }
                    .frame(height: 120)
                }
            }
        }
    }

    @ViewBuilder
    private var workoutsCard: some View {
        let workouts = model.database.workoutSessions(day)
        if !workouts.isEmpty {
            SectionCard("Workouts", symbol: "figure.run", tint: Theme.activity) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(workouts) { workout in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workout.label ?? workout.activity.capitalized)
                                .font(.subheadline.weight(.medium))
                            Text("\(Format.clockTime(workout.start)) · \(Format.duration(workout.duration))"
                                 + (workout.calories.map { " · \(Int($0.rounded())) kcal" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var stepsTrendCard: some View {
        SectionCard("Last 14 days", subtitle: "Steps", symbol: "chart.bar.fill", tint: Theme.activity) {
            Chart(model.trend(.steps, days: 14)) { entry in
                BarMark(
                    x: .value("Day", entry.day.startOfDay(), unit: .day),
                    y: .value("Steps", entry.value)
                )
                .foregroundStyle(Theme.activity)
                .cornerRadius(4)
            }
            .frame(height: 150)
        }
    }
}
