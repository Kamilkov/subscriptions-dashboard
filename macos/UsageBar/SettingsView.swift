// Options window: General (single-number display), Providers (what is polled
// and shown), Updates.
import SwiftUI

private let providerNames: [String: String] = [
    "claude": "Anthropic — Claude Code",
    "codex": "OpenAI — Codex",
    "cursor": "Cursor",
    "antigravity": "Google — Antigravity",
    "copilot": "GitHub — Copilot",
]

// "claude.weekly_all" -> "Anthropic — Claude Code · Weekly - all models".
// Split on the FIRST dot only; lane labels may contain dots.
// Pass the limit when known so the vendor-provided lane name wins.
private func pinnedLabel(_ id: String, _ limit: Limit? = nil) -> String {
    let parts = id.split(separator: ".", maxSplits: 1)
    guard parts.count == 2 else { return id }
    let svc = String(parts[0])
    let lane = limit.map { laneDisplay(String(parts[1]), $0) } ?? laneName(String(parts[1]))
    return "\(providerNames[svc] ?? svc) · \(lane)"
}

struct SettingsView: View {
    let store: Store

    var body: some View {
        // Forms are List-backed and never report an intrinsic height, so each
        // tab pins its own: tall enough for the full content, scroll disabled.
        TabView {
            generalTab.frame(height: 400)
                .tabItem { Label("General", systemImage: "gearshape") }
            providersTab.frame(height: 420)
                .tabItem { Label("Providers", systemImage: "point.3.connected.trianglepath.dotted") }
            numbersTab.frame(height: 545)
                .tabItem { Label("Numbers", systemImage: "info.circle") }
            updatesTab.frame(height: 110)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .scrollDisabled(true)
        .frame(width: 500)
        // Settings opened from an accessory-mode app lands behind other windows.
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    private var generalTab: some View {
        // Keep a vanished pinned lane in the option list (marked unavailable)
        // so the Picker's selection always has a matching tag.
        let lanes = store.visibleLanes()
        let stale = store.pinnedLane.flatMap { p in lanes.contains { $0.id == p } ? nil : p }
        return Form {
            Section("Menu bar & small widget") {
                Picker("Show", selection: Binding(
                    get: { store.pinnedLane },
                    set: { store.setPinnedLane($0) })) {
                    Text("Automatic — worst lane").tag(String?.none)
                    ForEach(lanes, id: \.id) { lane in
                        Text(pinnedLabel(lane.id, lane.limit)).tag(String?.some(lane.id))
                    }
                    if let stale {
                        Text("\(pinnedLabel(stale)) (unavailable)").tag(String?.some(stale))
                    }
                }
                Text("Automatic picks the worst lane: blocked, then over pace, then highest usage. A pinned lane that disappears falls back to Automatic.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Menu bar label", selection: Binding(
                    get: { store.menuBarStyle },
                    set: { store.setMenuBarStyle($0) })) {
                    Text("Gauge icon — ⌗ 39%").tag("icon")
                    Text("\"AI\" — AI 39%").tag("ai")
                    Text("Provider name — claude 39%").tag("provider")
                }
                Text("Provider name shows which lane the number comes from.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Board background") {
                // Defaults mirror the web board's --page values.
                ColorPicker("Light mode", selection: bgBinding(dark: false, fallback: "F1F1F4"),
                            supportsOpacity: false)
                ColorPicker("Dark mode", selection: bgBinding(dark: true, fallback: "151517"),
                            supportsOpacity: false)
                Button("Reset to default") {
                    store.setBoardBg(dark: false, hex: nil)
                    store.setBoardBg(dark: true, hex: nil)
                }
                Text("Tints the board window's translucent background; each appearance keeps its own colour. Colours that sink text contrast below 4.5:1 are not applied.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func bgBinding(dark: Bool, fallback: String) -> Binding<Color> {
        Binding(
            get: { colorFromHex((dark ? store.boardBgDark : store.boardBgLight) ?? fallback) ?? .clear },
            set: { store.setBoardBg(dark: dark, hex: hexFromColor($0)) })
    }

    private var providersTab: some View {
        Form {
            Section("Providers") {
                ForEach(services, id: \.self) { svc in
                    Toggle(providerNames[svc] ?? svc, isOn: Binding(
                        get: { store.enabled.contains(svc) },
                        set: { store.setEnabled(svc, $0) }))
                }
            }
            Section("Windows") {
                ForEach(Bucket.allCases, id: \.self) { bucket in
                    Toggle("\(bucket.title) — \(bucket.hint)", isOn: Binding(
                        get: { store.enabledBuckets.contains(bucket.rawValue) },
                        set: { store.setBucket(bucket, $0) }))
                }
            }
            Text("Disabled providers are not polled; disabled windows are hidden. Both disappear from the board and widget.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // One (term, definition) per computed number — same wording as the web
    // board's "How these numbers are computed" section; edit both together.
    private static let numbers: [(String, String)] = [
        ("The bar", "Fill is % of quota used; the tick is % of the window elapsed. The whole board is that one comparison: am I burning faster than time is passing?"),
        ("Pace badge", "Usage ÷ elapsed. UNDER below 0.85×, OVER above 1.15×, ON PACE between. The first ~2% of a window always reads ON PACE so one session can't skew the ratio."),
        ("runs out ~…", "A trend fitted over the last 24 hours only, extrapolated forward. A lane can be UNDER for the week yet still warn — the badge looks back, the projection looks forward. If the trend lasts past the reset, it says so instead."),
        ("BLOCKED", "Shown only when the vendor reports the limit actually enforced, not merely warned. Remaining budget is shown when the vendor provides it."),
        ("Menu bar number", "Automatic picks the worst visible lane: blocked first, then over pace, then highest usage. Pin a specific lane in General."),
        ("grid: midnights / window ÷7", "Two ways to slice weekly bars: gridlines at local midnights on the shared axis, or each bar divided into seven equal sevenths of its own window."),
        ("Stale lanes", "A lane that can't be fetched keeps its last good numbers and is marked stale with their age — never a guessed value."),
    ]

    private var numbersTab: some View {
        Form {
            Section("How these numbers are computed") {
                ForEach(Self.numbers, id: \.0) { term, def in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(term).font(.callout.weight(.semibold))
                        Text(def).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var updatesTab: some View {
        Form {
            Section("Updates") {
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates…") { Updater.controller.checkForUpdates(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
