import Foundation

/// Named homes for HTTP/RPC request timeout values that used to be duplicated as inline numeric
/// literals scattered across call sites — one definition per conceptual timeout, even where
/// multiple call sites happen to share the same value (#1801 tech-debt audit, 2026-09-03).
public enum NetworkTimeouts {
    /// `LinkMetadataFetcher`'s ephemeral session: per-request bound for the head/body fetch.
    public static let linkMetadataRequest: TimeInterval = 10
    /// `LinkMetadataFetcher`'s ephemeral session: whole-fetch bound (the capped body read).
    public static let linkMetadataResource: TimeInterval = 15

    /// `WXRAssetDownloader`'s ephemeral session: per-request bound for one imported image.
    public static let wxrAssetRequest: TimeInterval = 15
    /// `WXRAssetDownloader`'s ephemeral session: whole-fetch bound for one imported image.
    public static let wxrAssetResource: TimeInterval = 30

    /// `ActivityPubFollowers.fetch(_:)`'s per-request bound.
    public static let activityPubFollowersRequest: TimeInterval = 10

    /// `PodmanContainerControl.waitUntilServing`'s per-poll HTTP GET bound — distinct from that
    /// method's own overall `timeout`/`interval` parameters.
    public static let containerServingProbeRequest: TimeInterval = 2

    /// `MCPClient.listTools()`'s `tools/list` request bound.
    public static let mcpToolsListRequest: TimeInterval = 5
    /// `MCPClient.callTool(...)`'s `tools/call` request bound — deliberately longer than the
    /// other MCP calls' deadlines; tool work is open-ended in a way `initialize`/`tools/list` are not.
    public static let mcpToolCallRequest: TimeInterval = 30

    /// `ACPClient`'s `initialize`/`session/new`/`session/cancel` request bound.
    public static let acpRequestTimeout: TimeInterval = 10
    /// `ACPClient.sendPrompt`'s `session/prompt` request bound — long enough for a real turn
    /// (thinking, tool use) to complete normally while still bounding a crashed in-container agent.
    public static let acpPromptTimeout: TimeInterval = 120
}
