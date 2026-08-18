import SwiftUI
import Sparkle

// Sparkle auto-updater: checks SUFeedURL on its own schedule; the Options
// window exposes a manual check.
@MainActor
enum Updater {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}

// Launch with `open UsageBar.app --args -openBoard 1` (or -openSettings 1) to
// open that window immediately through the same policy-first path as its
// button — used for automated UI verification.
private struct BoardOpener: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            let defaults = UserDefaults.standard
            guard defaults.bool(forKey: "openBoard") || defaults.bool(forKey: "openSettings") else { return }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                if defaults.bool(forKey: "openBoard") { openWindow(id: "board") }
                if defaults.bool(forKey: "openSettings") { openSettings() }
            }
        }
    }
}

// After a Sparkle update the widget extension keeps running from the replaced
// bundle and renders blank (reloadAllTimelines does NOT restart it — only the
// process dying does). On first launch of a new version, kill the leftover so
// chronod respawns it from the fresh bundle.
private func killStaleWidgetAfterUpdate() {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let defaults = UserDefaults.standard
    guard defaults.string(forKey: "lastRunVersion") != version else { return }
    defaults.set(version, forKey: "lastRunVersion")
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    kill.arguments = ["UsageBarWidget"]
    try? kill.run()  // no leftover process is fine — killall exits 1, ignored
}

@main
struct UsageBarApp: App {
    @State private var store = Store()

    init() { killStaleWidgetAfterUpdate() }

    var body: some Scene {
        MenuBarExtra {
            BoardView(store: store)
        } label: {
            // Worst lane's usage % lives in the menu bar itself; the "ai" and
            // "provider" styles say so in text instead of the gauge icon.
            if store.menuBarStyle == "icon" {
                Image(systemName: "gauge.with.needle")
            }
            Text(store.menuTitle)
            BoardOpener()
        }
        .menuBarExtraStyle(.window)

        // Standalone board for a dedicated display. Restoration is disabled
        // on purpose: a restored window would be created while the app is
        // still an accessory (LSUIElement) and get stamped without
        // minimize/zoom/fullscreen. The only creation path is the Open Window
        // button, which flips the activation policy to .regular FIRST, so
        // AppKit stamps the window correctly and nothing needs restamping.
        Window("Usage Board", id: "board") {
            BoardWindow(store: store)
        }
        .defaultSize(width: 720, height: 640)
        .restorationBehavior(.disabled)
        .commands {
            // App menu, under "About" — the standard spot when a window
            // is frontmost (the menu bar dropdown has its own ⋯ item).
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.controller.checkForUpdates(nil) }
            }
        }

        Window("Weekly Utilization", id: "utilization") {
            UtilizationWindow(store: store)
        }
        .defaultSize(width: 720, height: 560)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(store: store)
        }
    }
}
