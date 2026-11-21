import SwiftUI
import TokenCore

// Menu sections. Each is one custom-view menu item laid straight onto the system menu material,
// inset to line up with the menu's own item text. Every section keeps one fixed view tree:
// a refresh only changes values inside it (digits roll), nothing is swapped, so nothing flashes.

private extension ProviderModel {
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

// MARK: - Provider switcher

/// Tabs for the enabled providers. The selected one sits on a soft fill, never the blue highlight.
struct SwitcherSection: View {
    @Environment(UsageStore.self) private var store
    @Namespace private var selection
    @State private var hovered: ProviderID?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(self.store.enabled) { id in
                let isSelected = id == self.store.selected
                Button {
                    guard !isSelected else { return }
                    withAnimation(.smooth(duration: 0.3)) { self.store.selected = id }
                    self.store.current.refreshLimits(minimumAge: 60)
                } label: {
                    HStack(spacing: 4) {
                        ProviderLogo(id: id, size: 15)
                            .foregroundStyle(isSelected ? AnyShapeStyle(id.markColor ?? .primary) : AnyShapeStyle(.secondary))
                        // Go and Zen share OpenCode's mark: a word tells them apart when both are here.
                        if id.sharesMark, self.store.enabled.contains(where: { $0 != id && $0.sharesMark }) {
                            Text(id.shortName)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.1))
                                .matchedGeometryEffect(id: "tab", in: self.selection)
                        } else if self.hovered == id {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in self.hovered = inside ? id : (self.hovered == id ? nil : self.hovered) }
                .help(id.displayName)
            }
        }
        .padding(.horizontal, Theme.inset - 6)
        .padding(.vertical, 2)
        .animation(.easeOut(duration: 0.12), value: self.hovered)
    }
}

// MARK: - Header

struct HeaderSection: View {
    @Environment(UsageStore.self) private var store
    private var model: ProviderModel { self.store.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    ProviderLogo(id: self.model.id, size: 13)
                        .foregroundStyle(self.model.id.markColor ?? .primary)
                    Text(self.model.id.displayName)
                        .font(.system(size: 13, weight: .bold))
                }
                .contentTransition(.opacity)
                Spacer(minLength: 8)
                if let plan = self.model.plan {
                    Text(plan)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(self.model.subtitle(hidingEmail: self.store.prefs.hidesEmail))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .modifier(SectionInsets(top: 3, bottom: 4))
    }
}

// MARK: - Plan limits

struct LimitsSection: View {
    @Environment(UsageStore.self) private var store
    private var model: ProviderModel { self.store.current }

    var body: some View {
        let limits = self.model.limits
        let prefs = self.store.prefs
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Limits")
                Spacer()
                if limits != nil || self.model.limitsIssue == nil {
                    Text(prefs.limitFigure == .left ? "left" : "used")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            if limits == nil, let issue = self.model.limitsIssue {
                Text(self.model.message(for: issue))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // One clock for every row, so countdowns tick together and a passed reset shows full.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 11) {
                        ForEach((limits ?? .placeholder()).items) { limit in
                            LimitRow(limit: limit, now: context.date, figure: prefs.limitFigure,
                                     resetStyle: prefs.resetStyle, showsPace: prefs.showsPace)
                        }
                    }
                }
                .redacted(reason: limits == nil ? .placeholder : [])
                if limits != nil, let issue = self.model.limitsIssue {
                    Text(self.model.message(for: issue))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
        }
        .modifier(SectionInsets(top: 6, bottom: 7))
    }

}

private struct LimitRow: View {
    let limit: PlanLimits.Limit
    let now: Date
    let figure: LimitFigure
    let resetStyle: ResetStyle
    let showsPace: Bool

    /// Once the reset passes, the stored figure is stale and the limit is full again.
    private var hasReset: Bool { self.limit.resetsAt.map { $0 <= self.now } ?? false }
    private var left: Double { self.hasReset ? 100 : self.limit.leftPercent }
    /// What the row shows and the bar fills to: percent left, or percent used.
    private var shown: Double { self.figure == .left ? self.left : 100 - self.left }

