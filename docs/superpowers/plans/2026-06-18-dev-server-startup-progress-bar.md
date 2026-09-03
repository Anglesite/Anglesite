# Dev-server startup progress bar — Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the indeterminate spinner shown while `astro dev` boots with a determinate progress bar that advances through real startup milestones, creeps smoothly between them using last-startup timing, and shows a phase message underneath.

**Architecture:** A pure, host-independent state machine (`StartupProgressEstimator`) plus a persistence type (`StartupTimingStore`) live in `AnglesiteCore` so they get CI coverage under `swift test`. A thin `@MainActor @Observable StartupProgressModel` in `AnglesiteApp` wires the estimator to the signals the app already has — the `SiteRuntimeState` stream and `LogCenter`'s `astro:<siteID>` lines — runs the ease timer, and persists timing on success. The `SiteRuntimeState` enum and the dev-server readiness path are untouched.

**Tech Stack:** Swift 6.4 / SwiftUI (macOS 27+), Swift Testing, `UserDefaults`-backed persistence, Swift actors (`LogCenter`).

## Global Constraints

- **ES/Swift module rules:** `AnglesiteCore` is an SPM library with no SwiftUI import — keep the new core types Foundation-only. (`AppSettings.swift` is the precedent.)
- **No third-party deps** beyond Apple's frameworks.
- **Toolchain:** SwiftPM commands MUST use the Xcode 27 toolchain. Prefix every `swift`/`xcrun` invocation with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` and call via `xcrun`. The CommandLineTools `swift` is broken/too old.
- **Tests:** Swift Testing (`import Testing`, `@Test`, `#expect`). Core types only — `AnglesiteApp` has no CI test target (hosted app tests are blocked on CI), so app-layer glue is verified by compiling, not unit tests.
- **Worktree:** Work happens in `.claude/worktrees/startup-progress-bar/` on branch `feature/startup-progress-bar`. Before any `xcodebuild`, run `xcodegen generate` and export `ANGLESITE_PLUGIN_SRC=<…>/github.com/Anglesite/anglesite`.
- **Curated phase messages only** — no numeric ETA, no "step N of M", no raw Astro log text.
- **Fraction is monotonic** — never decreases, never reaches `1.0` before the `.ready` anchor.

**Reference design:** `docs/superpowers/specs/2026-06-18-dev-server-startup-progress-bar-design.md`

---

### Task 1: `StartupProfile` + `StartupTimingStore` (per-site timing persistence)

**Files:**
- Create: `Sources/AnglesiteCore/StartupTiming.swift`
- Test: `Tests/AnglesiteCoreTests/StartupTimingStoreTests.swift`

