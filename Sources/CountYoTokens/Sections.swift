import SwiftUI
import TokenCore

// Menu sections. Each is one custom-view menu item laid straight onto the system menu material,
// inset to line up with the menu's own item text. Every section keeps one fixed view tree:
// a refresh only changes values inside it (digits roll), nothing is swapped, so nothing flashes.

private extension UsageStore {
    /// Before the first-ever scan, all zeros in the real layout (shown redacted).
    var shown: UsageSnapshot { self.snapshot ?? .placeholder(settings: self.windowSettings) }
}

private struct SectionInsets: ViewModifier {
    var top: CGFloat = 6
    var bottom: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.inset)
            .padding(.top, self.top)
            .padding(.bottom, self.bottom)
    }
}

/// Bold-ish grey title, the way Apple labels groups in its menus.
private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Header

struct HeaderSection: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude")
                    .font(.system(size: 13, weight: .bold))
                Spacer(minLength: 8)
                if let plan = self.store.account?.plan {
                    Text(plan)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(self.store.account?.email ?? "Local usage")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .modifier(SectionInsets(top: 3, bottom: 4))
    }
}

// MARK: - Today and this window

struct HeroSection: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let snapshot = self.store.shown
        HStack(alignment: .top, spacing: 12) {
            Metric(title: "Today", value: snapshot.today?.cost ?? 0, tokens: snapshot.today?.tokens ?? 0)
            Metric(
                title: "This window",
                value: snapshot.currentWindow?.cost ?? 0,
                tokens: snapshot.currentWindow?.tokens ?? 0)
        }
        .modifier(SectionInsets(top: 5, bottom: 6))
        .redacted(reason: self.store.snapshot == nil ? .placeholder : [])
    }
}

private struct Metric: View {
    let title: String
    let value: Double
    let tokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionTitle(text: self.title)
            Text(Format.money(self.value))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .tracking(-0.2)
                .contentTransition(.numericText(value: self.value))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(Format.tokens(self.tokens)) tokens")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(self.tokens)))
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Last 30 days

struct HistorySection: View {
    @Environment(UsageStore.self) private var store
    @State private var hoveredDay: Date?

    var body: some View {
        let snapshot = self.store.shown
        let day = self.hoveredDay.flatMap { id in snapshot.days.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SectionTitle(text: day.map { Format.day($0.start) } ?? "Last 30 days")
                Spacer(minLength: 8)
                Text(day.map { Format.money($0.cost) } ?? Format.wholeMoney(snapshot.historyCost))
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.numericText(value: day?.cost ?? snapshot.historyCost))
                Text(Format.tokens(day?.tokens ?? snapshot.historyTokens))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(day?.tokens ?? snapshot.historyTokens)))
            }
            .monospacedDigit()
            DailyBars(days: snapshot.days, hovered: self.$hoveredDay)
                .frame(height: 50)
            HStack {
                Text(snapshot.days.first.map { $0.start.formatted(.dateTime.day().month(.abbreviated)) } ?? "")
                Spacer()
                Text("avg \(Format.wholeMoney(snapshot.historyCost / Double(max(1, snapshot.days.count)))) a day")
                    .contentTransition(.numericText())
                Spacer()
                Text("Today")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .modifier(SectionInsets(top: 6, bottom: 7))
        .animation(.easeOut(duration: 0.12), value: self.hoveredDay)
        .redacted(reason: self.store.snapshot == nil ? .placeholder : [])
    }
}

// MARK: - Weekly windows

struct WindowsSection: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let snapshot = self.store.shown
        let peak = max(snapshot.windows.map(\.cost).max() ?? 0, 0.01)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Weekly windows")
                Spacer()
                if let end = snapshot.currentWindow?.end {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("resets in \(Format.countdown(to: end, from: context.date))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .help("Resets \(end.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))")
                }
            }
            VStack(spacing: 8) {
                ForEach(snapshot.windows) { window in
                    WindowRow(window: window, peak: peak)
                }
            }
        }
        .modifier(SectionInsets(top: 6, bottom: 7))
        .redacted(reason: self.store.snapshot == nil ? .placeholder : [])
    }
}

private struct WindowRow: View {
    let window: UsageSnapshot.Window
    let peak: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.range(self.window.start, self.window.end))
                    .font(.system(size: 12.5, weight: self.window.isCurrent ? .semibold : .regular))
                    .foregroundStyle(self.window.isCurrent ? .primary : .secondary)
                if self.window.isCurrent {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        .help("Current window")
                }
                Spacer(minLength: 8)
                Text(Format.tokens(self.window.tokens))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(self.window.tokens)))
                    .frame(width: 46, alignment: .trailing)
                Text(Format.wholeMoney(self.window.cost))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(self.window.isCurrent ? .primary : .secondary)
                    .contentTransition(.numericText(value: self.window.cost))
                    .frame(width: 56, alignment: .trailing)
            }
            .monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(self.window.isCurrent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.28)))
                        .frame(width: max(3, proxy.size.width * min(1, self.window.cost / self.peak)))
                }
            }
            .frame(height: 3)
        }
    }
}

// MARK: - Footer

struct FooterSection: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Top model")
                    .foregroundStyle(.secondary)
                if let top = self.store.snapshot?.topModel {
                    Text(Format.model(top.model))
                        .fontWeight(.medium)
                    Text("· \(Int((top.share * 100).rounded()))% of spend")
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: top.share))
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(self.status(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
        }
        .modifier(SectionInsets(top: 4, bottom: 4))
    }

    private func status(now: Date) -> String {
        let freshness = self.store.isVisiblyRefreshing ? "Updating…" : Format.updated(self.store.updatedAt, now: now)
        return "Estimated at API prices · \(freshness)"
    }
}
