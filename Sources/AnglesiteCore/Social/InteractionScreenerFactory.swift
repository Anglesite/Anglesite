import Foundation

/// Where the app looks for an installed Kev model (#2059). The asset directory is user-level
/// state, not a bundle resource: at ~1 GB it has no place in the App Store binary, so it arrives
/// on demand and lives beside the other Application Support caches. A developer override
/// (`ANGLESITE_KEV_ASSETS`) points straight at a checkpoint directory, matching how the
/// tests find the golden checkpoint.
public enum KevModelLocator {
    /// The checkpoint this build expects; the directory name under `Models/`.
    public static let checkpointName = "kev-0.5b"
    /// Environment override for development and tests.
    public static let environmentOverride = "ANGLESITE_KEV_ASSETS"

    /// `<Application Support>/Anglesite/Models/kev-0.5b/`, or `nil` when the platform has no
    /// Application Support directory.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Anglesite", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(checkpointName, isDirectory: true)
    }

    /// The assets to use: the environment override if set, else ``defaultDirectory(fileManager:)``.
    /// Returns `nil` only when neither location exists on disk — presence of the small files
    /// (tokenizer + head) is what's checked; the backbone is verified lazily at first use.
    public static func installedAssets(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> KevModelAssets? {
        let candidates: [URL] = [
            environment[environmentOverride].map { URL(fileURLWithPath: $0, isDirectory: true) },
            defaultDirectory(fileManager: fileManager),
        ].compactMap { $0 }
        return candidates.lazy.map(KevModelAssets.init(directory:))
            .first { $0.hasTokenizerAndHead(fileManager: fileManager) }
    }
}

/// Builds the production ``InteractionScreener`` when a decision model is installed, or `nil` so
/// callers keep today's publish-everything path (pattern: `CopyEditAuditorFactory.makeDefault()`).
///
/// `nil` covers every "not here" case in one place: no Core ML on this platform, no installed
/// assets, or assets whose tokenizer/head fail to load. A backbone that is present but broken is
/// *not* `nil`: it surfaces at first prediction as ``DecisionError/unavailable(_:)``, which the
/// screener logs once and fails open on — so the owner sees the reason in the debug pane instead
/// of a silently disabled screen.
public enum InteractionScreenerFactory {
    /// The default screener for this host, or `nil`.
    ///
    /// - Parameters:
    ///   - policy: Thresholds; see ``InteractionScreeningPolicy/default``.
    ///   - environment: Process environment, for the ``KevModelLocator/environmentOverride``.
    ///   - log: Where load failures go; defaults to `LogCenter`.
    public static func makeDefault(
        policy: InteractionScreeningPolicy = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: (@Sendable (String) async -> Void)? = nil
    ) -> InteractionScreener? {
        guard let assets = KevModelLocator.installedAssets(environment: environment) else { return nil }
        guard let provider = makeProvider(assets: assets, log: log) else { return nil }
        return InteractionScreener(provider: provider, policy: policy, log: log)
    }

    /// The ``DecisionProvider`` over `assets`, or `nil` when it can't be assembled on this host.
    /// Exposed so other gates can share one provider; `makeDefault` is the screener-specific wrap.
    public static func makeProvider(assets: KevModelAssets, log: (@Sendable (String) async -> Void)? = nil) -> (any DecisionProvider)? {
        #if canImport(CoreML)
        let head: KevPointerHead
        do {
            head = try assets.loadHead()
        } catch {
            Task { await (log ?? Self.defaultLog)("Kev head failed to load from \(assets.directory.path): \(error)") }
            return nil
        }
        let backbone = CoreMLKevBackbone(modelURL: assets.backboneURL, hiddenSize: head.hiddenSize)
        do {
            let scorer = try KevOptionScorer(assets: assets, head: head, backbone: backbone)
            return ScoringDecisionProvider(scorer: scorer)
        } catch {
            Task { await (log ?? Self.defaultLog)("Kev scorer failed to assemble from \(assets.directory.path): \(error)") }
            return nil
        }
        #else
        return nil
        #endif
    }

    private static let defaultLog: @Sendable (String) async -> Void = { text in
        await LogCenter.shared.append(source: "InteractionScreenerFactory", stream: .stderr, text: text)
    }
}
