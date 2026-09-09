// Lifecycle tests for the Linux shell's `ShellModel` (#1968): open → start ordering, the
// stop-before-start gate on a site switch, and `stopCurrent`'s drain/idempotence contract —
// all against a recording fake `SiteRuntime`, so no podman, container image, or GTK is needed.
// Every wait is event-driven (a `for await` over the fake's event stream), never a timed sleep.
import Foundation
import Testing
import AnglesiteCore
import AnglesiteSiteModel
@testable import AnglesiteLinuxCore

/// One lifecycle call the fake runtime received, tagged with the runtime it landed on so a
/// test can assert cross-runtime ordering (site A's stop before site B's start).
private enum RuntimeEvent: Equatable, Sendable {
    case start(runtime: Int, siteID: String, siteDirectory: URL)
    case stop(runtime: Int)
}

/// Serializes every fake runtime's events into one ordered stream. `@unchecked Sendable`
/// because the lock guards the only mutable state; the continuation itself is Sendable.
private final class RuntimeEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RuntimeEvent] = []
    private var continuation: AsyncStream<RuntimeEvent>.Continuation?
    let stream: AsyncStream<RuntimeEvent>

    init() {
        var captured: AsyncStream<RuntimeEvent>.Continuation?
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func record(_ event: RuntimeEvent) {
        lock.withLock { recorded.append(event) }
        continuation?.yield(event)
    }

    var events: [RuntimeEvent] { lock.withLock { recorded } }
}

/// A `SiteRuntime` that only records what the shell asked of it. `stop()` can be held open
/// through `stopGate` so a test can observe what the shell does while a teardown is in flight.
private actor FakeSiteRuntime: SiteRuntime {
    let mcpClient = MCPClient(supervisor: ProcessSupervisor())
    private let id: Int
    private let log: RuntimeEventLog
    private let stateMachine = SiteRuntimeStateMachine()
    /// When set, `stop()` awaits this before recording — a controllable slow teardown.
    private let stopGate: Task<Void, Never>?

    init(id: Int, log: RuntimeEventLog, stopGate: Task<Void, Never>? = nil) {
        self.id = id
        self.log = log
        self.stopGate = stopGate
    }

    func start(siteID: String, siteDirectory: URL) async {
        log.record(.start(runtime: id, siteID: siteID, siteDirectory: siteDirectory))
        let gen = stateMachine.beginStarting(siteID: siteID)
        stateMachine.settle(gen: gen, to: .ready(siteID: siteID, url: URL(string: "http://127.0.0.1:4321")!))
    }

    func stop() async {
        await stopGate?.value
        log.record(.stop(runtime: id))
        stateMachine.settle(gen: stateMachine.beginAttempt(), to: .idle)
    }

    func observe() -> AsyncStream<SiteRuntimeState> {
        stateMachine.observe()
    }
}

/// Hands out `FakeSiteRuntime`s numbered in creation order, so event assertions can name
/// "the first runtime" and "the second runtime" without capturing the instances.
private final class RuntimeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var created = 0
    let log = RuntimeEventLog()
    /// The gate applied to the *next* runtime's `stop()`; consumed on creation.
    private var pendingStopGate: Task<Void, Never>?

    func holdNextStop(until gate: Task<Void, Never>) {
        lock.withLock { pendingStopGate = gate }
    }

    func make() -> any SiteRuntime {
        lock.withLock {
            created += 1
            let gate = pendingStopGate
            pendingStopGate = nil
            return FakeSiteRuntime(id: created, log: log, stopGate: gate)
        }
    }
}

@Suite("ShellModel lifecycle", .serialized)
struct ShellModelLifecycleTests {
    private static func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("shell-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makePackage(in root: URL, named name: String, displayName: String) throws -> (AnglesitePackage, AnglesitePackage.Marker) {
        try AnglesitePackage.createSkeleton(
            at: root.appendingPathComponent("\(name).anglesite", isDirectory: true),
            displayName: displayName)
    }

    /// Awaits the next event from `log`, failing loudly if the stream ends first.
    private static func next(from iterator: inout AsyncStream<RuntimeEvent>.AsyncIterator) async throws -> RuntimeEvent {
        try #require(await iterator.next())
    }

    @Test("open reads the marker's identity and starts the runtime on the package's Source/")
    func openStartsRuntimeWithMarkerIdentity() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (package, marker) = try Self.makePackage(in: root, named: "Alpha", displayName: "Alpha Site")
        let factory = RuntimeFactory()
        let model = ShellModel(makeRuntime: { factory.make() })
        var events = factory.log.stream.makeAsyncIterator()

        let site = try await model.open(packageURL: package.url)

