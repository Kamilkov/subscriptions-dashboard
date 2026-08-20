// The board, a 1:1 port of the web dashboard's layout (dashboard.py is the
// source of truth): each group lays its lanes on a SHARED time axis — a lane's
// bar is positioned/sized by its window's place in the group's overall span —
// with an axis row (edge labels + now/today marker) above the lanes.
import SwiftUI

private struct LaneItem: Identifiable {
    let svc: String, label: String, limit: Limit
    let pace: Pace, elapsed: Double, stale: Bool, age: String
    let verdict: String?
    // Group-axis layout, all as 0…1 fractions of the lane area (set by layout()).
    var left: Double = 0, width: Double = 1, nowFrac: Double = 0
    var barTicks: [Double] = []   // window/7 gridlines, fractions of the bar
    var areaTicks: [Double] = []  // midnight gridlines, fractions of the area
    var id: String { "\(svc).\(label)" }
}

private func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }

// Hex "RRGGBB" <-> Color, for the user board-background setting (stored as
// hex to stay parity-comparable with the web board's localStorage values).
func colorFromHex(_ hex: String) -> Color? {
    var v: UInt64 = 0
    guard hex.count == 6, Scanner(string: hex).scanHexInt64(&v) else { return nil }
    return Color(red: Double((v >> 16) & 0xFF) / 255,
                 green: Double((v >> 8) & 0xFF) / 255,
                 blue: Double(v & 0xFF) / 255)
}

func hexFromColor(_ c: Color) -> String {
    let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
    return String(format: "%02X%02X%02X", Int(round(n.redComponent * 255)),
                  Int(round(n.greenComponent * 255)), Int(round(n.blueComponent * 255)))
}

// Local midnights in (start, end) — Calendar day-walk stays DST-safe.
private func midnights(start: Double, end: Double) -> [Double] {
    let cal = Calendar.current
    var d = cal.startOfDay(for: Date(timeIntervalSince1970: start))
    var out: [Double] = []
    while d.timeIntervalSince1970 <= start { d = cal.date(byAdding: .day, value: 1, to: d)! }
    while d.timeIntervalSince1970 < end {
        out.append(d.timeIntervalSince1970)
        d = cal.date(byAdding: .day, value: 1, to: d)!
    }
    return out
}

private extension Pace {
    var color: Color {
        switch self {
        case .under: Color(red: 0.19, green: 0.62, blue: 0.30)
        case .on: Color(red: 0.75, green: 0.42, blue: 0.0)
        case .over: Color(red: 0.84, green: 0.0, blue: 0.08)
        }
    }
    var text: String { self == .on ? "ON PACE" : rawValue.uppercased() }
}

// Full-window variant: same board at normal type size; the bars absorb the
// extra width. `scale` stays available for an explicit display/kiosk mode.
struct BoardWindow: View {
    let store: Store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            BoardView(store: store, isWindow: true)
                .frame(maxWidth: .infinity)
        }
        // User background tint sits OVER the material (first .background is
        // nearest the content), so the frosted-glass look survives underneath.
        .background {
            if let hex = scheme == .dark ? store.boardBgDark : store.boardBgLight,
               let tint = colorFromHex(hex) {
                tint.opacity(0.55).ignoresSafeArea()
            }
        }
        // Same translucent material the MenuBarExtra dropdown gets for free —
        // adapts to wallpaper/appearance and honors "Reduce transparency".
        .background(.ultraThinMaterial)
        .containerBackground(.ultraThinMaterial, for: .window)
        // Without this the title bar paints its own opaque background over
        // the window material and reads as a black strip.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Regular-app mode (Dock, Cmd-Tab, window chrome) while the board is
        // open; pure menu-bar accessory again on close. NOTE: the green button
        // deliberately zooms instead of entering a fullscreen Space — forcing
        // .fullScreenPrimary onto a SwiftUI-scene window lets it ENTER
        // fullscreen but never exit (the scene never sanctioned it and cannot
        // restore); verified by AX-driven bisect 2026-08-17. Revisit only via
        // an AppKit-hosted NSWindow.
        .onAppear { store.enterRegular() }
        .onDisappear { store.leaveRegular() }
    }
}