**Interfaces:**
- Consumes: nothing (leaf type).
- Produces:
  - `StartupProfile` — `Sendable, Equatable, Codable` value with `launchingToBuilding: TimeInterval`, `buildingToConnecting: TimeInterval`, `connectingToReady: TimeInterval`; `static let default: StartupProfile`; `var isPlausible: Bool`.
  - `StartupTimingStore` — `final class`, `@unchecked Sendable`; `static let shared`; `init(defaults: UserDefaults)`; `func profile(for siteID: String) -> StartupProfile`; `func record(_ profile: StartupProfile, for siteID: String)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/StartupTimingStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

/// `final class` so `deinit` drops the throwaway suite (mirrors AppSettingsTests).
final class StartupTimingStoreTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        let suite = "test-anglesite-startup-\(UUID().uuidString)"
        suiteName = suite
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit { defaults.removePersistentDomain(forName: suiteName) }

    @Test("Absent timing falls back to the default profile")
    func absentFallsBackToDefault() {
        let store = StartupTimingStore(defaults: defaults)
        #expect(store.profile(for: "site-a") == StartupProfile.default)
    }

    @Test("Record then read round-trips a plausible profile")
    func roundTrip() {
        let store = StartupTimingStore(defaults: defaults)
        let p = StartupProfile(launchingToBuilding: 0.4, buildingToConnecting: 2.1, connectingToReady: 0.9)
        store.record(p, for: "site-a")
        #expect(store.profile(for: "site-a") == p)
    }

    @Test("Timing is isolated per site id")
    func perSiteIsolation() {
        let store = StartupTimingStore(defaults: defaults)
        let p = StartupProfile(launchingToBuilding: 0.4, buildingToConnecting: 2.1, connectingToReady: 0.9)
        store.record(p, for: "site-a")
        #expect(store.profile(for: "site-b") == StartupProfile.default)
    }

    @Test("Implausible profile is not recorded")
    func implausibleIgnored() {
        let store = StartupTimingStore(defaults: defaults)
        let bad = StartupProfile(launchingToBuilding: -1, buildingToConnecting: 0, connectingToReady: 0)
        store.record(bad, for: "site-a")
        #expect(store.profile(for: "site-a") == StartupProfile.default)
    }

    @Test("Corrupt stored data falls back to the default profile")
    func corruptFallsBack() {
        let store = StartupTimingStore(defaults: defaults)
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "anglesite.startupTiming.site-a")
        #expect(store.profile(for: "site-a") == StartupProfile.default)
    }

    @Test("Default profile is plausible and weighted toward building")
    func defaultIsPlausible() {
        let d = StartupProfile.default
        #expect(d.isPlausible)
        #expect(d.buildingToConnecting > d.launchingToBuilding)
        #expect(d.buildingToConnecting > d.connectingToReady)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test --filter StartupTimingStoreTests`
Expected: FAIL — `cannot find 'StartupTimingStore' in scope` / `cannot find 'StartupProfile' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/StartupTiming.swift`:

```swift
import Foundation

/// Expected per-segment durations of a dev-server startup, used to pace the smooth fill of the
/// startup progress bar between milestone anchors. One segment per gap in the milestone sequence
/// launching → building → connecting → ready.
public struct StartupProfile: Sendable, Equatable, Codable {
    public var launchingToBuilding: TimeInterval
    public var buildingToConnecting: TimeInterval
    public var connectingToReady: TimeInterval

    public init(launchingToBuilding: TimeInterval, buildingToConnecting: TimeInterval, connectingToReady: TimeInterval) {
        self.launchingToBuilding = launchingToBuilding
        self.buildingToConnecting = buildingToConnecting
        self.connectingToReady = connectingToReady
    }

    /// Built-in fallback used on first run and when stored timing is missing/corrupt. Calibrated
    /// to the default template: a quick spawn, a few seconds of Astro/Vite build, a short tail.
    public static let `default` = StartupProfile(
        launchingToBuilding: 0.5,
        buildingToConnecting: 3.0,
        connectingToReady: 1.5
    )

    /// Whether every segment is finite and non-negative and the total is within a sane ceiling.
    /// Guards against persisting a degenerate or absurd measurement (e.g. a machine asleep mid-boot).
    public var isPlausible: Bool {
        let segments = [launchingToBuilding, buildingToConnecting, connectingToReady]
        guard segments.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        let total = segments.reduce(0, +)
        return total > 0 && total <= 120
    }
}

/// Persists the most recent *successful* `StartupProfile` per site in `UserDefaults`, so the next
/// startup can pace its progress bar against how long the last one actually took. Reads fall back
/// to `StartupProfile.default` whenever nothing plausible is stored.
public final class StartupTimingStore: @unchecked Sendable {
    /// Shared instance bound to `UserDefaults.standard`. Tests construct their own with a scratch suite.
    public static let shared = StartupTimingStore(defaults: .standard)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func key(for siteID: String) -> String { "anglesite.startupTiming.\(siteID)" }

    /// Last successful profile for `siteID`, or `.default` when absent, undecodable, or implausible.
    public func profile(for siteID: String) -> StartupProfile {
        guard
            let data = defaults.data(forKey: key(for: siteID)),
            let decoded = try? JSONDecoder().decode(StartupProfile.self, from: data),
            decoded.isPlausible
        else {
            return .default
        }
        return decoded
    }

    /// Persist a completed successful startup. Implausible or unencodable profiles are dropped.
    public func record(_ profile: StartupProfile, for siteID: String) {
        guard profile.isPlausible, let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key(for: siteID))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test --filter StartupTimingStoreTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/StartupTiming.swift Tests/AnglesiteCoreTests/StartupTimingStoreTests.swift
git commit -m "feat(preview): persist per-site dev-server startup timing"
```

