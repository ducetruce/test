import SwiftUI
import Charts

struct TrendsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var metric: TrendMetric = .readinessScore
    @State private var window = 30

    private let windows = [7, 30, 90, 180]

    private var points: [DayPoint] { model.trend(metric, days: window) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Range", selection: $window) {
                        ForEach(windows, id: \.self) { value in
                            Text("\(value)d").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)

                    chartCard
                    summaryCard
                    metricPicker
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Trends")
            .refreshable { await model.sync() }
        }
    }

    private var chartCard: some View {
        SectionCard(metric.title, subtitle: "Last \(window) days") {
            if points.isEmpty {
                EmptyStateView(
                    symbol: "chart.xyaxis.line",
                    title: "Nothing to plot yet",
                    message: "Sync more history from Settings to fill this out."
                )
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value(metric.title, point.value)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(metric.tint)

                        PointMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value(metric.title, point.value)
                        )
                        .symbolSize(window > 60 ? 0 : 18)
                        .foregroundStyle(metric.tint)
                    }

                    // Dashed baseline so a single day reads against the period average.
                    if let average {
                        RuleMark(y: .value("Average", average))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 220)
            }
        }
    }

    private var average: Double? { Stats.mean(points.map(\.value)) }

    @ViewBuilder
    private var summaryCard: some View {
        if !points.isEmpty {
            SectionCard("Summary") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatTile(label: "Average", value: value(average), caption: nil, tint: metric.tint)
                    StatTile(label: "Latest", value: value(points.last?.value), caption: points.last.map { Format.dayLabel($0.day) }, tint: metric.tint)
                    StatTile(label: "Best", value: value(points.map(\.value).max()), caption: nil, tint: metric.tint)
                    StatTile(label: "Lowest", value: value(points.map(\.value).min()), caption: nil, tint: metric.tint)
                }
            }
        }
    }

    private var metricPicker: some View {
        SectionCard("Metric") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(TrendMetric.allCases) { option in
                    Button {
                        withAnimation { metric = option }
                    } label: {
                        Text(option.title)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(option == metric ? option.tint.opacity(0.22) : Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func value(_ number: Double?) -> String {
        guard let number else { return "—" }
        switch metric {
        case .steps:
            return Format.integer(Int(number.rounded()))
        case .sleepDuration:
            return Format.number(number, decimals: 1) + " h"
        case .temperature:
            return String(format: "%+.2f", number)
        case .sleepScore, .readinessScore, .activityScore:
            return "\(Int(number.rounded()))"
        default:
            return "\(Int(number.rounded())) \(metric.unit)"
        }
    }
}