    var body: some View {
        let pace = self.hasReset || !self.showsPace ? nil : self.limit.pace(now: self.now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.limit.title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 8)
                Text(self.resetText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                    .help(self.limit.resetsAt.map { "Resets \($0.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))" } ?? "")
                Text("\(Int(self.shown.rounded()))%")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(self.isLow ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText(value: self.shown))
                    .frame(width: 40, alignment: .trailing)
            }
            .monospacedDigit()
            Meter(fraction: self.shown / 100, height: Meter.limitHeight,
                  fill: self.isLow ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accent),
                  mark: pace.map { self.paceMark($0) / 100 })
                .padding(.top, 1)
                .help(pace.map { "Even pace would leave \(Int((100 - $0.expectedUsedPercent).rounded()))% by now" } ?? "")
            if let pace {
                PaceLine(pace: pace, now: self.now)
                    .padding(.top, 1)
                    .transition(.opacity)
            }
        }
    }

    private var isLow: Bool { self.left < 10 }

    private func paceMark(_ pace: PlanLimits.Pace) -> Double {
        self.figure == .left ? 100 - pace.expectedUsedPercent : pace.expectedUsedPercent
    }

    private var resetText: String {
        guard let reset = self.limit.resetsAt else { return "" }
        if self.hasReset { return "reset" }
        return Format.reset(reset, now: self.now, style: self.resetStyle)
    }
}

/// `12% in reserve · Lasts until reset`, `8% in deficit · Runs out in 1d 3h`.
private struct PaceLine: View {
    let pace: PlanLimits.Pace
    let now: Date

    var body: some View {
        let delta = Int(abs(self.pace.deltaPercent).rounded())
        HStack(spacing: 0) {
            if self.pace.isOnPace {
                Text("On pace")
            } else {
                Text("\(delta)% in \(self.pace.deltaPercent < 0 ? "reserve" : "deficit")")
                    .foregroundStyle(self.pace.deltaPercent < 0 ? Theme.reserve : Theme.deficit)
                    .contentTransition(.numericText(value: Double(delta)))
            }
            Text(" · " + self.outlook)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var outlook: String {
        guard let seconds = self.pace.runsOutIn else { return "Lasts until reset" }
        if seconds < 60 { return "Runs out now" }
        return "Runs out in \(Format.countdown(to: self.now.addingTimeInterval(seconds), from: self.now))"
    }
}

/// A capsule bar on a faint track. Every bar in the menu is one of these, so they all share one
/// shape; the optional mark (the pace) stands a little proud of the bar without changing its size.
struct Meter: View {
    static let limitHeight: CGFloat = 6
    static let windowHeight: CGFloat = 4

    let fraction: Double
    let height: CGFloat
    let fill: AnyShapeStyle
    var mark: Double?

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .frame(height: self.height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let clamped = min(1, max(0, self.fraction))
                    // Never narrower than it is tall, so a sliver still reads as a rounded bar.
                    Capsule()
                        .fill(self.fill)
                        .frame(width: clamped > 0 ? max(self.height, width * clamped) : 0, height: self.height)
                    if let mark = self.mark {
                        Capsule()
                            .fill(Color.primary.opacity(0.6))
                            .frame(width: 2, height: self.height + 5)
                            .position(x: min(width - 1, max(1, width * min(1, max(0, mark)))), y: self.height / 2)
                    }
                }
            }
    }
}

// MARK: - Today and this window

struct HeroSection: View {
    @Environment(UsageStore.self) private var store
    private var model: ProviderModel { self.store.current }

    var body: some View {
        let snapshot = self.model.shown
        HStack(alignment: .top, spacing: 12) {
            Metric(title: "Today", value: snapshot.today?.cost ?? 0, tokens: snapshot.today?.tokens ?? 0,
                   tokensOnly: snapshot.measuresTokens)
            Metric(
                title: "This window",
                value: snapshot.currentWindow?.cost ?? 0,
                tokens: snapshot.currentWindow?.tokens ?? 0,
                tokensOnly: snapshot.measuresTokens)
        }
        .modifier(SectionInsets(top: 5, bottom: 6))
        .redacted(reason: self.model.snapshot == nil ? .placeholder : [])
    }
}

private struct Metric: View {
    let title: String
    let value: Double
    let tokens: Int
    var tokensOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionTitle(text: self.title)
            Text(self.tokensOnly ? Format.tokens(self.tokens) : Format.money(self.value))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .tracking(-0.2)
                .contentTransition(.numericText(value: self.tokensOnly ? Double(self.tokens) : self.value))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(self.tokensOnly ? "tokens" : "\(Format.tokens(self.tokens)) tokens")
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
    private var model: ProviderModel { self.store.current }
    @State private var hoveredDay: Date?