---

### Task 2: `StartupPhase` + `StartupProgressEstimator` (pure milestone state machine)

**Files:**
- Create: `Sources/AnglesiteCore/StartupProgressEstimator.swift`
- Test: `Tests/AnglesiteCoreTests/StartupProgressEstimatorTests.swift`

**Interfaces:**
- Consumes: `StartupProfile` (Task 1); `SiteRuntimeState` (existing, `AnglesiteCore/SiteRuntime.swift`); `AstroDevServer.parseReadyURL(_:)` (existing `public static`).
- Produces:
  - `StartupPhase` — `String`-raw `enum`, `Sendable, Equatable, CaseIterable`: `idle, launching, building, connecting, ready, failed`; `var message: String`.
  - `StartupProgressEstimator` — `Sendable, Equatable` value type. `init(profile: StartupProfile = .default)`. Properties `phase: StartupPhase`, `fraction: Double`, `message: String`, `isActive: Bool`, `completedProfile: StartupProfile?`. Methods `mutating func ingest(runtimeState: SiteRuntimeState, at: TimeInterval)`, `mutating func ingest(logText: String, at: TimeInterval)`, `mutating func tick(now: TimeInterval)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/StartupProgressEstimatorTests.swift`:

```swift
import Testing
import Foundation
@testable import AnglesiteCore

struct StartupProgressEstimatorTests {

    private func make() -> StartupProgressEstimator {
        // A fast, explicit profile so ticks reach meaningful fractions at small times.
        StartupProgressEstimator(profile: StartupProfile(
            launchingToBuilding: 1, buildingToConnecting: 1, connectingToReady: 1))
    }

    @Test("Starts idle at zero with no message")
    func startsIdle() {
        let est = make()
        #expect(est.phase == .idle)
        #expect(est.fraction == 0)
        #expect(est.message == "")
        #expect(est.isActive == false)
    }

    @Test(".starting enters launching and becomes active")
    func startingEntersLaunching() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 0)
        #expect(est.phase == .launching)
        #expect(est.isActive)
        #expect(est.message == "Starting dev server…")
    }

    @Test("A non-URL astro line advances launching → building")
    func firstLogEntersBuilding() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 0)
        est.ingest(logText: "astro v5.0.0 ready in 120 ms", at: 0.2)
        #expect(est.phase == .building)
        #expect(est.message == "Building site…")
        #expect(est.fraction >= 0.15)   // jumped to building's lower bound
    }

    @Test("A Local-URL line advances to connecting")
    func urlLineEntersConnecting() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 0)
        est.ingest(logText: "  Building...", at: 0.2)
        est.ingest(logText: "┃ Local    http://localhost:4321/", at: 0.5)
        #expect(est.phase == .connecting)
        #expect(est.message == "Connecting to preview…")
        #expect(est.fraction >= 0.55)
    }

    @Test("A URL line as the very first log jumps straight to connecting")
    func urlFirstLineSkipsBuilding() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 0)
        est.ingest(logText: "Local http://localhost:4321/", at: 0.3)
        #expect(est.phase == .connecting)
        #expect(est.fraction >= 0.55)
    }

    @Test(".ready completes the bar to 1.0")
    func readyCompletes() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 0)
        est.ingest(logText: "x", at: 0.2)
        est.ingest(logText: "Local http://localhost:4321/", at: 0.5)
        est.ingest(runtimeState: .ready(siteID: "s", url: URL(string: "http://localhost:4321/")!), at: 1.0)
        #expect(est.phase == .ready)
        #expect(est.fraction == 1.0)
        #expect(est.isActive == false)
    }

    @Test("tick eases the fraction forward but never reaches the phase cap")
    func tickAsymptotesUnderCap() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 0)
        est.ingest(logText: "building", at: 0)   // in building, cap 0.55
        est.tick(now: 0.5)
        let mid = est.fraction
        #expect(mid > 0.15)
        #expect(mid < 0.55)
        // Far past the expected segment: approaches the cap but never hits it.
        est.tick(now: 100)
        #expect(est.fraction < 0.55)
        #expect(est.fraction > mid)
    }

    @Test("fraction is monotonic non-decreasing across ticks and anchors")
    func monotonic() {
        var est = make()
        var last = 0.0
        func checkAndAdvance(_ f: Double) { #expect(f >= last); last = f }

        est.ingest(runtimeState: .starting(siteID: "s"), at: 0); checkAndAdvance(est.fraction)
        est.tick(now: 0.3); checkAndAdvance(est.fraction)
        est.ingest(logText: "building", at: 0.4); checkAndAdvance(est.fraction)
        est.tick(now: 0.8); checkAndAdvance(est.fraction)
        est.ingest(logText: "Local http://localhost:4321/", at: 1.0); checkAndAdvance(est.fraction)
        est.tick(now: 1.5); checkAndAdvance(est.fraction)
        est.ingest(runtimeState: .ready(siteID: "s", url: URL(string: "http://x/")!), at: 2.0); checkAndAdvance(est.fraction)
    }

    @Test("Fraction never reaches 1.0 before the ready anchor")
    func neverCompletesEarly() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 0)
        est.ingest(logText: "building", at: 0.1)
        est.ingest(logText: "Local http://x/", at: 0.2)
        est.tick(now: 10_000)
        #expect(est.fraction < 1.0)
    }

    @Test(".failed stops activity and clears the bar")
    func failedResets() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 0)
        est.ingest(logText: "building", at: 0.1)
        est.ingest(runtimeState: .failed(siteID: "s", message: "boom"), at: 0.5)
        #expect(est.phase == .failed)
        #expect(est.isActive == false)
        #expect(est.message == "")
    }

    @Test("Logs after ready are ignored")
    func logsAfterReadyIgnored() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 0)
        est.ingest(runtimeState: .ready(siteID: "s", url: URL(string: "http://x/")!), at: 1.0)
        est.ingest(logText: "Local http://other/", at: 1.5)
        #expect(est.phase == .ready)
        #expect(est.fraction == 1.0)
    }

    @Test("completedProfile reports measured segments after ready")
    func completedProfileMeasuresSegments() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 10)
        est.ingest(logText: "building", at: 10.5)                       // launching→building = 0.5
        est.ingest(logText: "Local http://x/", at: 13.5)               // building→connecting = 3.0
        est.ingest(runtimeState: .ready(siteID: "s", url: URL(string: "http://x/")!), at: 15.0) // connecting→ready = 1.5
        let p = est.completedProfile
        #expect(p != nil)
        #expect(abs((p?.launchingToBuilding ?? -1) - 0.5) < 0.0001)
        #expect(abs((p?.buildingToConnecting ?? -1) - 3.0) < 0.0001)
        #expect(abs((p?.connectingToReady ?? -1) - 1.5) < 0.0001)
    }

    @Test("completedProfile is nil before ready")
    func completedProfileNilBeforeReady() {
        var est = make()
        est.ingest(runtimeState: .starting(siteID: "s"), at: 0)
        est.ingest(logText: "building", at: 0.2)
        #expect(est.completedProfile == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test --filter StartupProgressEstimatorTests`
