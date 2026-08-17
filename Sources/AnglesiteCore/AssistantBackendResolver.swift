import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Resolves `AppSettings.activeAssistantBackend` into an `ACPAssistant`, or `nil` when the active
/// backend is `"foundationModels"` (the default) or references an agent that no longer exists —
/// `SiteAssistantSessionFactory` falls back to the existing `FoundationModelAssistant` path on
/// `nil`, exactly like `ContentAssistantFactory`'s "not compiled in" `nil` case (ACP agent
/// settings design spec §4.5).
public enum AssistantBackendResolver {
    /// Parses the `"acp:<uuid>"` convention. Returns `nil` for `"foundationModels"` or any
    /// malformed value — callers treat that as "use Foundation Models."
    public static func activeAgentID(from raw: String) -> UUID? {
        guard raw.hasPrefix("acp:") else { return nil }
        return UUID(uuidString: String(raw.dropFirst(4)))
    }

    /// Builds an ``ACPAssistant`` for the currently-selected agent, or `nil` when Foundation
    /// Models should handle the session instead. Every failure mode — a `"foundationModels"`
    /// setting, a malformed backend string, an unreadable agent store, an agent that was removed
    /// after being selected — collapses to `nil` deliberately: the setting is advisory, and a
    /// broken selection must degrade to the always-available on-device path rather than leave the
    /// user with no assistant at all.
    public static func resolveActiveACPAssistant(
        siteID: String,
        sourceDirectory: URL,
        containerControlProvider: @escaping ACPAssistant.ContainerControlProvider,
        agentStore: ACPAgentStore = ACPAgentStore(),
        appSettings: AppSettings = .shared,
        secretStore: any SecretStore = PlatformSecretStore.make()
    ) -> ACPAssistant? {
        guard let agentID = activeAgentID(from: appSettings.activeAssistantBackend) else { return nil }
        guard let connections = try? agentStore.load(),
              let connection = connections.first(where: { $0.id == agentID }) else { return nil }
        return ACPAssistant(
            connection: connection,
            siteID: siteID,
            sourceDirectory: sourceDirectory,
            containerControlProvider: containerControlProvider,
            secretStore: secretStore
        )
    }

    /// Builds an ``ExternalLLMBackend`` for the single configured endpoint, or `nil` when
    /// Foundation Models (or an ACP agent) should handle the session instead. Every failure mode
    /// — backend not selected, no base URL configured, blank model — collapses to `nil`
    /// deliberately, matching ``resolveActiveACPAssistant(siteID:sourceDirectory:containerControlProvider:agentStore:appSettings:secretStore:)``'s
    /// "broken selection degrades to on-device" contract. A `SecretStore` read failure degrades
    /// to an unauthenticated request rather than blocking resolution — some self-hosted servers
    /// need no key at all.
    public static func resolveActiveExternalLLMAssistant(
        appSettings: AppSettings = .shared,
        secretStore: any SecretStore = PlatformSecretStore.make(),
        urlSession: URLSession = .shared
    ) -> ExternalLLMBackend? {
        guard appSettings.activeAssistantBackend == "externalLLM" else { return nil }
        guard let baseURL = appSettings.externalLLMBaseURL else { return nil }
        let model = appSettings.externalLLMModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return nil }
        let apiKey = try? secretStore.readExternalLLMAPIKey()
        return ExternalLLMBackend(
            configuration: .init(baseURL: baseURL, model: model, apiKey: apiKey),
            urlSession: urlSession
        )
    }
}