struct BoardView: View {
    let store: Store
    var scale: CGFloat = 1
    var isWindow = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    // Wide enough for "Monthly - Cursor models" + UNDER tag on one line.
    private let labelWidth: CGFloat = 195
    // Wide enough for the longest one-liner: "runs out ~Wed 19 Aug, 14:22" @ 9pt mono.
    private let metaWidth: CGFloat = 160

    // All type and column sizes are design-pixel * scale * the user's A−/A+
    // multiplier, so everything (and the popover width) grows together.
    private var eff: CGFloat { scale * store.fontScale }
    private func s(_ x: CGFloat) -> CGFloat { x * eff }

    var body: some View {
        let now = Date().timeIntervalSince1970
        VStack(alignment: .leading, spacing: s(10)) {
            header
            ForEach(errorLines(), id: \.self) { msg in
                HStack(spacing: s(8)) {
                    Label(msg, systemImage: "exclamationmark.circle")
                        .font(.system(size: s(11))).foregroundStyle(.orange)
                    if msg.hasPrefix("Antigravity not running") { openAntigravityButton }
                }
            }
            ForEach(Bucket.allCases, id: \.self) { bucket in
                if store.enabledBuckets.contains(bucket.rawValue) {
                    groupView(bucket, now: now)
                }
            }
            ForEach(unavailableLines(), id: \.self) { msg in
                HStack(spacing: s(8)) {
                    Text(msg).font(.system(size: s(11))).foregroundStyle(.secondary)
                    if msg.hasPrefix("Antigravity not running") { openAntigravityButton }
                }
            }
            footer
        }
        .padding(s(14))
        .frame(width: isWindow ? nil : 630 * eff)
    }