Expected: FAIL — `cannot find 'StartupProgressEstimator' in scope` / `cannot find 'StartupPhase' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/StartupProgressEstimator.swift`:

```swift
import Foundation

/// The coarse milestone a dev-server startup is currently at. Drives both the progress bar's fill
/// range and the curated message shown beneath it.
public enum StartupPhase: String, Sendable, Equatable, CaseIterable {
    case idle
    case launching
    case building
    case connecting
    case ready
    case failed

    /// Forward-only ordering. The estimator only ever advances to a higher-ranked active phase.
    var rank: Int {
        switch self {
        case .idle:       return 0
        case .launching:  return 1
        case .building:   return 2
        case .connecting: return 3
        case .ready:      return 4
        case .failed:     return 5
        }
    }

    /// `[start, cap]` fraction band the bar occupies while in this phase. The smooth fill eases
    /// from `start` toward `cap` but only the next real anchor crosses into the following band.
    var fillRange: (start: Double, cap: Double) {
        switch self {
        case .idle, .failed: return (0, 0)
        case .launching:     return (0.0, 0.15)
        case .building:      return (0.15, 0.55)
        case .connecting:    return (0.55, 0.90)
        case .ready:         return (1.0, 1.0)
        }
    }

    public var message: String {
        switch self {
        case .idle, .failed, .ready: return ""
        case .launching:  return "Starting dev server…"
        case .building:   return "Building site…"
        case .connecting: return "Connecting to preview…"
        }
    }
}

/// Pure, time-base-agnostic state machine that turns startup signals into a determinate progress
/// fraction and a phase message. It is driven entirely by its caller — runtime-state changes, the
/// site's `astro` stdout lines, and periodic `tick`s — with timestamps supplied as parameters, so
/// it carries no clock and is trivially testable. The `StartupProgressModel` (AnglesiteApp) owns
/// the clock, the `LogCenter` subscription, and persistence.
///
/// Fill is anchored by real milestones and eased between them using a `StartupProfile`: within a
/// phase the fraction approaches — but never reaches — that phase's cap, so the bar keeps inching
/// on overrun and only a genuine anchor completes a segment. `.ready` jumps to `1.0`.
public struct StartupProgressEstimator: Sendable, Equatable {
    public private(set) var phase: StartupPhase = .idle
    public private(set) var fraction: Double = 0

    private let profile: StartupProfile
    private var phaseEnteredAt: TimeInterval = 0
    private var anchorTimes: [StartupPhase: TimeInterval] = [:]

    /// How sharply the fill approaches the cap. At `elapsed == expectedSegment` the bar is ~92% of
    /// the way across the band; it asymptotes to (but never reaches) the cap thereafter.
    private static let easeK = 2.5

    public init(profile: StartupProfile = .default) {
        self.profile = profile
    }

    public var message: String { phase.message }

    public var isActive: Bool {
        phase == .launching || phase == .building || phase == .connecting
    }

    /// After a successful startup, the measured per-segment durations — for persisting back to the
    /// `StartupTimingStore`. `nil` until `.ready`. Missing intermediate anchors collapse to zero-
    /// length segments (e.g. a URL line that arrived before any other astro output).
    public var completedProfile: StartupProfile? {
        guard phase == .ready,
              let tLaunch = anchorTimes[.launching],
              let tReady = anchorTimes[.ready] else { return nil }
        let tBuild = anchorTimes[.building] ?? tLaunch
        let tConn = anchorTimes[.connecting] ?? tBuild
        return StartupProfile(
            launchingToBuilding: max(tBuild - tLaunch, 0),
            buildingToConnecting: max(tConn - tBuild, 0),
            connectingToReady: max(tReady - tConn, 0)
        )
    }

    /// Drive launching/ready/failed anchors off the runtime's state machine.
    public mutating func ingest(runtimeState: SiteRuntimeState, at now: TimeInterval) {
        switch runtimeState {
        case .starting:
            enter(.launching, at: now)
        case .ready:
            enter(.ready, at: now)
        case .failed:
            phase = .failed
            fraction = 0
        case .idle:
            phase = .idle
            fraction = 0
            anchorTimes = [:]
        }
    }

    /// Drive building/connecting anchors off the site's `astro` stdout. The caller is responsible
    /// for filtering to the `astro:<siteID>` stdout stream before calling.
    public mutating func ingest(logText: String, at now: TimeInterval) {
        guard isActive else { return }
        if AstroDevServer.parseReadyURL(logText) != nil {
            enter(.connecting, at: now)
        } else {
            enter(.building, at: now)
        }
    }

    /// Ease the fraction toward the current phase's cap, paced by the expected segment duration.
    /// No-op once the startup is no longer active.
    public mutating func tick(now: TimeInterval) {
        guard isActive else { return }
        let (start, cap) = phase.fillRange
        let expected = max(expectedSegment(for: phase), 0.05)
        let r = max(now - phaseEnteredAt, 0) / expected
        let eased = 1 - exp(-Self.easeK * r)               // 0 at r=0, →1, never 1
        let target = start + (cap - start) * eased
        // Monotonic, and strictly below the cap so only a real anchor can cross into the next band.
        fraction = min(max(fraction, target), cap - 0.0001)
    }

    // MARK: - Internals

    /// Expected duration of the segment we wait through *while in* `phase`.
    private func expectedSegment(for phase: StartupPhase) -> TimeInterval {
        switch phase {
        case .launching:  return profile.launchingToBuilding
        case .building:   return profile.buildingToConnecting
        case .connecting: return profile.connectingToReady
        default:          return 0
        }
    }

    /// Advance to a higher-ranked phase, recording its anchor time and snapping the fraction up to
    /// the new band's start. Lower-or-equal ranks are ignored (forward-only).
    private mutating func enter(_ newPhase: StartupPhase, at now: TimeInterval) {
        guard newPhase.rank > phase.rank else { return }
        anchorTimes[newPhase] = now
        phaseEnteredAt = now
        phase = newPhase
        fraction = max(fraction, newPhase.fillRange.start)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test --filter StartupProgressEstimatorTests`
