// Desktop / Notification Center widget. Renders the latest snapshot the app
// wrote to the App Group container — no credentials, no networking in here.
import WidgetKit
import SwiftUI
import AppIntents

// Per-widget lane choice ("Edit Widget"). nil / Automatic follows the app's
// pinned lane, else worst-first — so untouched widgets behave as before.
struct LaneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Usage Lane"
    static let defaultQuery = LaneQuery()
    let id: String    // "svc.label", same key as HistorySnapshot.pinned
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct LaneQuery: EntityQuery {
    private func all() -> [LaneEntity] {
        guard let snap = Snapshot.readShared() else { return [] }
        return snap.lanes.flatMap { svc, lanes in
            lanes.keys.map { LaneEntity(id: "\(svc).\($0)", name: "\(svc.capitalized) · \($0)") }
        }.sorted { $0.name < $1.name }
    }
    func entities(for identifiers: [String]) async throws -> [LaneEntity] {
        // A vanished lane keeps its id as the display name instead of erroring.
        identifiers.map { id in all().first { $0.id == id } ?? LaneEntity(id: id, name: id) }
    }
    func suggestedEntities() async throws -> [LaneEntity] { all() }
}

struct SelectLaneIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select lane"
    static let description = IntentDescription(
        "Which usage lane this widget shows. Automatic follows the app's pinned lane, else worst-first.")
    @Parameter(title: "Lane") var lane: LaneEntity?
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let snap: HistorySnapshot?
    var laneID: String? = nil
}

struct UsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snap: nil)
    }

    func snapshot(for configuration: SelectLaneIntent, in context: Context) async -> UsageEntry {
        UsageEntry(date: .now, snap: Snapshot.readShared(), laneID: configuration.lane?.id)
    }

    func timeline(for configuration: SelectLaneIntent, in context: Context) async -> Timeline<UsageEntry> {
        // The app pushes reloadAllTimelines after each poll; this .after is
        // just a fallback so countdown/pace stays roughly current if it quits.
        let entry = UsageEntry(date: .now, snap: Snapshot.readShared(), laneID: configuration.lane?.id)
        return Timeline(entries: [entry], policy: .after(.now + 15 * 60))
    }
}

private struct LaneItem: Identifiable {
    let svc: String, label: String, limit: Limit
    let pace: Pace, elapsed: Double
    let caption: String  // "CLAUDE", or "CLAUDE · STALE 3H · AUTH" when its fetch is failing
    var id: String { "\(svc).\(label)" }
}

// A provider counts as stale after two missed polls; its lanes then carry the
// age (and last error category) so the reader knows which numbers to distrust.
private let staleAfter: Double = 45 * 60

private func ageText(_ s: Double) -> String {
    if s >= 48 * 3600 { return "\(Int((s / 86400).rounded()))d" }
    if s >= 3600 { return "\(Int((s / 3600).rounded()))h" }
    return "\(Int((s / 60).rounded()))m"
}

private extension Pace {
    var color: Color {
        switch self {
        case .under: Color(red: 0.19, green: 0.72, blue: 0.35)
        case .on: Color(red: 1.0, green: 0.62, blue: 0.04)
        case .over: Color(red: 1.0, green: 0.28, blue: 0.24)
        }
    }
    var text: String { self == .on ? "ON PACE" : rawValue.uppercased() }
}

