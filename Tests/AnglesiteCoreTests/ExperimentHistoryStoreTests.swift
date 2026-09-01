import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ExperimentHistoryStore")
struct ExperimentHistoryStoreTests {
    private func makeConfigDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("experiment-history-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeOutcome(experimentID: String = "hero-headline", concludedAt: String = "2026-08-20") -> ExperimentHistoryStore.Outcome {
        ExperimentHistoryStore.Outcome(
            experimentID: experimentID, name: "Hero headline", decision: .promote,
            variantName: "New headline", controlVisitors: 1000, controlConversions: 50,
            variantVisitors: 1000, variantConversions: 120, startedAt: "2026-08-01",
            concludedAt: concludedAt)
    }

    @Test("load returns an empty array when no file exists yet")
    func loadReturnsEmptyWhenMissing() async {
        let store = ExperimentHistoryStore(configDirectory: makeConfigDirectory())
        #expect(await store.load() == [])
    }

    @Test("append then load round-trips an outcome")
    func appendThenLoadRoundTrips() async {
        let store = ExperimentHistoryStore(configDirectory: makeConfigDirectory())
        let outcome = makeOutcome()

        await store.append(outcome)
        let loaded = await store.load()

        #expect(loaded == [outcome])
    }

    @Test("append creates the config directory if it doesn't exist yet")
    func appendCreatesConfigDirectory() async {
        let configDirectory = makeConfigDirectory()
        let store = ExperimentHistoryStore(configDirectory: configDirectory)

        await store.append(makeOutcome())

        #expect(FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("experiment-history.json").path))
    }

    @Test("multiple appends preserve order")
    func multipleAppendsPreserveOrder() async {
        let store = ExperimentHistoryStore(configDirectory: makeConfigDirectory())
        let first = makeOutcome(experimentID: "first", concludedAt: "2026-08-01")
        let second = makeOutcome(experimentID: "second", concludedAt: "2026-08-20")

        await store.append(first)
        await store.append(second)
        let loaded = await store.load()

        #expect(loaded.map(\.experimentID) == ["first", "second"])
    }

    @Test("load tolerates a corrupt file")
    func loadToleratesCorruptFile() async throws {
        let configDirectory = makeConfigDirectory()
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try "not json".write(
            to: configDirectory.appendingPathComponent("experiment-history.json"),
            atomically: true, encoding: .utf8)
        let store = ExperimentHistoryStore(configDirectory: configDirectory)

        #expect(await store.load() == [])
    }

    @Test("decision round-trips through JSON as its raw string")
    func decisionRoundTripsAsRawString() async throws {
        let configDirectory = makeConfigDirectory()
        let store = ExperimentHistoryStore(configDirectory: configDirectory)
        await store.append(makeOutcome())

        let raw = try String(
            contentsOf: configDirectory.appendingPathComponent("experiment-history.json"), encoding: .utf8)
        #expect(raw.contains("\"promote\""))
    }
}