Expected: PASS (13 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/StartupProgressEstimator.swift Tests/AnglesiteCoreTests/StartupProgressEstimatorTests.swift
git commit -m "feat(preview): milestone state machine for startup progress"
```

---

### Task 3: `StartupProgressModel` (app-layer glue: signals, ticker, persistence)

**Files:**
- Create: `Sources/AnglesiteApp/StartupProgressModel.swift`

**Interfaces:**
- Consumes: `StartupProgressEstimator`, `StartupPhase`, `StartupTimingStore` (Tasks 1–2); `SiteRuntimeState`, `LogCenter` (existing, `AnglesiteCore`).
- Produces: `StartupProgressModel` — `@MainActor @Observable final class`. `init(timingStore: StartupTimingStore = .shared, logCenter: LogCenter = .shared, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })`. Read-only `phase: StartupPhase`, `fraction: Double`, `message: String`. `func ingest(state: SiteRuntimeState)`; `func stop()`.

This is thin app-layer glue with no CI test target, so it has no TDD cycle — it is verified by compiling the app target (Task 4's build step covers both files). Implement it directly.

- [ ] **Step 1: Write the implementation**

Create `Sources/AnglesiteApp/StartupProgressModel.swift`:

```swift
import SwiftUI
import AnglesiteCore