private func laneItems(_ snap: HistorySnapshot, now: Double, pin: String? = nil) -> [LaneItem] {
    var out: [LaneItem] = []
    for (svc, lanes) in snap.lanes {
        var caption = svc.uppercased()
        if let fetched = snap.fetchedAt[svc], now - fetched > staleAfter {
            caption += " · STALE \(ageText(now - fetched))"
            if let cat = snap.errors[svc] { caption += " · \(cat.uppercased())" }
        }
        for (label, limit) in lanes {
            let elapsed = limit.elapsedPct(now: now)
            out.append(LaneItem(svc: svc, label: label, limit: limit,
                                pace: paceBadge(usagePct: limit.pct, elapsed: elapsed),
                                elapsed: elapsed, caption: caption))
        }
    }
    out.sort {
        $0.pace.rank != $1.pace.rank ? $0.pace.rank < $1.pace.rank
            : $0.limit.pct > $1.limit.pct
    }
    // Pinned lane first; a vanished pin degrades to worst-first naturally.
    if let pin, let idx = out.firstIndex(where: { $0.id == pin }), idx > 0 {
        out.insert(out.remove(at: idx), at: 0)
    }
    return out
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        if let snap = entry.snap, !snap.lanes.isEmpty {
            // This widget's own lane choice wins; Automatic (nil) falls back to
            // the app-wide pin, so unedited widgets behave exactly as before.
            let items = laneItems(snap, now: entry.date.timeIntervalSince1970,
                                  pin: entry.laneID ?? snap.pinned)
            switch family {
            case .systemSmall: small(items, snap: snap)
            case .systemLarge: rows(items, limit: 8, snap: snap)
            default: rows(items, limit: 4, snap: snap)
            }
        } else {
            VStack(spacing: 4) {
                Text("No data yet").font(.caption)
                Text("Open UsageBar").font(.caption2).foregroundStyle(.secondary)
                if let snap = entry.snap { errorLine(snap) }  // failing before ever succeeding
            }
        }
    }

    // Always-visible failure summary, ungated by staleAfter and immune to lane
    // truncation: a provider that is erroring — or has never succeeded and so
    // has no lanes at all — must still be named plainly (PRODUCT: honest under
    // failure). staleAfter only delays the per-lane STALE <age> caption.
    @ViewBuilder private func errorLine(_ snap: HistorySnapshot) -> some View {
        if let text = errorSummary(snap.errors) {
            Text(text)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Pace.over.color)
                // A four-provider summary outmeasures a small widget's width
                // even at minimum scale; wrap there instead of losing names.
                .minimumScaleFactor(0.6)
                .lineLimit(family == .systemSmall ? 2 : 1)
        }
    }

    private func small(_ items: [LaneItem], snap: HistorySnapshot) -> some View {
        // The pinned lane (per-widget or app-wide) was already moved to the
        // front by body; a vanished pin degrades to worst-first naturally.
        let worst = items[0]
        return VStack(alignment: .leading, spacing: 2) {
            Text(worst.caption)
                .font(.system(size: 9, design: .monospaced)).kerning(0.8)
                .minimumScaleFactor(0.7).lineLimit(1)
                .foregroundStyle(.secondary)
            Text(laneDisplay(worst.label, worst.limit))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
            Spacer()
            Text("\(Int(worst.limit.pct.rounded()))%")
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundStyle(worst.pace.color)
            bar(worst).frame(height: 6)
            Text(worst.limit.blocked ? "LIMIT REACHED" : worst.pace.text)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(worst.limit.blocked ? Pace.over.color : worst.pace.color)
            footer(snap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rows(_ items: [LaneItem], limit: Int, snap: HistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.prefix(limit)) { it in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(it.caption)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .minimumScaleFactor(0.7).lineLimit(1)
                        Text(laneDisplay(it.label, it.limit))
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(width: 110, alignment: .leading)
                    bar(it).frame(height: 7)
                    Text("\(Int(it.limit.pct.rounded()))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(it.pace.color)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
            footer(snap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(_ it: LaneItem) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(it.pace.color)
                    .frame(width: geo.size.width * min(100, max(0, it.limit.pct)) / 100)
                Rectangle().fill(.primary)  // elapsed-time tick
                    .frame(width: 1.5)
                    .offset(x: geo.size.width * it.elapsed / 100 - 0.75)
            }
        }
    }

    private func footer(_ snap: HistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            errorLine(snap)
            // Relative, not clock time: "2:15 PM" from yesterday (or a 60-day-old
            // history seed) reads as current; "23 hours ago" cannot.
            Text("as of \(Date(timeIntervalSince1970: snap.tsEpoch).formatted(.relative(presentation: .named)))")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}

@main
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "UsageBoard", intent: SelectLaneIntent.self,
                               provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("AI usage")
        .description("Subscription usage vs. time. Edit the widget to pin a lane.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
