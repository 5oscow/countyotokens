import SwiftUI
import TokenCore

/// Thirty days of spend. Today is the accent bar; a dashed line marks the daily average.
/// Bars keep their identity (keyed by day), so new values grow and shrink instead of redrawing.
struct DailyBars: View {
    let days: [UsageSnapshot.Day]
    @Binding var hovered: Date?
    /// Dollars normally; tokens for a provider that records no cost.
    var measure: (UsageSnapshot.Day) -> Double = { $0.cost }

    private let spacing: CGFloat = 2.5

    var body: some View {
        GeometryReader { proxy in
            let peak = max(self.days.map(self.measure).max() ?? 0, 0.01)
            let average = self.days.isEmpty ? 0 : self.days.reduce(0) { $0 + self.measure($1) } / Double(self.days.count)
            let height = proxy.size.height
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: self.spacing) {
                    ForEach(self.days) { day in
                        let isToday = day.id == self.days.last?.id
                        let isHovered = day.id == self.hovered
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(self.fill(isToday: isToday, isHovered: isHovered, isEmpty: self.measure(day) <= 0))
                            .frame(height: self.measure(day) > 0 ? max(3, height * self.measure(day) / peak) : 2)
                            .frame(maxWidth: .infinity)
                    }
                }
                if average > 0 {
                    Path { path in
                        let y = height - height * average / peak
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                    .stroke(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 0.75, dash: [2, 2.5]))
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    let slot = proxy.size.width / CGFloat(max(1, self.days.count))
                    let index = min(self.days.count - 1, max(0, Int(point.x / slot)))
                    if self.days.indices.contains(index), self.hovered != self.days[index].id {
                        self.hovered = self.days[index].id
                    }
                case .ended:
                    self.hovered = nil
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Daily spend, last 30 days")
    }

    private func fill(isToday: Bool, isHovered: Bool, isEmpty: Bool) -> Color {
        if isEmpty { return Color.primary.opacity(0.10) }
        if isHovered { return Theme.accent }
        if isToday { return Theme.accent.opacity(self.hovered == nil ? 1 : 0.55) }
        return Color.primary.opacity(self.hovered == nil ? 0.24 : 0.16)
    }
}