    var body: some View {
        let snapshot = self.model.shown
        let day = self.hoveredDay.flatMap { id in snapshot.days.first { $0.id == id } }
        let tokensOnly = snapshot.measuresTokens
        let tokens = day?.tokens ?? snapshot.historyTokens
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SectionTitle(text: day.map { Format.day($0.start) } ?? "Last 30 days")
                Spacer(minLength: 8)
                if !tokensOnly {
                    Text(day.map { Format.money($0.cost) } ?? Format.wholeMoney(snapshot.historyCost))
                        .font(.system(size: 12, weight: .semibold))
                        .contentTransition(.numericText(value: day?.cost ?? snapshot.historyCost))
                }
                Text(tokensOnly ? "\(Format.tokens(tokens)) tokens" : Format.tokens(tokens))
                    .font(.system(size: 12, weight: tokensOnly ? .semibold : .regular))
                    .foregroundStyle(tokensOnly ? .primary : .secondary)
                    .contentTransition(.numericText(value: Double(tokens)))
            }
            .monospacedDigit()
            DailyBars(days: snapshot.days, hovered: self.$hoveredDay, measure: tokensOnly ? { Double($0.tokens) } : { $0.cost })
                .frame(height: 50)
            HStack {
                Text(snapshot.days.first.map { $0.start.formatted(.dateTime.day().month(.abbreviated)) } ?? "")
                Spacer()
                Text(tokensOnly
                    ? "avg \(Format.tokens(snapshot.historyTokens / max(1, snapshot.days.count))) a day"
                    : "avg \(Format.wholeMoney(snapshot.historyCost / Double(max(1, snapshot.days.count)))) a day")
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
        .redacted(reason: self.model.snapshot == nil ? .placeholder : [])
    }
}

// MARK: - Weekly windows

struct WindowsSection: View {
    @Environment(UsageStore.self) private var store
    private var model: ProviderModel { self.store.current }

    var body: some View {
        let snapshot = self.model.shown
        let tokensOnly = snapshot.measuresTokens
        let peak = max(snapshot.windows.map { tokensOnly ? Double($0.tokens) : $0.cost }.max() ?? 0, 0.01)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Weekly windows")
                Spacer()
                if let end = snapshot.currentWindow?.end {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Format.reset(end, now: context.date, style: self.store.prefs.resetStyle,
                                          verb: self.model.id.hasLimits ? "resets" : "ends"))
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
                    WindowRow(window: window, peak: peak, tokensOnly: tokensOnly)
                }
            }
        }
        .modifier(SectionInsets(top: 6, bottom: 7))
        .redacted(reason: self.model.snapshot == nil ? .placeholder : [])
    }
}

private struct WindowRow: View {
    let window: UsageSnapshot.Window
    let peak: Double
    let tokensOnly: Bool

    private var amount: Double { self.tokensOnly ? Double(self.window.tokens) : self.window.cost }

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
                if !self.tokensOnly {
                    Text(Format.tokens(self.window.tokens))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(self.window.tokens)))
                        .frame(width: 46, alignment: .trailing)
                }
                Text(self.tokensOnly ? Format.tokens(self.window.tokens) : Format.wholeMoney(self.window.cost))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(self.window.isCurrent ? .primary : .secondary)
                    .contentTransition(.numericText(value: self.amount))
                    .frame(width: 56, alignment: .trailing)
            }
            .monospacedDigit()
            Meter(fraction: self.amount / self.peak, height: Meter.windowHeight,
                  fill: self.window.isCurrent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.28)))
        }
    }
}

// MARK: - Footer

struct FooterSection: View {
    @Environment(UsageStore.self) private var store
    private var model: ProviderModel { self.store.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if self.model.id.hasSpend, self.store.prefs.showsTopModel {
                TopModelLine(top: self.model.snapshot?.topModel)
            }
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
        let updated = self.model.id.hasSpend ? self.model.updatedAt : self.model.limits?.fetchedAt
        let freshness = self.model.isVisiblyRefreshing ? "Updating…"
            : updated == nil && !self.model.id.hasSpend ? "Not updated yet" : Format.updated(updated, now: now)
        return "\(self.model.id.hasSpend ? self.model.id.spendNote : "Limits from \(self.model.id.displayName)") · \(freshness)"
    }
}

/// `Top model  Opus 5.5 · 76% of spend` on one line; when a long model name won't fit, the name
/// moves to a line of its own rather than being cut off.
private struct TopModelLine: View {
    let top: UsageSnapshot.ModelShare?

    var body: some View {
        Group {
            if let top = self.top {
                let name = Text(Format.model(top.model)).fontWeight(.medium)
                let share = Text("\(Int((top.share * 100).rounded()))% of \(top.byTokens == true ? "tokens" : "spend")")
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        Text("Top model").foregroundStyle(.secondary)
                        name
                        Text("·").foregroundStyle(.secondary)
                        share
                    }
                    .lineLimit(1)
                    .fixedSize()
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text("Top model").foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            share
                        }
                        name
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Text("Top model").foregroundStyle(.secondary)
                    Text("—").foregroundStyle(.tertiary)
                }
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }
}
