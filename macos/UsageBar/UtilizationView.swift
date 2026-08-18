// "Weekly utilization" view: per fixed-schedule lane, a column chart of the
// peak % reached in each reset window — short bars week after week mean plan
// headroom you're not using. Web parity: dashboard.py /history.
import SwiftUI

private let trackHeight: CGFloat = 120

private func shortDate(_ epoch: Double) -> String {
    Date(timeIntervalSince1970: epoch).formatted(.dateTime.day().month(.abbreviated))
}

struct UtilizationView: View {
    let store: Store

    var body: some View {
        let lanes = weeklyUtilization(store.history)
        let now = Date().timeIntervalSince1970
        VStack(alignment: .leading, spacing: 14) {
            Text("Weekly utilization").font(.system(size: 18, weight: .bold))
            Text("Peak usage reached in each reset window — how much of what you pay for you "
                 + "actually use. Short bars week after week mean headroom you're not touching.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if lanes.isEmpty {
                Text("No weekly history yet — usage accrues as the app polls.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 6)
            } else {
                ForEach(lanes) { UtilCard(lane: $0, now: now) }
                Text("* current window is still open — its bar is a partial peak. "
                     + "Weekly + monthly lanes only.")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UtilCard: View {
    let lane: LaneUtil
    let now: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(lane.svc.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).kerning(0.8)
                Text(lane.name).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text("avg \(Int(lane.avg.rounded()))%  ·  peak \(Int(lane.max.rounded()))%  ·  \(lane.count) wk")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(lane.windows.enumerated()), id: \.offset) { _, w in
                    column(w)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
    }

    private func column(_ w: UtilWindow) -> some View {
        let open = w.reset > now
        let frac = max(0, min(100, w.peak)) / 100
        return VStack(spacing: 4) {
            Text("\(Int(w.peak.rounded()))")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(0.5))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(open ? 0.5 : 1))
                    .frame(height: max(2, trackHeight * frac))
            }
            .frame(height: trackHeight)
            Text(shortDate(w.reset) + (open ? "*" : ""))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}

// Same translucent chrome + activation-policy handling as BoardWindow.
struct UtilizationWindow: View {
    let store: Store

    var body: some View {
        ScrollView {
            UtilizationView(store: store).frame(maxWidth: .infinity)
        }
        .background(.ultraThinMaterial)
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear { store.enterRegular() }
        .onDisappear { store.leaveRegular() }
    }
}