/// Drives the determinate startup progress bar for one site window. Owns a pure
/// `StartupProgressEstimator` and feeds it three things: runtime-state changes (pushed in by
/// `SiteWindow` via `ingest(state:)`), the site's `astro:<id>` stdout lines (subscribed from
/// `LogCenter`), and ~20 fps `tick`s that ease the fill forward. On success it persists the
/// measured timing so the next startup paces itself. The estimator stays host-independent and
/// CI-tested; this class is the SwiftUI/actor wiring around it.
@MainActor
@Observable
final class StartupProgressModel {
    private(set) var phase: StartupPhase = .idle
    private(set) var fraction: Double = 0
    private(set) var message: String = ""

    private let timingStore: StartupTimingStore
    private let logCenter: LogCenter
    private let clock: @Sendable () -> TimeInterval

    private var estimator = StartupProgressEstimator()
    private var siteID: String?
    private var logTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    init(
        timingStore: StartupTimingStore = .shared,
        logCenter: LogCenter = .shared,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.timingStore = timingStore
        self.logCenter = logCenter
        self.clock = clock
    }

    /// Push a runtime-state change. `.starting` (re)arms tracking for the site; `.ready` records
    /// timing and completes the bar; `.failed`/`.idle` tear the tracker down.
    func ingest(state: SiteRuntimeState) {
        switch state {
        case .starting(let id):
            begin(siteID: id)
        case .ready(let id, _):
            estimator.ingest(runtimeState: state, at: clock())
            if let profile = estimator.completedProfile {
                timingStore.record(profile, for: id)
            }
            publish()
            stop()
        case .failed, .idle:
            estimator.ingest(runtimeState: state, at: clock())
            publish()
            stop()
        }
    }

