import Foundation
import Observation
import AnglesiteCore

/// Drives one site's "Edit Site" P2P session on iOS (#1431, iOS v2.0 design §3) behind the
/// `SiteRuntime` seam — the same pattern the Mac's `PreviewModel` uses (and the retired #71
/// scaffold used), so #1208 P4's real `P2PSiteRuntime` plugs in by swapping only the injected
/// `makeRuntime` factory.
///
/// Lifecycle contract (design §3): the model outlives the full-screen cover that renders it.
/// Dismissing the cover merely stops *rendering* — the runtime keeps running warm so re-entry is
/// instant; only the explicit Stop action (``stop()``) ends the session. The shell owns one model
/// per site, so switching sites never tears down another site's session.
@MainActor
@Observable
public final class EditSessionModel {
    /// The session leg the cover should render. Copy stays in the owner's vocabulary — the
    /// site, the Mac, the network — never ICE/SDP/WebRTC (design §3).
    public enum Phase: Equatable {
        /// No paired Mac (or the pairing store is unreadable): walk into pairing onboarding.
        case pairingRequired
        /// The session is being established but the runtime hasn't reported state yet.
        case waking
        /// The runtime is booting the site (container start, dev-server launch).
        case starting
        /// Live preview available at `URL`.
        case ready(URL)
        /// The session ended in an owner-facing failure.
        case failed(message: String)
        /// No session — before the first ``open()`` and after ``stop()``.
        case idle
    }

    /// The site's stable package UUID — the identity the phone names sites by (design §2), the
    /// same UUID `SitePickerModel` discovery yields.
    public let siteID: UUID
    /// Owner-facing site name for the cover's title.
    public let siteDisplayName: String

    public private(set) var phase: Phase = .idle
    /// The session's MCP connection for the edit pipeline; `nil` while no session runs.
    public private(set) var mcpClient: MCPClient?

    /// Whether a runtime currently exists — drives the cover's Stop affordance.
    public var isSessionActive: Bool { runtime != nil }

    private let pairedMacs: () throws -> [PairedDevice]
    private let makeRuntime: @MainActor () -> any SiteRuntime
    private let lastMacContact: @Sendable () async -> Date?
    private let onPhaseChange: @MainActor (Phase) -> Void

    private var runtime: (any SiteRuntime)?
    private var observationTask: Task<Void, Never>?

    /// - Parameters:
    ///   - siteID: The site's stable package UUID.
    ///   - siteDisplayName: Owner-facing name for titles and messages.
    ///   - pairedMacs: `PairedDeviceStore().load` in production. A throw is treated as "no
    ///     paired Mac" — the walk-in re-pairs, which also heals a corrupt store.
    ///   - makeRuntime: Builds the session's `SiteRuntime`. Production hands out
    ///     ``PendingP2PSiteRuntime`` until #1208 P4 ships the real `P2PSiteRuntime`.
    ///   - lastMacContact: When the Mac was last known reachable (CloudKit presence heartbeat,
    ///     read-side lands with P4) — folded into failure copy when available.
    ///   - onPhaseChange: Called after every ``phase`` transition. `SiteSplitScreen` uses this to
    ///     track which sites have a warm session for #1436's relaunch re-offer, without this
    ///     model taking on a `UserDefaults`/persistence dependency of its own.
    public init(
        siteID: UUID,
        siteDisplayName: String,
        pairedMacs: @escaping () throws -> [PairedDevice],
        makeRuntime: @escaping @MainActor () -> any SiteRuntime,
        lastMacContact: @escaping @Sendable () async -> Date? = { nil },
        onPhaseChange: @escaping @MainActor (Phase) -> Void = { _ in }
    ) {
        self.siteID = siteID
        self.siteDisplayName = siteDisplayName
        self.pairedMacs = pairedMacs
        self.makeRuntime = makeRuntime
        self.lastMacContact = lastMacContact
        self.onPhaseChange = onPhaseChange
    }

    /// Entry point every presentation of the cover calls. Gates on pairing, then starts a
    /// session — or, when one is already running warm (the cover was dismissed and re-entered),
    /// leaves it untouched and keeps rendering its state.
    public func open() async {
        if runtime != nil { return }
        guard hasPairedMac else {
            setPhase(.pairingRequired)
            return
        }
        await startSession()
    }

    /// Called when pairing onboarding finishes: re-checks the store and proceeds.
    public func completePairing() async {
        guard runtime == nil, hasPairedMac else { return }
        await startSession()
    }

    /// The explicit Stop action: ends the session for real. The observation is cancelled first
    /// so the runtime's own settle-to-idle can't race a stale phase back in.
    public func stop() async {
        observationTask?.cancel()
        observationTask = nil
        let stopping = runtime
        runtime = nil
        mcpClient = nil
        setPhase(.idle)
        await stopping?.stop()
    }

    /// Single write path for ``phase`` so every transition also notifies ``onPhaseChange``.
    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        onPhaseChange(newPhase)
    }

    private var hasPairedMac: Bool {
        guard let macs = try? pairedMacs() else { return false }
        return !macs.isEmpty
    }

    private func startSession() async {
        let runtime = makeRuntime()
        self.runtime = runtime
        setPhase(.waking)
        mcpClient = await runtime.mcpClient

        observationTask?.cancel()
        observationTask = Task { [weak self] in
            let stream = await runtime.observe()
            for await state in stream {
                guard let self, !Task.isCancelled else { return }
                await self.render(state)
            }
        }

        let id = siteID.uuidString
        Task {
            // No local site files on iOS — the runtime reaches the site through the Mac.
            await runtime.start(siteID: id, siteDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        }
    }

    private func render(_ state: SiteRuntimeState) async {
        switch state {
        case .idle:
            // The runtime's initial replayed state (or a stop this model initiated) — never
            // demote an in-flight phase for it.
            if runtime == nil { setPhase(.idle) }
        case .starting:
            setPhase(.starting)
        case .ready(_, let url, _):
            setPhase(.ready(url))
        case .failed(_, let message):
            var composed = message
            if let lastSeen = await lastMacContact() {
                composed += " " + Self.lastReachableClause(lastSeen)
            }
            setPhase(.failed(message: composed))
        }
    }

    /// The "last reachable" sentence appended to failure copy (design §3: "Your Mac was last
    /// reachable at 3:12 PM"). Static and public so tests assert against the same formatter —
    /// locale differences can't break CI.
    public static func lastReachableClause(_ date: Date) -> String {
        let formatted: String
        if Calendar.current.isDateInToday(date) {
            formatted = date.formatted(date: .omitted, time: .shortened)
        } else {
            formatted = date.formatted(.dateTime.month().day().hour().minute())
        }
        return String(localized: "Your Mac was last reachable at \(formatted).")
    }
}
