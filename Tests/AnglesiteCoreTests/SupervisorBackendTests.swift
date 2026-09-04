import Testing
import Foundation
@testable import AnglesiteCore

struct SupervisorBackendTests {
    @Test("SpawnSpec codable round trips")
    func spawnSpecCodableRoundTrip() throws {
        let original = SpawnSpec(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["status", "--porcelain"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: URL(fileURLWithPath: "/tmp/site"),
            stdinPipe: true,
            logSource: "git:status"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpawnSpec.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("SpawnSpec codable round trips with nil fields")
    func spawnSpecCodableNilFieldsRoundTrip() throws {
        let original = SpawnSpec(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hi"],
            environment: nil,
            workingDirectory: nil,
            stdinPipe: false,
            logSource: "echo"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpawnSpec.self, from: encoded)
        #expect(decoded == original)
    }
}
