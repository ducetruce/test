import SwiftUI

/// Sleep-stage graph for one night: one block per five minutes, drawn in four rows
/// (awake at the top, deep at the bottom) the way a hypnogram is conventionally read.
struct Hypnogram: View {
    var stages: [SleepStage]
    var start: Date
    var end: Date

    private static let rows: [SleepStage] = [.awake, .rem, .light, .deep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.rows, id: \.self) { stage in
                        Text(stage.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(height: 22, alignment: .center)
                    }
                }
                .frame(width: 42, alignment: .leading)

                Canvas { context, size in
                    guard !stages.isEmpty else { return }
                    let blockWidth = size.width / CGFloat(stages.count)
                    let rowHeight = size.height / CGFloat(Self.rows.count)
                    for (index, stage) in stages.enumerated() {
                        guard let row = Self.rows.firstIndex(of: stage) else { continue }
                        let rect = CGRect(
                            x: CGFloat(index) * blockWidth,
                            y: CGFloat(row) * rowHeight + 3,
                            width: max(blockWidth, 1),
                            height: max(rowHeight - 6, 2)
                        )
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(Theme.color(for: stage))
                        )
                    }
                }
                .frame(height: 88)
            }

            HStack {
                Text(Format.clockTime(start))
                Spacer()
                Text(Format.clockTime(end))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 50)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stages from \(Format.clockTime(start)) to \(Format.clockTime(end))")
    }
}