    private var header: some View {
        HStack {
            Text("AI subscriptions").font(.system(size: s(13), weight: .semibold))
            Text("· usage vs. time").font(.system(size: s(13))).foregroundStyle(.secondary)
            Spacer()
            Button("A−") { store.adjustFontScale(-0.1) }
                .controlSize(.small)
            Button("A+") { store.adjustFontScale(+0.1) }
                .controlSize(.small)
            if isWindow {
                // The window has no ⋯ menu, so the grid toggle stays in its header.
                Button(store.gridMode == "midnight" ? "grid: midnights" : "grid: window /7") {
                    store.toggleGridMode()
                }
                .controlSize(.small)
            }
            Button("Refresh") { Task { await store.refresh(force: true) } }
                .controlSize(.small)
            if !isWindow {
                Button("Open Window") {
                    // Policy BEFORE openWindow — a window created under
                    // accessory policy is stamped without minimize/zoom.
                    // The policy change needs a runloop turn to settle,
                    // hence the async hop before creating the window.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async { openWindow(id: "board") }
                }
                .controlSize(.small)
                Menu {
                    Button(store.gridMode == "midnight" ? "grid: midnights" : "grid: window /7") {
                        store.toggleGridMode()
                    }
                    Button("Options…") {
                        // SettingsLink goes dead after the window closes once;
                        // the openSettings action + activate reliably reopens it.
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    Button("How numbers work…") {
                        // Same Options window — the explainer is its Numbers tab.
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    Button("Weekly utilization…") {
                        // Policy-first (see Open Window), then the history window.
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        DispatchQueue.main.async { openWindow(id: "utilization") }
                    }
                    Button("Check for Updates…") { Updater.controller.checkForUpdates(nil) }
                    Divider()
                    Button("Quit UsageBar") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private var footer: some View {
        let last = store.lastPoll
        return Text(last > 0
                    ? "last poll \(Date(timeIntervalSince1970: last).formatted(date: .omitted, time: .shortened)) · auto every 20 min"
                    : "polling…")
            .font(.system(size: s(10), design: .monospaced)).foregroundStyle(.tertiary)
    }

    // MARK: - group

    @ViewBuilder
    private func groupView(_ bucket: Bucket, now: Double) -> some View {
        var items = laneItems(bucket: bucket, now: now)
        // Claude reports no session limit between sessions; keep the rolling
        // group visible with an idle placeholder instead of vanishing (web parity).
        let claudeLanes = store.enabled.contains("claude") ? store.states["claude"]!.lanes : [:]
        let sessionIdle = bucket == .rolling && !claudeLanes.isEmpty && claudeLanes["session"] == nil
        let axis: (start: Double, end: Double, nowFrac: Double)? =
            items.isEmpty ? nil : layout(&items, bucket: bucket, now: now)
        if !items.isEmpty || sessionIdle {
            VStack(alignment: .leading, spacing: s(8)) {
                HStack {
                    Text(bucket.title.uppercased())
                        .font(.system(size: s(10), weight: .semibold, design: .monospaced)).kerning(1.2)
                    Spacer()
                    Text(bucket.hint).font(.system(size: s(10))).foregroundStyle(.secondary)
                }
                if let axis {
                    axisRow(bucket, axis: axis, now: now)
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                        LaneRow(item: it, scale: eff,
                                cont: i > 0 && items[i - 1].svc == it.svc)
                    }
                }
                if sessionIdle { IdleLaneRow(scale: eff) }
            }
            .padding(s(10))
            .background(RoundedRectangle(cornerRadius: s(9)).fill(.quaternary.opacity(0.4)))
        }
    }

    // Shared date axis: edge labels (dropped when the now-marker would collide,
    // same 16%/84% thresholds as the web board) and the now/today marker.
    private func axisRow(_ bucket: Bucket, axis: (start: Double, end: Double, nowFrac: Double),
                         now: Double) -> some View {
        HStack(alignment: .center, spacing: s(12)) {
            Color.clear.frame(width: s(labelWidth), height: 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    if bucket == .weekly {
                        // A name over each calendar day instead of edge labels.
                        ForEach(dayLabels(start: axis.start, end: axis.end,
                                          nowFrac: axis.nowFrac), id: \.frac) { d in
                            Text(d.name)
                                .font(.system(size: s(8), design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .position(x: geo.size.width * d.frac, y: geo.size.height / 2)
                        }
                    } else {
                        if axis.nowFrac > 0.16 {
                            Text(edgeLabel(bucket, axis.start, now: now))
                                .font(.system(size: s(9), design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if axis.nowFrac < 0.84 {
                            Text(edgeLabel(bucket, axis.end, now: now))
                                .font(.system(size: s(9), design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    VStack(spacing: 1) {
                        // Rolling is hours-scale, so the marker carries the clock time.
                        Text(bucket == .monthly ? "today"
                             : bucket == .rolling
                             ? Date(timeIntervalSince1970: now).formatted(.dateTime.hour().minute())
                             : "now")
                            .font(.system(size: s(9), weight: .semibold, design: .monospaced))
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: s(5)))
                    }
                    .fixedSize()
                    .position(x: geo.size.width * axis.nowFrac, y: geo.size.height / 2)
                }
            }
            .frame(height: s(18))
            Color.clear.frame(width: s(metaWidth), height: 1)
        }
    }

    private struct DayLabel { let frac: Double, name: String }

    // One label per calendar day on the weekly axis, centered over the day's
    // segment. Skips slivers at the edges and anything under the now-marker.
    private func dayLabels(start: Double, end: Double, nowFrac: Double) -> [DayLabel] {
        let span = max(end - start, 1)
        let bounds = [start] + midnights(start: start, end: end) + [end]
        var out: [DayLabel] = []
        for i in 0..<(bounds.count - 1) {
            let a = bounds[i], b = bounds[i + 1]
            if (b - a) / span < 0.05 { continue }
            let frac = ((a + b) / 2 - start) / span
            if abs(frac - nowFrac) < 0.055 { continue }
            out.append(DayLabel(frac: frac,
                                name: Date(timeIntervalSince1970: (a + b) / 2)
                                    .formatted(.dateTime.weekday(.abbreviated))))
        }
        return out
    }

    private func edgeLabel(_ bucket: Bucket, _ epoch: Double, now: Double) -> String {
        let d = Date(timeIntervalSince1970: epoch)
        switch bucket {
        case .rolling:
            let sec = epoch - now
            let a = abs(sec)
            let v = a < 3600 ? "\(Int((a / 60).rounded()))m" : "\(Int((a / 3600).rounded()))h"
            return sec < 0 ? "\(v) ago" : "in \(v)"
        case .weekly:
            return d.formatted(.dateTime.weekday(.abbreviated))
        case .monthly:
            return d.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    // MARK: - lane building + web groupLayout math

    private func laneItems(bucket: Bucket, now: Double) -> [LaneItem] {
        var out: [LaneItem] = []
        for svc in store.enabledServices {
            let st = store.states[svc]!
            let stale = st.status != "fresh"
            let age = st.fetchedAt.map { ageText(now - $0) } ?? ""
            for (label, limit) in st.lanes where Bucket(windowSeconds: limit.windowSeconds) == bucket {
                let elapsed = limit.elapsedPct(now: now)
                let pts = store.windowPoints(service: svc, label: label, limit: limit,
                                             now: now, trailing: 86400)
                let exhaust = projectExhaustion(points: pts, limit: limit, now: now)
                out.append(LaneItem(
                    svc: svc, label: label, limit: limit,
                    pace: paceBadge(usagePct: limit.pct, elapsed: elapsed),
                    elapsed: elapsed, stale: stale, age: age,
                    verdict: exhaust.map { "runs out ~" + fmtReset($0) } ?? "lasts past reset"))
            }
        }
        // Cluster lanes by provider (web parity): providers ordered by their
        // worst lane (rank, then usage), lanes worst-first inside the cluster.
        var worst: [String: Double] = [:]
        for it in out {
            let k = Double(it.pace.rank) + (100 - it.limit.pct) / 1000
            worst[it.svc] = min(worst[it.svc] ?? .infinity, k)
        }
        return out.sorted {
            let (wa, wb) = (worst[$0.svc]!, worst[$1.svc]!)
            if wa != wb { return wa < wb }
            if $0.svc != $1.svc { return $0.svc < $1.svc }
            return $0.pace.rank != $1.pace.rank ? $0.pace.rank < $1.pace.rank
                : $0.limit.resetEpoch < $1.limit.resetEpoch
        }
    }

    // Port of the web board's groupLayout(): axis spans min(windowStart) to
    // max(reset); each lane's bar is placed by its window's share of that span.
    private func layout(_ items: inout [LaneItem], bucket: Bucket,
                        now: Double) -> (start: Double, end: Double, nowFrac: Double) {
        let start = items.map(\.limit.windowStart).min()!
        let end = items.map(\.limit.resetEpoch).max()!
        let span = max(end - start, 1)
        let nowFrac = clamp01((now - start) / span)
        let weekly = bucket == .weekly
        let midTicks: [Double] = weekly && store.gridMode == "midnight"
            ? midnights(start: start, end: end).map { clamp01(($0 - start) / span) } : []
        for i in items.indices {
            items[i].left = clamp01((items[i].limit.windowStart - start) / span)
            items[i].width = clamp01(items[i].limit.windowSeconds / span)
            items[i].nowFrac = nowFrac
            items[i].barTicks = weekly && store.gridMode == "window"
                ? (1..<7).map { Double($0) / 7 } : []
            items[i].areaTicks = midTicks
        }
        return (start, end, nowFrac)
    }

    private func errorLines() -> [String] {
        store.enabledServices.compactMap { svc in
            let st = store.states[svc]!
            guard let err = st.error, !st.lanes.isEmpty else { return nil }
            return err.category == "auth" ? staleFix(svc) : "Can't reach \(svc) (\(err.category))"
        }
    }

    private func unavailableLines() -> [String] {
        store.enabledServices.compactMap { svc in
            let st = store.states[svc]!
            guard st.lanes.isEmpty else { return nil }
            if let err = st.error, err.category == "auth" { return staleFix(svc) }
            return "\(svc) — no data yet" + (st.error.map { " (\($0.category))" } ?? "")
        }
    }

    private var openAntigravityButton: some View {
        // `open -a` resolves the app by name via LaunchServices — same
        // behavior as the web dashboard's /api/open-antigravity endpoint.
        Button("Open Antigravity") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // "Antigravity IDE", not "Antigravity" — two apps exist and only
            // the IDE runs the language server we read usage from.
            p.arguments = ["-a", "Antigravity IDE"]
            try? p.run()
        }
        .controlSize(.small).font(.system(size: s(10)))
    }

    private func staleFix(_ svc: String) -> String {
        ["claude": "Token stale — open Claude Code once",
         "codex": "Token stale — run codex once",
         "cursor": "Token stale — open Cursor once",
         "gemini": "Token stale — run gemini once",
         "antigravity": "Antigravity not running — open it to see usage",
         "copilot": "Token stale — sign into Copilot once"][svc] ?? svc
    }
}

// MARK: - lane rows

private struct LaneRow: View {
    let item: LaneItem
    var scale: CGFloat = 1
    // Same provider as the lane above: caption printed once per cluster
    // (it's the cluster header), continuation rows tuck closer (web parity).
    var cont = false

    private func s(_ x: CGFloat) -> CGFloat { x * scale }

    var body: some View {
        HStack(alignment: .center, spacing: s(12)) {
            VStack(alignment: .leading, spacing: 1) {
                if !cont {
                    Text(item.svc.uppercased())
                        .font(.system(size: s(11), weight: .bold, design: .monospaced))
                        .kerning(0.8)
                }
                HStack(spacing: s(5)) {
                    Text(laneDisplay(item.label, item.limit)).font(.system(size: s(12)))
                    Text(item.limit.blocked ? "LIMIT REACHED" : item.pace.text)
                        .font(.system(size: s(9), weight: .semibold, design: .monospaced))
                        .foregroundStyle(item.limit.blocked ? Pace.over.color : item.pace.color)
                    if item.stale {
                        Text("stale \(item.age)")
                            .font(.system(size: s(9), weight: .semibold, design: .monospaced))
                            .padding(.horizontal, s(4)).padding(.vertical, 1)
                            .background(Capsule().fill(Pace.on.color))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: s(195), alignment: .leading)  // keep in sync with BoardView.labelWidth

            area

            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: s(4)) {
                    Text("\(Int(item.limit.pct.rounded()))%")
                        .font(.system(size: s(13), weight: .bold, design: .monospaced))
                        .foregroundStyle(item.pace.color)
                    Text("· \(countdown(item.limit.resetEpoch))")
                        .font(.system(size: s(10), design: .monospaced)).foregroundStyle(.secondary)
                }
                Text("resets \(fmtReset(item.limit.resetEpoch))")
                    .font(.system(size: s(9), design: .monospaced)).foregroundStyle(.secondary)
                if let v = item.verdict {
                    Text(v).font(.system(size: s(9), design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: s(160), alignment: .trailing)  // keep in sync with BoardView.metaWidth
        }
        .padding(.top, cont ? -s(4) : 0)  // tuck continuation rows under the cluster header
    }

    // The lane area = the group's full time span. The window bar occupies its
    // slice; midnight ticks and the now-line live on the area (shared axis).
    private var area: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                ForEach(item.areaTicks, id: \.self) { t in  // midnights, full height
                    Rectangle().fill(.secondary.opacity(0.3))
                        .frame(width: 1)
                        .offset(x: w * t)
                }
                windowBar(barWidth: w * item.width)
                    .offset(x: w * item.left)
                Rectangle()  // shared now-line, overhangs the bar like the web board
                    .fill(.primary)
                    .frame(width: s(2))
                    .offset(x: w * item.nowFrac - s(1))
            }
        }
        .frame(height: s(18))
        .accessibilityElement()
        .accessibilityLabel("\(item.svc) \(laneDisplay(item.label, item.limit)) — \(Int(item.limit.pct))% used, \(item.pace.text) pace, \(Int(item.elapsed))% of window elapsed")
    }

    private func windowBar(barWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: s(4)).fill(.quaternary)
            RoundedRectangle(cornerRadius: s(4))
                .fill(item.pace.color)
                .frame(width: barWidth * min(100, max(0, item.limit.pct)) / 100)
            ForEach(item.barTicks, id: \.self) { t in  // window/7 gridlines
                Rectangle().fill(.secondary.opacity(0.4))
                    .frame(width: 1)
                    .offset(x: barWidth * t)
            }
        }
        .frame(width: barWidth, height: s(14))
        .overlay(item.limit.blocked
                 ? RoundedRectangle(cornerRadius: s(4)).strokeBorder(Pace.over.color, lineWidth: 1.5)
                 : item.stale
                 ? RoundedRectangle(cornerRadius: s(4)).strokeBorder(Pace.on.color, lineWidth: 1.5)
                 : nil)
    }
}

// Web parity: between Claude sessions the rolling group shows a muted
// placeholder instead of disappearing.
private struct IdleLaneRow: View {
    var scale: CGFloat = 1
    private func s(_ x: CGFloat) -> CGFloat { x * scale }

    var body: some View {
        HStack(alignment: .center, spacing: s(12)) {
            VStack(alignment: .leading, spacing: 1) {
                Text("CLAUDE")
                    .font(.system(size: s(9), design: .monospaced)).kerning(0.8)
                    .foregroundStyle(.secondary)
                HStack(spacing: s(5)) {
                    Text("5-hour session").font(.system(size: s(12), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("IDLE").font(.system(size: s(9), weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: s(195), alignment: .leading)  // keep in sync with BoardView.labelWidth
            RoundedRectangle(cornerRadius: s(4)).fill(.quaternary)
                .frame(height: s(14))
            VStack(alignment: .trailing, spacing: 1) {
                Text("0%").font(.system(size: s(13), weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("no active session")
                    .font(.system(size: s(9), design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: s(160), alignment: .trailing)  // keep in sync with BoardView.metaWidth
        }
        .accessibilityElement()
        .accessibilityLabel("claude 5-hour session — no active session")
    }
}

// MARK: - formatting

private func fmtReset(_ epoch: Double) -> String {
    // "Thu 20 Aug, 09:00" — piecewise, because the combined formatter inserts
    // the locale's own separators ("Thu, 20 Aug at 09:00"). Matches the web board.
    let d = Date(timeIntervalSince1970: epoch)
    return d.formatted(.dateTime.weekday(.abbreviated)) + " "
        + d.formatted(.dateTime.day().month(.abbreviated))
        + ", " + d.formatted(.dateTime.hour().minute())
}

private func countdown(_ epoch: Double) -> String {
    let s = max(0, epoch - Date().timeIntervalSince1970)
    if s >= 86400 { return "\(Int((s / 86400).rounded()))d" }
    if s >= 3600 { return "\(Int((s / 3600).rounded()))h" }
    return "\(max(1, Int((s / 60).rounded())))m"
}

private func ageText(_ s: Double) -> String {
    if s < 90 { return "just now" }
    if s < 90 * 60 { return "\(Int((s / 60).rounded())) min ago" }
    if s < 36 * 3600 { return "\(Int((s / 3600).rounded())) h ago" }
    return "\(Int((s / 86400).rounded())) d ago"
}