    /// Cancel the log subscription and ticker. Safe to call repeatedly.
    func stop() {
        logTask?.cancel(); logTask = nil
        tickTask?.cancel(); tickTask = nil
    }

    // MARK: - Internals

    private func begin(siteID: String) {
        // Re-arm only on a genuinely new startup; ignore a duplicate `.starting` for the same site.
        if self.siteID == siteID && estimator.isActive { return }
        self.siteID = siteID
        estimator = StartupProgressEstimator(profile: timingStore.profile(for: siteID))
        estimator.ingest(runtimeState: .starting(siteID: siteID), at: clock())
        publish()
        subscribeToLogs(siteID: siteID)
        startTicker()
    }

    private func subscribeToLogs(siteID: String) {
        logTask?.cancel()
        let source = "astro:\(siteID)"
        logTask = Task { @MainActor [weak self] in
            guard let center = self?.logCenter else { return }
            let subscription = await center.subscribe()
            for await line in subscription.stream {
                guard let self else { break }
                if Task.isCancelled { break }
                guard line.source == source, line.stream == .stdout else { continue }
                guard self.estimator.isActive else { break }
                self.estimator.ingest(logText: line.text, at: self.clock())
                self.publish()
            }
            subscription.cancel()
        }
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.estimator.isActive else { return }
                self.estimator.tick(now: self.clock())
                self.publish()
                try? await Task.sleep(nanoseconds: 50_000_000) // ~20 fps
            }
        }
    }

    private func publish() {
        phase = estimator.phase
        fraction = estimator.fraction
        message = estimator.message
    }
}
```

- [ ] **Step 2: Commit** (compile verification happens in Task 4)

```bash
git add Sources/AnglesiteApp/StartupProgressModel.swift
git commit -m "feat(preview): startup progress model wiring logs + ticker"
```

---

### Task 4: `StartupProgressView` + `SiteWindow` integration (replace the spinner)

**Files:**
- Create: `Sources/AnglesiteApp/StartupProgressView.swift`
- Modify: `Sources/AnglesiteApp/SiteWindow.swift` (add `@State` model ~line 51; replace the `.starting` branch at lines 258–259; add an `.onChange(of: preview.state)` to the body modifier chain)

**Interfaces:**
- Consumes: `StartupProgressModel` (Task 3); existing `PreviewModel.state`.
- Produces: `StartupProgressView` — `struct StartupProgressView: View` with `let title: String`, `let model: StartupProgressModel`.

- [ ] **Step 1: Write the progress view**

Create `Sources/AnglesiteApp/StartupProgressView.swift`:

```swift
import SwiftUI

/// Determinate dev-server startup indicator: a title line, a linear progress bar driven by
/// `StartupProgressModel.fraction`, and the current curated phase message beneath it. Replaces the
/// indeterminate spinner the preview pane used to show while `astro dev` booted.
struct StartupProgressView: View {
    let title: String
    let model: StartupProgressModel

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            ProgressView(value: model.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
            // Fixed height so the layout doesn't jump as messages change; empty between phases.
            Text(model.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: 18)
                .animation(.easeInOut(duration: 0.2), value: model.message)
        }
        .frame(maxWidth: 360)
        .animation(.easeInOut(duration: 0.2), value: model.fraction)
    }
}
```

- [ ] **Step 2: Add the model to `SiteWindow`**

In `Sources/AnglesiteApp/SiteWindow.swift`, add a `@State` declaration alongside the other models (after the `health` declaration at line 51):

```swift
    @State private var health = HealthModel(runner: DefaultHealthCheckRunner())
    /// Drives the determinate startup progress bar shown in `mainPane` while the dev server boots.
    @State private var startup = StartupProgressModel()