        #expect(site.displayName == "Alpha Site")
        #expect(site.siteID == marker.siteID.uuidString)
        let started = try await Self.next(from: &events)
        #expect(started == .start(runtime: 1, siteID: marker.siteID.uuidString, siteDirectory: package.sourceURL))
        await model.stopCurrent()
    }

    @Test("open throws for a directory with no marker and leaves nothing running")
    func openRejectsNonPackage() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let notAPackage = root.appendingPathComponent("Nope.anglesite", isDirectory: true)
        try FileManager.default.createDirectory(at: notAPackage, withIntermediateDirectories: true)
        let factory = RuntimeFactory()
        let model = ShellModel(makeRuntime: { factory.make() })

        await #expect(throws: AnglesitePackage.PackageError.self) {
            _ = try await model.open(packageURL: notAPackage)
        }
        await model.stopCurrent()
        #expect(factory.log.events.isEmpty)
    }

    @Test("opening a second site stops the first before the second starts")
    func siteSwitchStopsPreviousBeforeStartingNext() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (alpha, _) = try Self.makePackage(in: root, named: "Alpha", displayName: "Alpha")
        let (beta, betaMarker) = try Self.makePackage(in: root, named: "Beta", displayName: "Beta")
        let factory = RuntimeFactory()
        let model = ShellModel(makeRuntime: { factory.make() })
        var events = factory.log.stream.makeAsyncIterator()

        _ = try await model.open(packageURL: alpha.url)
        _ = try await Self.next(from: &events) // start(1)

        let second = try await model.open(packageURL: beta.url)
        #expect(second.displayName == "Beta")

        let stopped = try await Self.next(from: &events)
        #expect(stopped == .stop(runtime: 1))
        let started = try await Self.next(from: &events)
        #expect(started == .start(runtime: 2, siteID: betaMarker.siteID.uuidString, siteDirectory: beta.sourceURL))
        await model.stopCurrent()
    }

    @Test("re-opening the same package tears down its predecessor before starting again")
    func reopeningSamePackageSerializesStopThenStart() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (alpha, _) = try Self.makePackage(in: root, named: "Alpha", displayName: "Alpha")
        let factory = RuntimeFactory()
        let model = ShellModel(makeRuntime: { factory.make() })
        var events = factory.log.stream.makeAsyncIterator()

        _ = try await model.open(packageURL: alpha.url)
        _ = try await Self.next(from: &events) // start(1)
        _ = try await model.open(packageURL: alpha.url)

        #expect(try await Self.next(from: &events) == .stop(runtime: 1))
        if case .start(let runtime, _, _) = try await Self.next(from: &events) {
            #expect(runtime == 2)
        } else {
            Issue.record("expected the second runtime to start after the first stopped")
        }
        await model.stopCurrent()
    }

    @Test("stopCurrent stops the open site once; a second call is a no-op")
    func stopCurrentIsIdempotent() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (alpha, _) = try Self.makePackage(in: root, named: "Alpha", displayName: "Alpha")
        let factory = RuntimeFactory()
        let model = ShellModel(makeRuntime: { factory.make() })
        var events = factory.log.stream.makeAsyncIterator()

        _ = try await model.open(packageURL: alpha.url)
        _ = try await Self.next(from: &events) // start(1)

        await model.stopCurrent()
        #expect(try await Self.next(from: &events) == .stop(runtime: 1))
        await model.stopCurrent()
        // Nothing else may have happened: the very next event must be the *next* open's start,
        // not a second stop.
        _ = try await model.open(packageURL: alpha.url)
        if case .start(let runtime, _, _) = try await Self.next(from: &events) {
            #expect(runtime == 2)
        } else {
            Issue.record("expected a start, got a stray event after the idempotent stop")
        }
        #expect(factory.log.events.filter { $0 == .stop(runtime: 1) }.count == 1)
        await model.stopCurrent()
    }

    @Test("stopCurrent during a site switch drains the in-flight teardown, then stops the new site")
    func stopCurrentDrainsInFlightSwitch() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (alpha, _) = try Self.makePackage(in: root, named: "Alpha", displayName: "Alpha")
        let (beta, _) = try Self.makePackage(in: root, named: "Beta", displayName: "Beta")
        let factory = RuntimeFactory()
        // Hold runtime 1's stop open until the test releases it, so the switch is mid-teardown
        // when stopCurrent is called. An AsyncStream latch (both halves Sendable) rather than a
        // captured `var` continuation, which the Linux compiler flags as a sending hazard.
        let (released, releaseLatch) = AsyncStream<Void>.makeStream()
        let gate = Task<Void, Never> {
            for await _ in released { return }
        }
        factory.holdNextStop(until: gate)
        let model = ShellModel(makeRuntime: { factory.make() })
        var events = factory.log.stream.makeAsyncIterator()

        _ = try await model.open(packageURL: alpha.url)
        _ = try await Self.next(from: &events) // start(1)
        _ = try await model.open(packageURL: beta.url) // runtime 2, gated on runtime 1's stop

        let shutdown = Task.detached { await model.stopCurrent() }
        // Nothing can have been recorded yet: runtime 1's stop is parked on the gate, runtime
        // 2's start waits on that stop, and stopCurrent waits on the same chain.
        #expect(factory.log.events.count == 1)

        releaseLatch.yield()
        releaseLatch.finish()
        await shutdown.value

        #expect(try await Self.next(from: &events) == .stop(runtime: 1))
        // Runtime 2's deferred start and stopCurrent both wake on runtime 1's stop, so whether
        // runtime 2 ever starts is unspecified — but if it does, its stop must come *after* its
        // start (a stop-then-start would boot a container nobody tears down), and either way
        // the shutdown's stop is the final event.
        let remaining = Array(factory.log.events.dropFirst(2))
        #expect(remaining.last == .stop(runtime: 2))
        #expect(remaining.count == 1 || remaining.first == .start(runtime: 2, siteID: (try Self.markerID(of: beta)), siteDirectory: beta.sourceURL))
    }

    private static func markerID(of package: AnglesitePackage) throws -> String {
        try package.readMarker().siteID.uuidString
    }
}
