import Foundation

public enum Inbox {
    @Sendable public static func isTrackedSendable(_ projectRoot: URL, _ relPath: String) async -> Bool { false }
    public static func isTrackedPlain(_ projectRoot: URL, _ relPath: String) async -> Bool { false }
}

public enum Committer {
    /// Default is a reference to a `@Sendable`-declared static async func (the #1976 shape).
    public static func viaSendableRef(
        _ url: URL, isTracked: @Sendable (URL, String) async -> Bool = Inbox.isTrackedSendable
    ) async -> Bool { await isTracked(url, "x") }

    /// Default is a reference to a plain static async func.
    public static func viaPlainRef(
        _ url: URL, isTracked: @Sendable (URL, String) async -> Bool = Inbox.isTrackedPlain
    ) async -> Bool { await isTracked(url, "x") }

    /// Default is a closure literal.
    public static func viaLiteral(
        _ url: URL, isTracked: @Sendable (URL, String) async -> Bool = { await Inbox.isTrackedSendable($0, $1) }
    ) async -> Bool { await isTracked(url, "x") }
}