```

- [ ] **Step 3: Replace the `.starting` branch**

In `mainPane(for:)` (lines 258–259), replace:

```swift
        case .starting:
            centeredStatus { ProgressView("Starting dev server for \(site.name)…") }
```

with:

```swift
        case .starting:
            centeredStatus {
                StartupProgressView(title: "Starting dev server for \(site.name)…", model: startup)
            }
```

- [ ] **Step 4: Feed runtime-state changes into the model**

In `SiteWindow.body`, add an `.onChange` after the existing `.onChange(of: router.pendingNavigation)` block (it ends at line 76). Insert:

```swift
        .onChange(of: preview.state) { _, newState in
            startup.ingest(state: newState)
        }
```

Also seed the initial state so the model arms even if the `.idle → .starting` transition is set before the view observes it. In `onDisappear` (line 77), the model is torn down with the window; add `startup.stop()` there alongside `preview.close()`:

```swift
        .onDisappear {
            preview.close()
            startup.stop()
```

(Leave the rest of `onDisappear` unchanged.)

- [ ] **Step 5: Generate the project and build the app target**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export ANGLESITE_PLUGIN_SRC="$HOME/Developer/github.com/Anglesite/anglesite"
xcodegen generate
xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. This compiles `StartupProgressModel`, `StartupProgressView`, and the `SiteWindow` edits together.

- [ ] **Step 6: Run the full core test suite (no regressions)**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test 2>&1 | tail -15
```

Expected: all tests pass, including `StartupTimingStoreTests` and `StartupProgressEstimatorTests`.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnglesiteApp/StartupProgressView.swift Sources/AnglesiteApp/SiteWindow.swift
git commit -m "feat(preview): show determinate startup progress bar in site window"
```

---

## Manual verification (after Task 4)

Build and run the `Anglesite` scheme, open a site, and confirm the preview pane shows a linear bar that fills smoothly through "Starting dev server… → Building site… → Connecting to preview…" and completes as the preview loads — no indeterminate spinner. Open the same site a second time and confirm the fill paces against the first run (the bar should track reality more closely once timing is persisted). Force a failure (e.g. a site with missing deps) and confirm the existing error pane still appears.

## Self-Review notes

- **Spec coverage:** UI-only/core-runtime-untouched ✓ (Task 4 only edits `SiteWindow`; no `SiteRuntimeState` change). Milestone→fraction→message table ✓ (`StartupPhase.fillRange`/`.message`, Task 2). Smooth fill via last-startup timing ✓ (Tasks 1+2 `tick`). Default profile on first run ✓ (`StartupProfile.default`). Curated messages, no ETA/step text ✓. Monotonic, never-early-100% ✓ (Task 2 tests). Error handling via existing `.failed` pane ✓ (Task 4 leaves it intact). Per-site persistence ✓ (Task 1).
- **Spec deviation (intentional):** the design put the testable model in `AnglesiteApp`; this plan extracts the pure state machine to `AnglesiteCore` (`StartupProgressEstimator`) so it gets CI coverage, per the `TokenOnboarding` convention in CLAUDE.md. The App-layer `StartupProgressModel` is thin glue. The runtime state machine and readiness path remain untouched, satisfying the spec's "core untouched" intent.
- **Type consistency:** `StartupProfile`, `StartupPhase`, `StartupProgressEstimator`, `StartupTimingStore`, and `StartupProgressModel` signatures match across Tasks 1→4. `ingest(state:)` (model) vs `ingest(runtimeState:at:)` (estimator) are deliberately distinct.
- **Placeholders:** none.
