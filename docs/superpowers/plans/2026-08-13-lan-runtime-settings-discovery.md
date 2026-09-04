# Remote Development Server Settings + LAN Discovery Implementation Plan

**Status:** historical

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the four issues reported in [#858](https://github.com/Anglesite/Anglesite/issues/858) against Settings ▸ Advanced ▸ "LAN site runtime": wrong section title, wrong host placeholder, comma-grouped port placeholders, and no way to discover a LAN host automatically.

**Architecture:** Three copy/format literals become testable static helpers. `anglesite-lan-host` gains a Bonjour advertisement (`_anglesite-lan._tcp` with a TXT record); the app gains a matching `NWBrowser`-backed discovery type behind a `LANHostDiscovering` protocol (mirroring the existing `ConnectivityMonitoring` pattern), a pure `selectLANHost(from:)` function implementing the "0/1/N" selection rule, and a `@MainActor` `LANHostScanCoordinator` that drives one time-boxed scan per button click. `AdvancedSettingsView` wires the coordinator into the existing Form section.

**Tech Stack:** Swift 6.4, SwiftUI, Apple's `Network` framework (`NWBrowser`/`NWListener`/`NWTXTRecord`), Swift Testing (`@Test`/`#expect`) for all new tests.

## Global Constraints

- Swift 6.4 / macOS 27+, strict concurrency enabled on every touched target (`AnglesiteCore`, `AnglesiteApp`/`AnglesiteAppCore`, `AnglesiteLANHost`) — every new type must be `Sendable` or explicitly `@MainActor`-isolated; no unchecked global mutable state.
- New test files use Swift Testing (`import Testing`, `@Test`, `#expect`) — the codebase's convention for new suites (see `Tests/AnglesiteCoreTests/LANHostServerTests.swift`, `Tests/AnglesiteAppTests/CitationRowViewTests.swift`), not XCTest.
- Apple frameworks only — no new third-party dependencies (`CONTRIBUTING.md` ▸ "Code guidelines").
- Any new/changed/removed user-visible string literal in `Sources/AnglesiteApp` needs a `Localizable.xcstrings` sync per `CONTRIBUTING.md` ▸ "Commit String Catalog updates" — done once, at the end, after all UI-visible strings are finalized (Task 8).
- Commit subjects: conventional commits, `type(scope): summary (#858)`, ≤72 characters total (`CONTRIBUTING.md` ▸ "Commits and pull requests").
- `anglesite-lan-host` is dev/test infrastructure gated behind an explicit Settings override — none of this changes the shipping runtime-selection policy for real users (see `docs/specs/2026-07-09-lan-site-runtime-design.md`).
- Design source of truth: `docs/superpowers/specs/2026-08-13-lan-runtime-settings-discovery-design.md` — every task below implements a specific section of it.

---

### Task 1: Testable copy/format helpers + the three UI bugs

**Files:**
- Modify: `Sources/AnglesiteApp/SettingsView.swift:293-406` (the `AdvancedSettingsView` struct and its LAN section)
- Test: Create `Tests/AnglesiteAppTests/AdvancedSettingsCopyTests.swift`

**Interfaces:**
- Produces: `enum AdvancedSettingsCopy { static let sectionTitle: String; static let hostPlaceholder: String; static func portPlaceholder(_ port: Int) -> String }` — internal (not `private`), declared at file scope in `SettingsView.swift` so `@testable import AnglesiteAppCore` can reach it. Later tasks (Task 6) reuse `AdvancedSettingsCopy.sectionTitle`/`hostPlaceholder`/`portPlaceholder(_:)` unchanged.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnglesiteAppTests/AdvancedSettingsCopyTests.swift`:

```swift
import Testing
@testable import AnglesiteAppCore

@Suite("AdvancedSettingsCopy")
struct AdvancedSettingsCopyTests {
    @Test("section title reads Remote Development Server")
    func sectionTitle() {
        #expect(AdvancedSettingsCopy.sectionTitle == "Remote Development Server")
    }

    @Test("host placeholder reads my-mac.local")
    func hostPlaceholder() {
        #expect(AdvancedSettingsCopy.hostPlaceholder == "my-mac.local")
    }

    @Test("port placeholder has no locale grouping", arguments: [4321, 4399, 80, 65535])
    func portPlaceholderNoGrouping(port: Int) {
        #expect(AdvancedSettingsCopy.portPlaceholder(port) == String(port))
        #expect(!AdvancedSettingsCopy.portPlaceholder(port).contains(","))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --filter AdvancedSettingsCopyTests`
Expected: FAIL — `AdvancedSettingsCopy` does not exist yet (compile error).

- [ ] **Step 3: Add `AdvancedSettingsCopy` and fix the three call sites**

In `Sources/AnglesiteApp/SettingsView.swift`, immediately above `private struct AdvancedSettingsView: View {` (line 293), add:

```swift
/// Copy and formatting for the "Remote Development Server" section, pulled out of the private
/// view so it's directly testable (#858) — `Text` can't be introspected, and the view itself is
/// `private`, so these three literals previously had no test seam at all.
enum AdvancedSettingsCopy {
    static let sectionTitle = "Remote Development Server"
    static let hostPlaceholder = "my-mac.local"

    /// Plain digits, no locale grouping. `Text("\(port)")` interpolates through
    /// `LocalizedStringKey`, which applies locale grouping to the `Int` (`4321` → `4,321`) — the
    /// root cause of #858's comma bug. `Text(verbatim:)` with this plain `String` avoids it.
    static func portPlaceholder(_ port: Int) -> String { String(port) }
}
```

Then update the three call sites inside `AdvancedSettingsView.body` (around lines 363-379):

```swift
Section(AdvancedSettingsCopy.sectionTitle) {
    LabeledContent("Runtime host") {
        TextField("", text: $lanRuntimeHost, prompt: Text(verbatim: AdvancedSettingsCopy.hostPlaceholder))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 240)
            .accessibilityLabel("LAN runtime host")
    }
    LabeledContent("Preview port") {
        TextField("", text: $lanRuntimePreviewPort,
                  prompt: Text(verbatim: AdvancedSettingsCopy.portPlaceholder(LANRuntimeConfiguration.defaultPreviewPort)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
            .accessibilityLabel("LAN runtime preview port")
    }
    LabeledContent("MCP port") {
        TextField("", text: $lanRuntimeMCPPort,
                  prompt: Text(verbatim: AdvancedSettingsCopy.portPlaceholder(LANRuntimeConfiguration.defaultMCPPort)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
            .accessibilityLabel("LAN runtime MCP port")
    }
    Text("Dev/test only: when this Mac can't boot the local container runtime (e.g. inside a VM without nested virtualization), Anglesite connects preview and editing to a dev server already running on the named host over the trusted local network. Leave the host blank to disable. Takes effect the next time a site window opens.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

(The `Section("LAN site runtime")` and the two `Text("\(LANRuntimeConfiguration.defaultXPort)")` prompts are what's being replaced; everything else in the section body is unchanged at this step.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --filter AdvancedSettingsCopyTests`
Expected: PASS (4 tests: sectionTitle, hostPlaceholder, and 4 parameterized portPlaceholder cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/SettingsView.swift Tests/AnglesiteAppTests/AdvancedSettingsCopyTests.swift
git commit -m "fix(#858): fix Remote Dev Server section title, placeholder, ports"
```

---

### Task 2: `DiscoveredLANHost` + `selectLANHost` pure selection logic

**Files:**
- Create: `Sources/AnglesiteCore/LANHostDiscovery.swift`
- Test: Create `Tests/AnglesiteCoreTests/LANHostDiscoveryTests.swift`

**Interfaces:**
- Produces:
  - `public struct DiscoveredLANHost: Sendable, Equatable { let siteName: String; let dnsName: String; let ipAddress: String; let previewPort: Int; let mcpPort: Int; init(siteName:dnsName:ipAddress:previewPort:mcpPort:) }`
  - `public extension DiscoveredLANHost { init?(txtRecord: [String: String], dnsName: String, ipAddress: String) }`
  - `public enum LANHostSelection: Equatable { case empty; case autoPopulate(DiscoveredLANHost); case chooseFrom([DiscoveredLANHost]) }`
  - `public func selectLANHost(from hosts: [DiscoveredLANHost]) -> LANHostSelection`
  - `public protocol LANHostDiscovering: Sendable { func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void); func stop() }`
- Consumes: nothing (pure `Foundation`-only file, no `Network` import — this is deliberate so it compiles and tests identically on every platform).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteCoreTests/LANHostDiscoveryTests.swift`:

```swift
import Testing
@testable import AnglesiteCore

private func lanHost(_ name: String) -> DiscoveredLANHost {
    DiscoveredLANHost(siteName: name, dnsName: "\(name).local", ipAddress: "192.168.1.1",
                       previewPort: 4321, mcpPort: 4399)
}

@Suite("selectLANHost")
struct SelectLANHostTests {
    @Test("zero hosts selects empty")
    func zeroHostsIsEmpty() {
        #expect(selectLANHost(from: []) == .empty)
    }

    @Test("exactly one host auto-populates")
    func oneHostAutoPopulates() {
        let host = lanHost("blog")
        #expect(selectLANHost(from: [host]) == .autoPopulate(host))
    }

    @Test("multiple hosts requires a choice, in discovery order")
    func multipleHostsChooseFrom() {
        let hosts = [lanHost("blog"), lanHost("docs")]
        #expect(selectLANHost(from: hosts) == .chooseFrom(hosts))
    }
}

@Suite("DiscoveredLANHost TXT record parsing")
struct DiscoveredLANHostTXTTests {
    @Test("decodes a well-formed TXT record")
    func decodesWellFormed() {
        let host = DiscoveredLANHost(
            txtRecord: ["site": "my-blog", "previewPort": "4321", "mcpPort": "4399"],
            dnsName: "mac-studio.local", ipAddress: "192.168.1.42")
        #expect(host == DiscoveredLANHost(
            siteName: "my-blog", dnsName: "mac-studio.local", ipAddress: "192.168.1.42",
            previewPort: 4321, mcpPort: 4399))
    }

    @Test("returns nil when site is missing")
    func nilWhenSiteMissing() {
        #expect(DiscoveredLANHost(txtRecord: ["previewPort": "4321", "mcpPort": "4399"],
                                   dnsName: "mac-studio.local", ipAddress: "192.168.1.42") == nil)
    }

    @Test("returns nil when previewPort fails to parse as Int")
    func nilWhenPreviewPortNotInt() {
        #expect(DiscoveredLANHost(txtRecord: ["site": "my-blog", "previewPort": "not-a-number", "mcpPort": "4399"],
                                   dnsName: "mac-studio.local", ipAddress: "192.168.1.42") == nil)
    }

    @Test("returns nil when mcpPort is missing")
    func nilWhenMcpPortMissing() {
        #expect(DiscoveredLANHost(txtRecord: ["site": "my-blog", "previewPort": "4321"],
                                   dnsName: "mac-studio.local", ipAddress: "192.168.1.42") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter LANHostDiscoveryTests`
Expected: FAIL — none of `DiscoveredLANHost`/`selectLANHost`/`LANHostSelection` exist yet.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteCore/LANHostDiscovery.swift`:

```swift
import Foundation

/// A LAN host discovered via Bonjour, advertising itself as `_anglesite-lan._tcp`
/// (see `LANHostAdvertiser`). Carries everything `AdvancedSettingsView`'s "Find on local
/// network" button needs to either auto-populate or list a candidate.
public struct DiscoveredLANHost: Sendable, Equatable {
    /// The `--site` basename the host was launched with, e.g. `my-blog`. Disambiguates multiple
    /// `anglesite-lan-host` instances advertising on the same network.
    public let siteName: String
    /// The resolved Bonjour hostname, e.g. `mac-studio.local`.
    public let dnsName: String
    /// The resolved IP address as a string, e.g. `192.168.1.42`.
    public let ipAddress: String
    /// The host's `astro dev` preview port, from the TXT record.
    public let previewPort: Int
    /// The host's MCP sidecar port, from the TXT record.
    public let mcpPort: Int

    public init(siteName: String, dnsName: String, ipAddress: String, previewPort: Int, mcpPort: Int) {
        self.siteName = siteName
        self.dnsName = dnsName
        self.ipAddress = ipAddress
        self.previewPort = previewPort
        self.mcpPort = mcpPort
    }
}

extension DiscoveredLANHost {
    /// Decodes a Bonjour TXT record (`site`, `previewPort`, `mcpPort` keys — written by
    /// `LANHostAdvertiser`) into a `DiscoveredLANHost`. Returns `nil` when any key is missing or
    /// a port fails to parse as an `Int`, so a malformed or foreign TXT record is dropped rather
    /// than crashing or producing a garbage entry.
    public init?(txtRecord: [String: String], dnsName: String, ipAddress: String) {
        guard let siteName = txtRecord["site"],
              let previewPortString = txtRecord["previewPort"], let previewPort = Int(previewPortString),
              let mcpPortString = txtRecord["mcpPort"], let mcpPort = Int(mcpPortString) else {
            return nil
        }
        self.init(siteName: siteName, dnsName: dnsName, ipAddress: ipAddress,
                  previewPort: previewPort, mcpPort: mcpPort)
    }
}

/// What `AdvancedSettingsView` should do with the hosts a scan found — the pure "0/1/N" rule
/// issue #858 specifies. Plain data in, plain data out: no `Network` import, no timing, no view.
public enum LANHostSelection: Equatable {
    /// No hosts found (or none still visible by the time the scan window closed).
    case empty
    /// Exactly one host found — fill in host/ports without further user interaction.
    case autoPopulate(DiscoveredLANHost)
    /// More than one host found — show a picker; hosts are in discovery order.
    case chooseFrom([DiscoveredLANHost])
}

/// Implements the rule from issue #858: one server found → auto-populate; more than one →
/// present a list; none → empty state.
public func selectLANHost(from hosts: [DiscoveredLANHost]) -> LANHostSelection {
    switch hosts.count {
    case 0: return .empty
    case 1: return .autoPopulate(hosts[0])
    default: return .chooseFrom(hosts)
    }
}

/// Discovers `anglesite-lan-host` instances on the local network. Mirrors `ConnectivityMonitoring`
/// (`Platform/ConnectivityMonitoring.swift`): a platform-agnostic protocol, with the concrete
/// `Network`-framework implementation kept in a separate file so `AdvancedSettingsView` and this
/// file never need to import `Network` themselves.
public protocol LANHostDiscovering: Sendable {
    /// Begins browsing, delivering the accumulated set of currently-visible hosts to `onUpdate`
    /// every time the browse results change. Callbacks may arrive on an arbitrary queue.
    func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void)
    /// Stops browsing; no further callbacks are delivered after it returns. Idempotent.
    func stop()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter LANHostDiscoveryTests`
Expected: PASS (7 tests total).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteCore/LANHostDiscovery.swift Tests/AnglesiteCoreTests/LANHostDiscoveryTests.swift
git commit -m "feat(#858): add LAN host selection rule + TXT record decoding"
```

---

### Task 3: `NWBonjourLANHostDiscovery` — Network-framework browsing

**Files:**
- Create: `Sources/AnglesiteCore/NWBonjourLANHostDiscovery.swift`

**Interfaces:**
- Consumes: `DiscoveredLANHost`, `DiscoveredLANHost.init(txtRecord:dnsName:ipAddress:)`, `LANHostDiscovering` (Task 2).
- Produces: `public final class NWBonjourLANHostDiscovery: LANHostDiscovering` (`#if canImport(Network)`), `public enum PlatformLANHostDiscovery { public static func make() -> any LANHostDiscovering }` — Task 6 consumes `PlatformLANHostDiscovery.make()`.

This task has **no automated test** — `NWBrowser` requires real network hardware and a second Mac advertising `_anglesite-lan._tcp` to produce any result, which is exactly the Tier-4 boundary the design doc draws. Manual verification happens in Task 8.

- [ ] **Step 1: Write the implementation**

Create `Sources/AnglesiteCore/NWBonjourLANHostDiscovery.swift`:

```swift
#if canImport(Network)
import Network
import Foundation

/// Production `LANHostDiscovering` backed by `Network.framework`'s `NWBrowser`, browsing for
/// `_anglesite-lan._tcp` (advertised by `LANHostAdvertiser`). Resolves each result to a DNS name
/// + IP address and decodes its TXT record via `DiscoveredLANHost.init(txtRecord:dnsName:ipAddress:)`,
/// dropping any result that fails to decode.
public final class NWBonjourLANHostDiscovery: LANHostDiscovering, @unchecked Sendable {
    public static let serviceType = "_anglesite-lan._tcp"

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "io.dwk.anglesite.lan-discovery")
    private let lock = NSLock()
    private var running = false

    public init() {}

    public func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.resolveAll(results, onUpdate: onUpdate)
        }
        browser.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()
        browser?.cancel()
        browser = nil
    }

    /// Resolves every current browse result to a `DiscoveredLANHost` (dropping ones that fail),
    /// then delivers the whole accumulated set at once — the coordinator (Task 5) only ever needs
    /// "what's visible right now," not incremental diffs.
    private func resolveAll(_ results: Set<NWBrowser.Result>, onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void) {
        var hosts: [DiscoveredLANHost] = []
        let group = DispatchGroup()
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint,
                  case .bonjour(let txtRecord) = result.metadata else { continue }
            group.enter()
            resolve(name: name, type: type, domain: domain, txtRecord: txtRecord) { host in
                if let host { hosts.append(host) }
                group.leave()
            }
        }
        group.notify(queue: queue) { onUpdate(hosts) }
    }

    /// Opens a short-lived connection to the service endpoint purely to resolve its concrete
    /// host/IP (a Bonjour service endpoint doesn't carry a resolved address until connected).
    private func resolve(
        name: String, type: String, domain: String, txtRecord: NWTXTRecord,
        completion: @escaping (DiscoveredLANHost?) -> Void
    ) {
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                var ipAddress = ""
                if case .hostPort(let host, _) = connection?.currentPath?.remoteEndpoint {
                    ipAddress = "\(host)"
                }
                let dnsName = domain.isEmpty ? "\(name).local" : "\(name).\(domain)"
                let dict = Self.decodeKnownEntries(from: txtRecord)
                let host = DiscoveredLANHost(txtRecord: dict, dnsName: dnsName, ipAddress: ipAddress)
                connection?.cancel()
                completion(host)
            case .failed, .cancelled:
                completion(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Reads only the three keys `LANHostAdvertiser` writes — avoids depending on `NWTXTRecord`'s
    /// full enumeration API surface for keys this feature never uses.
    private static func decodeKnownEntries(from txtRecord: NWTXTRecord) -> [String: String] {
        var dict: [String: String] = [:]
        for key in ["site", "previewPort", "mcpPort"] {
            if case .string(let value)? = txtRecord.getEntry(for: key) {
                dict[key] = value
            }
        }
        return dict
    }
}

/// Compile-time factory for the platform's LAN-host discovery implementation, keeping the `#if`
/// selection here rather than at each call site — mirrors `PlatformConnectivityMonitor`.
public enum PlatformLANHostDiscovery {
    public static func make() -> any LANHostDiscovering {
        NWBonjourLANHostDiscovery()
    }
}
#else
/// Platforms without `Network.framework` report no hosts — "Find on local network" is inert
/// there rather than crashing or hanging indefinitely.
public final class UnavailableLANHostDiscovery: LANHostDiscovering, @unchecked Sendable {
    public init() {}
    public func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void) { onUpdate([]) }
    public func stop() {}
}

public enum PlatformLANHostDiscovery {
    public static func make() -> any LANHostDiscovering {
        UnavailableLANHostDiscovery()
    }
}
#endif
```

- [ ] **Step 2: Build and resolve any Network-framework API mismatches**

Run: `swift build --package-path . --target AnglesiteCore`
Expected: builds cleanly. `NWTXTRecord.Entry`/`getEntry(for:)`, `NWBrowser.Result.endpoint`/`.metadata`, and `NWEndpoint.service(name:type:domain:interface:)` are stable public `Network` framework API, but if the installed SDK reports a signature mismatch, fix the call site to match — this file has no unit test to catch it, so a clean build is the only automated signal until Task 8's manual verification.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteCore/NWBonjourLANHostDiscovery.swift
git commit -m "feat(#858): browse for anglesite-lan-host via NWBrowser"
```

---

### Task 4: `LANHostAdvertiser` + wire into `anglesite-lan-host`

**Files:**
- Create: `Sources/AnglesiteCore/LANHostAdvertiser.swift`
- Modify: `Sources/AnglesiteLANHost/main.swift:93-101`

**Interfaces:**
- Produces: `public final class LANHostAdvertiser` (`#if canImport(Network)`) with `init()`, `func start(site: String, previewPort: Int, mcpPort: Int)`, `func stop()`.
- Consumes: nothing beyond `Network`/`Foundation`.

No automated test (same `Network`-framework/real-hardware boundary as Task 3).

- [ ] **Step 1: Write the implementation**

Create `Sources/AnglesiteCore/LANHostAdvertiser.swift`:

```swift
#if canImport(Network)
import Network

/// Advertises an `anglesite-lan-host` instance on the local network via Bonjour so
/// `NWBonjourLANHostDiscovery` can find it. The listener never accepts real connections — it
/// exists only to carry the Bonjour record. The real preview/MCP ports (already bound by the
/// astro-dev/mcp-sidecar child processes `AnglesiteLANHost` launches) live in the TXT record
/// instead of the listener's own port.
public final class LANHostAdvertiser: @unchecked Sendable {
    public static let serviceType = "_anglesite-lan._tcp"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "io.dwk.anglesite.lan-advertiser")

    public init() {}

    /// Starts advertising with a TXT record carrying `site`, `previewPort`, and `mcpPort` — the
    /// keys `DiscoveredLANHost.init(txtRecord:dnsName:ipAddress:)` decodes. A failure to create
    /// the underlying listener (e.g. no network interfaces) leaves the host simply undiscoverable
    /// rather than crashing the standing process — typing the host manually still works.
    public func start(site: String, previewPort: Int, mcpPort: Int) {
        var txtRecord = NWTXTRecord()
        txtRecord.setEntry(.string(site), for: "site")
        txtRecord.setEntry(.string(String(previewPort)), for: "previewPort")
        txtRecord.setEntry(.string(String(mcpPort)), for: "mcpPort")

        guard let listener = try? NWListener(using: .tcp) else { return }
        listener.service = NWListener.Service(type: Self.serviceType, txtRecord: txtRecord)
        listener.newConnectionHandler = { connection in connection.cancel() }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Stops advertising. Idempotent.
    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
#endif
```

- [ ] **Step 2: Wire into `anglesite-lan-host serve`**

In `Sources/AnglesiteLANHost/main.swift`, inside `runServe(_:)`, right before the `await waitForShutdownSignal()` call (line 100), add:

```swift
#if canImport(Network)
let advertiser = LANHostAdvertiser()
advertiser.start(site: siteDirectory.lastPathComponent, previewPort: previewPort, mcpPort: mcpPort)
defer { advertiser.stop() }
#endif

await waitForShutdownSignal()
await supervisor.shutdownAll()
```

(`#if canImport(Network)` matches `LANHostAdvertiser`'s own gate — `AnglesiteLANHost` is a portable `.executableTarget` that must still build where `Network` doesn't exist.)

- [ ] **Step 3: Build**

Run: `swift build --package-path . --target AnglesiteLANHost`
Expected: builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnglesiteCore/LANHostAdvertiser.swift Sources/AnglesiteLANHost/main.swift
git commit -m "feat(#858): advertise anglesite-lan-host via Bonjour"
```

---

### Task 5: `LANHostScanCoordinator` — time-boxed scan orchestration (TDD)

**Files:**
- Create: `Sources/AnglesiteApp/LANHostScanCoordinator.swift`
- Test: Create `Tests/AnglesiteAppTests/LANHostScanCoordinatorTests.swift`

**Interfaces:**
- Consumes: `LANHostDiscovering`, `DiscoveredLANHost`, `LANHostSelection`, `selectLANHost(from:)` (Task 2), `PlatformLANHostDiscovery.make()` (Task 3).
- Produces: `enum LANDiscoveryScanState: Equatable { case idle; case scanning; case result(LANHostSelection) }` and `@MainActor final class LANHostScanCoordinator: ObservableObject { @Published private(set) var state: LANDiscoveryScanState; init(discovery: any LANHostDiscovering = PlatformLANHostDiscovery.make()); func startScan(scanDuration: Duration = .seconds(4)) }` — Task 6 consumes both as `@StateObject private var lanScan = LANHostScanCoordinator()`.

This is the one piece of the discovery feature with real orchestration logic (state transitions, timing), and it's fully testable via dependency injection — no `Network` import needed here either.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnglesiteAppTests/LANHostScanCoordinatorTests.swift`:

```swift
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

private final class FakeLANHostDiscovery: LANHostDiscovering, @unchecked Sendable {
    var hostsToReport: [DiscoveredLANHost] = []
    private(set) var stopCallCount = 0

    func start(onUpdate: @escaping @Sendable ([DiscoveredLANHost]) -> Void) {
        onUpdate(hostsToReport)
    }

    func stop() {
        stopCallCount += 1
    }
}

private func lanHost(_ name: String) -> DiscoveredLANHost {
    DiscoveredLANHost(siteName: name, dnsName: "\(name).local", ipAddress: "192.168.1.1",
                       previewPort: 4321, mcpPort: 4399)
}

@MainActor
@Suite("LANHostScanCoordinator")
struct LANHostScanCoordinatorTests {
    @Test("starts in idle state")
    func startsIdle() {
        let coordinator = LANHostScanCoordinator(discovery: FakeLANHostDiscovery())
        #expect(coordinator.state == .idle)
    }

    @Test("immediately after starting a scan, state is scanning")
    func scanningWhileInFlight() {
        let coordinator = LANHostScanCoordinator(discovery: FakeLANHostDiscovery())
        coordinator.startScan(scanDuration: .seconds(30))
        #expect(coordinator.state == .scanning)
    }

    @Test("a scan that finds one host ends in autoPopulate and stops discovery")
    func oneHostAutoPopulates() async throws {
        let fake = FakeLANHostDiscovery()
        fake.hostsToReport = [lanHost("blog")]
        let coordinator = LANHostScanCoordinator(discovery: fake)
        coordinator.startScan(scanDuration: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.state == .result(.autoPopulate(lanHost("blog"))))
        #expect(fake.stopCallCount == 1)
    }

    @Test("a scan that finds nothing ends empty")
    func noHostsIsEmpty() async throws {
        let coordinator = LANHostScanCoordinator(discovery: FakeLANHostDiscovery())
        coordinator.startScan(scanDuration: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.state == .result(.empty))
    }

    @Test("a scan that finds multiple hosts ends in chooseFrom")
    func multipleHostsChooseFrom() async throws {
        let fake = FakeLANHostDiscovery()
        fake.hostsToReport = [lanHost("blog"), lanHost("docs")]
        let coordinator = LANHostScanCoordinator(discovery: fake)
        coordinator.startScan(scanDuration: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.state == .result(.chooseFrom([lanHost("blog"), lanHost("docs")])))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path . --filter LANHostScanCoordinatorTests`
Expected: FAIL — `LANHostScanCoordinator`/`LANDiscoveryScanState` don't exist yet.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnglesiteApp/LANHostScanCoordinator.swift`:

```swift
import Combine
import AnglesiteCore

/// What `AdvancedSettingsView`'s "Find on local network" control is doing right now.
enum LANDiscoveryScanState: Equatable {
    case idle
    case scanning
    case result(LANHostSelection)
}

/// Drives one time-boxed LAN host scan per button click, bridging `LANHostDiscovering`'s
/// arbitrary-queue callback into `@MainActor`-safe, `@Published` state `AdvancedSettingsView` can
/// observe directly. Injectable `discovery` (default `PlatformLANHostDiscovery.make()`) is the
/// seam `LANHostScanCoordinatorTests` uses to avoid touching real `NWBrowser`.
@MainActor
final class LANHostScanCoordinator: ObservableObject {
    @Published private(set) var state: LANDiscoveryScanState = .idle

    private let discovery: any LANHostDiscovering
    private var latestHosts: [DiscoveredLANHost] = []

    init(discovery: any LANHostDiscovering = PlatformLANHostDiscovery.make()) {
        self.discovery = discovery
    }

    /// Starts a scan: resets accumulated results, begins browsing, and after `scanDuration`
    /// stops browsing and publishes the selection `selectLANHost(from:)` computes from whatever
    /// was seen. A scan already in flight is left alone (no re-entrant restart).
    func startScan(scanDuration: Duration = .seconds(4)) {
        guard state != .scanning else { return }
        state = .scanning
        latestHosts = []
        discovery.start { [weak self] hosts in
            Task { @MainActor in
                self?.latestHosts = hosts
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: scanDuration)
            guard let self else { return }
            self.discovery.stop()
            self.state = .result(selectLANHost(from: self.latestHosts))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --filter LANHostScanCoordinatorTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnglesiteApp/LANHostScanCoordinator.swift Tests/AnglesiteAppTests/LANHostScanCoordinatorTests.swift
git commit -m "feat(#858): add time-boxed LAN host scan coordinator"
```

---

### Task 6: Wire discovery UI into `AdvancedSettingsView`

**Files:**
- Modify: `Sources/AnglesiteApp/SettingsView.swift` (the `AdvancedSettingsView` struct from Task 1)

**Interfaces:**
- Consumes: `LANHostScanCoordinator`, `LANDiscoveryScanState`, `DiscoveredLANHost` (Task 5), `LANHostSelection` (Task 2).
- Produces: nothing further downstream — this is the leaf UI task.

No automated test — this is the Tier-4 rendered-UI piece the design doc calls out; verified manually in Task 8.

- [ ] **Step 1: Add the coordinator and discovery controls**

In `Sources/AnglesiteApp/SettingsView.swift`, add a `@StateObject` to `AdvancedSettingsView` alongside its existing `@AppStorage` properties (near line 298):

```swift
@StateObject private var lanScan = LANHostScanCoordinator()
```

Inside the `if showsLANRuntimeSection { Section(AdvancedSettingsCopy.sectionTitle) { ... } }` block from Task 1, insert the discovery controls between the three `LabeledContent` fields and the trailing "Dev/test only: …" caption:

```swift
Section(AdvancedSettingsCopy.sectionTitle) {
    LabeledContent("Runtime host") {
        TextField("", text: $lanRuntimeHost, prompt: Text(verbatim: AdvancedSettingsCopy.hostPlaceholder))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 240)
            .accessibilityLabel("LAN runtime host")
    }
    LabeledContent("Preview port") {
        TextField("", text: $lanRuntimePreviewPort,
                  prompt: Text(verbatim: AdvancedSettingsCopy.portPlaceholder(LANRuntimeConfiguration.defaultPreviewPort)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
            .accessibilityLabel("LAN runtime preview port")
    }
    LabeledContent("MCP port") {
        TextField("", text: $lanRuntimeMCPPort,
                  prompt: Text(verbatim: AdvancedSettingsCopy.portPlaceholder(LANRuntimeConfiguration.defaultMCPPort)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
            .accessibilityLabel("LAN runtime MCP port")
    }

    lanDiscoveryControls

    Text("Dev/test only: when this Mac can't boot the local container runtime (e.g. inside a VM without nested virtualization), Anglesite connects preview and editing to a dev server already running on the named host over the trusted local network. Leave the host blank to disable. Takes effect the next time a site window opens.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

Add the `lanDiscoveryControls` view and its supporting `apply(_:)` helper as new members of `AdvancedSettingsView`:

```swift
@ViewBuilder
private var lanDiscoveryControls: some View {
    Button {
        lanScan.startScan()
    } label: {
        if lanScan.state == .scanning {
            ProgressView().controlSize(.small)
        } else {
            Text("Find on local network")
        }
    }
    .disabled(lanScan.state == .scanning)
    .accessibilityLabel("Find LAN runtime hosts on local network")
    .onChange(of: lanScan.state) { _, newState in
        if case .result(.autoPopulate(let host)) = newState {
            apply(host)
        }
    }

    switch lanScan.state {
    case .result(.chooseFrom(let hosts)):
        ForEach(Array(hosts.enumerated()), id: \.offset) { _, host in
            Button {
                apply(host)
            } label: {
                Text("\(host.dnsName) — \(host.ipAddress) — \(host.siteName)")
            }
            .buttonStyle(.plain)
        }
    case .result(.empty):
        Text("No anglesite-lan-host instances found on the local network.")
            .font(.caption)
            .foregroundStyle(.secondary)
    case .idle, .scanning, .result(.autoPopulate):
        EmptyView()
    }
}

private func apply(_ host: DiscoveredLANHost) {
    lanRuntimeHost = host.dnsName
    lanRuntimePreviewPort = String(host.previewPort)
    lanRuntimeMCPPort = String(host.mcpPort)
}
```

- [ ] **Step 2: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds cleanly. Fix any SwiftUI syntax issues (e.g. `.onChange(of:)`'s two-parameter closure form requires macOS 14+, already satisfied by this project's macOS 27+ floor).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnglesiteApp/SettingsView.swift
git commit -m "feat(#858): add Find on local network button to Settings"
```

---

### Task 7: Info.plist Bonjour entitlement keys

**Files:**
- Modify: `Resources/Info.plist`

**Interfaces:** none (config-only; no Swift symbols produced or consumed).

- [ ] **Step 1: Add the Bonjour keys**

In `Resources/Info.plist`, insert before the closing `</dict>` (after the `UTExportedTypeDeclarations` array, before `NSAppleScriptEnabled`):

```xml
	<!-- Local-network Bonjour browsing for Settings ▸ Advanced ▸ Remote Development Server's
	     "Find on local network" button (#858): browses for _anglesite-lan._tcp, advertised by
	     anglesite-lan-host (Sources/AnglesiteLANHost, LANHostAdvertiser). App Sandbox requires
	     the service type declared here before NWBrowser is permitted to see it. -->
	<key>NSBonjourServices</key>
	<array>
		<string>_anglesite-lan._tcp</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Anglesite uses the local network to find a Mac running anglesite-lan-host, a dev/test-only remote development server, when Settings ▸ Advanced ▸ "Find on local network" is used.</string>
```

`AnglesiteLANHost` itself needs no entitlement change — it's an unsandboxed `.executableTarget` CLI binary (`Package.swift`, no `.entitlements` file of its own), so `NWListener`'s Bonjour advertisement isn't sandbox-restricted there.

- [ ] **Step 2: Validate the plist**

Run: `plutil -lint Resources/Info.plist`
Expected: `Resources/Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add Resources/Info.plist
git commit -m "fix(#858): declare Bonjour service for LAN host discovery"
```

---

### Task 8: Full verification, localization sync, and manual QA

**Files:** none new — verification only.

- [ ] **Step 1: Run the full Swift test suite**

Run: `swift test --package-path .`
Expected: all tests pass, including the new `AdvancedSettingsCopyTests`, `LANHostDiscoveryTests`, and `LANHostScanCoordinatorTests` suites.

- [ ] **Step 2: Build the app target**

Run: `scripts/build-app.sh -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
Expected: builds cleanly.

- [ ] **Step 3: Sync the String Catalog**

Task 6 added new user-visible string literals (`"Find on local network"`, the empty-state caption, the per-row `Text` interpolation) to `Sources/AnglesiteApp`. Per `CONTRIBUTING.md` ▸ "Commit String Catalog updates", a CLI-only build doesn't merge these into `Localizable.xcstrings` — run:

```bash
BUILD_DIR=$(xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILD_DIR =/{print $3}')
xcrun xcstringstool sync Sources/AnglesiteApp/Localizable.xcstrings \
  --stringsdata $(find "$(dirname "$BUILD_DIR")/Intermediates.noindex/Anglesite.build/Debug/Anglesite.build/Objects-normal/arm64" -name "*.stringsdata") \
  --skip-marking-strings-stale
```

Review the resulting `git diff Sources/AnglesiteApp/Localizable.xcstrings` — it should add keys for the new strings and update the three changed ones (section title, host placeholder — port placeholders use `Text(verbatim:)` so they're intentionally *not* catalog entries). If the diff includes unrelated keys, it pulled `.stringsdata` from a sibling worktree's `DerivedData` — rerun scoped to this worktree's own `BUILD_DIR` as above. Commit the catalog change:

```bash
git add Sources/AnglesiteApp/Localizable.xcstrings
git commit -m "chore(#858): sync String Catalog for Remote Dev Server strings"
```

- [ ] **Step 4: Manual QA (Tier 4 — cannot be automated)**

Requires two Macs on the same LAN (or one Mac plus a second `anglesite-lan-host` process bound to a non-loopback interface). Verify, per the issue's own acceptance criteria:

1. Settings ▸ Advanced shows "Remote Development Server" (not "LAN site runtime").
2. The host field's placeholder reads `my-mac.local`.
3. The preview/MCP port placeholders read `4321`/`4399` with no comma.
4. With no `anglesite-lan-host` running anywhere reachable: click "Find on local network" → after the scan window, the empty-state caption appears.
5. With exactly one `anglesite-lan-host` instance running and advertising: click the button → host/preview-port/MCP-port fields auto-populate with that instance's values, no further tap needed.
6. With two `anglesite-lan-host` instances running for different `--site` values: click the button → an inline list appears showing each as `dnsName — ipAddress — siteName`; tapping a row populates the three fields with that host's values.
7. On a fresh install/first Bonjour browse, confirm the macOS local-network permission prompt appears, and that denying it leaves the button producing the empty-state caption rather than hanging or crashing.

- [ ] **Step 5: Open the PR**

Follow `CONTRIBUTING.md` ▸ "Commits and pull requests": copy `.github/PULL_REQUEST_TEMPLATE.md`'s exact section headings (Summary, Paired PR check, Test plan) into the PR body, include `Closes #858`, and note in "Paired PR check" that this is app-only (no MCP schema change, no sidecar PR). Do not remove the `🛠️ In Progress` label from the issue — the closing keyword removes it from the claimed-issue search automatically on merge.
