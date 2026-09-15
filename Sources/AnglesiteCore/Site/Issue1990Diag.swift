import Foundation

/// DIAGNOSTIC (#1990, delete before merge): same-module default-argument shapes for an
/// `async` closure parameter, to bisect which one trips Swift 6.3.3's task-allocator LIFO check.
public enum Issue1990Diag {
    public static func viaFuncRefDefault(
        _ url: URL, isTracked: @Sendable (URL, String) async -> Bool = InboxSubmissionCommitter.isTracked
    ) async -> Bool { await isTracked(url, "x") }

    public static func viaLiteralDefault(
        _ url: URL, isTracked: @Sendable (URL, String) async -> Bool = { await InboxSubmissionCommitter.isTracked($0, $1) }
    ) async -> Bool { await isTracked(url, "x") }

    public static func viaNonSendableFuncRefDefault(
        _ url: URL, isTracked: (URL, String) async -> Bool = InboxSubmissionCommitter.isTracked
    ) async -> Bool { await isTracked(url, "x") }

    public static func localAsync(_ a: URL, _ b: String) async -> Bool { false }
    public static func viaLocalFuncRefDefault(
        _ url: URL, isTracked: @Sendable (URL, String) async -> Bool = Issue1990Diag.localAsync
    ) async -> Bool { await isTracked(url, "x") }

    @Sendable public static func localSendableAsync(_ a: URL, _ b: String) async -> Bool { false }
    public static func viaLocalSendableFuncRefDefault(
        _ url: URL, isTracked: @Sendable (URL, String) async -> Bool = Issue1990Diag.localSendableAsync
    ) async -> Bool { await isTracked(url, "x") }
}
