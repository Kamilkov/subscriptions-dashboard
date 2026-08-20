// Deterministic Store.refresh concurrency + retention tests — fetchers are
// injected and gated on task handles, so nothing here touches the network,
// real timing, or the user's real history file.
import XCTest
@testable import UsageBar

private actor Counter {
    var counts: [String: Int] = [:]
    func bump(_ k: String) { counts[k, default: 0] += 1 }
}

@MainActor
final class StoreTests: XCTestCase {

    // Every Store(startPolling: false) still runs HistoryFile.load() (which
    // also compacts the file), so EVERY test here gets its own temp history
    // file; the exact prior URL is restored and only the temp dir removed.
    private var savedHistoryURL: URL!
    private var savedSharedURL: URL!
    private var tempDir: URL!

    override func setUp() async throws {
        savedHistoryURL = HistoryFile.url
        savedSharedURL = Snapshot.sharedURL
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usagebar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        HistoryFile.url = tempDir.appendingPathComponent("history.jsonl")
        // Every refresh ends in publishShared -> Snapshot.writeShared; that
        // must hit this test's temp dir, never the real App Group container.
        Snapshot.sharedURL = tempDir.appendingPathComponent("latest.json")
    }

    override func tearDown() async throws {
        HistoryFile.url = savedHistoryURL
        Snapshot.sharedURL = savedSharedURL
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> Store { Store(startPolling: false) }

    // Spin until the given fetcher has started (deterministic: bounded yields).
    private func waitForStart(_ counter: Counter, _ key: String) async {
        for _ in 0..<10_000 {
            if await counter.counts[key] != nil { return }
            await Task.yield()
        }
        XCTFail("fetcher \(key) never started")
    }

    func testEnableDuringFullPollQueuesMissingProvider() async {
        let store = makeStore()
        store.enabled = ["claude"]
        let counter = Counter()
        var release: CheckedContinuation<Void, Never>?
        let gate = Task { await withCheckedContinuation { release = $0 } }

        let fetchers: [String: @Sendable () async throws -> [String: Limit]] = [
            "claude": { await counter.bump("claude"); await gate.value; return [:] },
            "codex": { await counter.bump("codex"); return [:] },
        ]
        let poll = Task { await store.refresh(force: true, fetchers: fetchers) }
        await waitForStart(counter, "claude")

        // Mid-poll: enable codex (its refresh(only:) must queue, not vanish)
        // and re-request claude (already in flight — must NOT queue a duplicate).
        store.enabled.insert("codex")
        await store.refresh(only: ["codex"], fetchers: fetchers)
        await store.refresh(only: ["claude"], fetchers: fetchers)

        release?.resume()
        await poll.value

        let counts = await counter.counts
        XCTAssertEqual(counts["codex"], 1, "queued fetch must run exactly once after the poll")
        XCTAssertEqual(counts["claude"], 1, "provider already in flight must not be re-fetched")
    }

    func testFullRefreshDuringPartialPollFetchesRest() async {
        let store = makeStore()
        store.enabled = ["claude", "codex"]
        let counter = Counter()
        var release: CheckedContinuation<Void, Never>?
        let gate = Task { await withCheckedContinuation { release = $0 } }

        let fetchers: [String: @Sendable () async throws -> [String: Limit]] = [
            "claude": { await counter.bump("claude"); await gate.value; return [:] },
            "codex": { await counter.bump("codex"); return [:] },
        ]
        let partial = Task { await store.refresh(only: ["claude"], fetchers: fetchers) }
        await waitForStart(counter, "claude")

        // A FULL refresh during the partial poll: the uncovered provider must
        // be queued (not dropped), the in-flight one not fetched twice.
        await store.refresh(force: true, fetchers: fetchers)

        release?.resume()
        await partial.value

        let counts = await counter.counts
        XCTAssertEqual(counts["codex"], 1, "full refresh during partial poll must fetch the rest")
        XCTAssertEqual(counts["claude"], 1, "no duplicate fetch for the in-flight provider")
    }

    // MARK: - board background contrast persistence

    // The hosted test process may share the real app's defaults domain: snapshot
    // the exact pre-test values (absence as nil) and restore them exactly —
    // plain cleanup could destroy the user's real settings.
    private func withBgDefaultsRestored(_ body: () -> Void) {
        let d = UserDefaults.standard
        let saved = ["boardBgLight": d.string(forKey: "boardBgLight"),
                     "boardBgDark": d.string(forKey: "boardBgDark")]
        defer {
            for (key, value) in saved {
                if let value { d.set(value, forKey: key) }
                else { d.removeObject(forKey: key) }
            }
        }
        body()
    }

    func testPersistedUnsafeBackgroundIsPurgedAtInit() {
        withBgDefaultsRestored {
            let d = UserDefaults.standard
            d.set("000000", forKey: "boardBgLight")  // unsafe in light mode
            d.set("151517", forKey: "boardBgDark")   // safe in dark mode
            let store = Store(startPolling: false)
            XCTAssertNil(store.boardBgLight, "unsafe persisted value must be ignored")
            XCTAssertNil(d.string(forKey: "boardBgLight"), "…and removed from defaults")
            XCTAssertEqual(store.boardBgDark, "151517", "safe persisted value survives")
        }
    }

    func testSetBoardBgRejectsUnsafeHex() {
        withBgDefaultsRestored {
            let store = Store(startPolling: false)
            store.setBoardBg(dark: false, hex: nil)
            store.setBoardBg(dark: false, hex: "000000")  // fails contrast -> no-op
            XCTAssertNil(store.boardBgLight)
            XCTAssertNil(UserDefaults.standard.string(forKey: "boardBgLight"))
        }
    }

    // MARK: - continuous retention

    func testRefreshPrunesHistoryOnDiskAndInMemory() async throws {
        // HistoryFile already points at this test's temp file (see setUp).
        let now = Date().timeIntervalSince1970
        let oldSnap = HistorySnapshot(tsEpoch: now - 61 * 86400, lanes: [:])
        let store = Store(startPolling: false)  // init's load precedes seeding,
        store.enabled = ["claude"]              // so startup pruning can't help
        HistoryFile.rewrite([oldSnap])
        store.history = [oldSnap]

        await store.refresh(force: true, fetchers: ["claude": { [:] }])

        let cutoff = now - 60 * 86400
        XCTAssertTrue(store.history.allSatisfy { $0.tsEpoch >= cutoff },
                      "expired snapshots must leave memory without a restart")
        let text = try String(contentsOf: HistoryFile.url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "expired line must leave the file without a restart")
    }
}
