import Foundation
import Testing
@testable import AnglesiteCore

/// `UnavailableProcessBackend` is the iOS fallback for `ProcessSupervisor`'s convenience init
/// (#71): every spawn must fail loudly with `spawnFailed`, and the passive queries must read as
/// "nothing running" — never pretend a subprocess exists.
struct UnavailableProcessBackendTests {
    private let backend = UnavailableProcessBackend()
    private let spec = SpawnSpec(
        executable: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        logSource: "test"
    )

    @Test func runOneShotThrowsSpawnFailed() async {
        await #expect(throws: SupervisorBackendError.self) {
            _ = try await backend.runOneShot(spec, logCenter: nil)
        }
    }

    @Test func runDetachingThrowsSpawnFailed() async {
        await #expect(throws: SupervisorBackendError.self) {
            _ = try await backend.runDetaching(spec)
        }
    }

    @Test func launchThrowsSpawnFailed() async {
        await #expect(throws: SupervisorBackendError.self) {
            _ = try await backend.launch(spec, restartPolicy: .never, onRespawn: nil, logCenter: LogCenter())
        }
    }

    @Test func writeStdinThrowsSpawnFailed() async {
        await #expect(throws: SupervisorBackendError.self) {
            try await backend.writeStdin(SpawnedProcessHandle(id: UUID(), pid: -1), Data("x".utf8))
        }
    }

    @Test func passiveQueriesReportNothingRunning() async {
        let handle = SpawnedProcessHandle(id: UUID(), pid: -1)
        #expect(await backend.isRunning(handle) == false)
        #expect(await backend.waitForExit(handle) == .terminated)
        #expect(await backend.stdinHandle(handle) == nil)
        // Termination paths are no-ops, not traps.
        await backend.terminate(handle, timeout: 0)
        await backend.shutdownAll(timeout: 0)
    }
}
