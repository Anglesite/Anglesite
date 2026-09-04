import Foundation

/// Decides *what*, if anything, to announce to VoiceOver as chat responses and deploys stream in —
/// independent of any SwiftUI view, so the rules are unit-tested under `swift test` rather than only
/// in a hosted app test (which CI can't run; see `TokenOnboarding` for the same boundary).
///
/// The single design rule that keeps VoiceOver usable is encoded in the signatures: announcements
/// are a pure function of a *coarse state transition* (`isStreaming` flipping, a deploy reaching a
/// terminal phase, the first stderr line appearing), never of a per-token or per-line append. There
/// is no debounce timer because there is nothing to debounce — the view feeds transitions, and a
/// non-transition returns `nil`.
///
/// The caller (the view) is responsible only for posting a returned string via
/// `AccessibilityNotification.Announcement(_:).post()` from an `.onChange` hook.
public enum LiveRegionAnnouncer {

    // MARK: Chat streaming

    /// The announcement when a chat turn *starts* streaming, or `nil`.
    ///
    /// Keyed off `isStreaming` going `false → true`, so a response that streams token-by-token
    /// produces exactly one start announcement, not one per chunk.
    public static func chatStartAnnouncement(wasStreaming: Bool, isStreaming: Bool) -> String? {
        (!wasStreaming && isStreaming) ? "Assistant is responding" : nil
    }

    /// How a chat turn ended — the view derives this from the model's terminal state when streaming
    /// stops. Distinguishing these is what lets the stop announcement *speak the answer* rather than
    /// a content-free "complete", and avoids saying "complete" for a turn that actually failed or
    /// was cancelled.
    public enum ChatTurnOutcome: Equatable {
        /// The assistant finished; `reply` is its final message text (may be empty for a no-op turn).
        case completed(reply: String)
        case failed(reason: String)
        case cancelled
    }

    /// The announcement when a chat turn *stops*, or `nil` if this isn't a stop transition.
    ///
    /// On success the assistant's reply is spoken directly so a VoiceOver user actually hears the
    /// answer (an empty reply falls back to a generic cue); failure and cancellation get their own
    /// cues instead of a misleading "complete". Keyed off `isStreaming` going `true → false`.
    public static func chatStopAnnouncement(wasStreaming: Bool, isStreaming: Bool,
                                            outcome: ChatTurnOutcome) -> String? {
        guard wasStreaming && !isStreaming else { return nil }
        switch outcome {
        case .completed(let reply):
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Response complete" : trimmed
        case .failed(let reason):
            return "Response failed. \(reason)"
        case .cancelled:
            return "Response stopped"
        }
    }

    // MARK: Deploy

    /// The announceable substrate of a deploy, mapped from the app-target `DeployModel.Phase` (which
    /// `AnglesiteCore` sits below and cannot reference). Only the distinctions that affect an
    /// announcement are modelled; `idle` and `blocked` both collapse to `inactive`.
    public enum DeployActivity: Equatable {
        case inactive
        case running(site: String)
        case succeeded(url: String)
        case failed(reason: String)
    }

    /// The announcement for a deploy phase transition, or `nil`.
    ///
    /// Speaks the *start* (so a deploy kicked off from a keyboard menu is confirmed even if focus
    /// doesn't move to the drawer) and the *terminal* transitions (succeeded/failed). Everything in
    /// between — the streaming log — stays silent here; see `deployStderrAnnouncement` for the one
    /// mid-flight exception.
    public static func deployAnnouncement(from old: DeployActivity, to new: DeployActivity) -> String? {
        guard old != new else { return nil }
        switch new {
        case .running(let site): return "Publishing \(site)"
        case .succeeded(let url): return "Published. \(url)"
        case .failed(let reason): return "Couldn't publish. \(reason)"
        case .inactive: return nil
        }
    }

    /// A one-shot warning the first time a deploy writes to stderr — keyed off the stderr line count
    /// crossing `0 → ≥1`. Gives a VoiceOver user early notice that something is going wrong before
    /// the terminal state, without announcing every subsequent error line (which would flood).
    public static func deployStderrAnnouncement(previousStderrCount: Int, currentStderrCount: Int) -> String? {
        (previousStderrCount == 0 && currentStderrCount > 0) ? "Publish log has errors" : nil
    }

    // MARK: Experiment lifecycle

    /// The announceable substrate of the experiment configure/start lifecycle (#1270 slice 5),
    /// mapped from `ExperimentStatsModel.Step` the same way `DeployActivity` maps from
    /// `DeployModel.Phase`. `.inactive` covers `.manual`/`.propose`/`.idle`-shaped states with
    /// nothing worth announcing.
    public enum ExperimentActivity: Equatable {
        case inactive
        case configuring
        case starting
        case running(name: String)
        case failed(reason: String)
    }

    /// The announcement for an experiment lifecycle transition, or `nil`. Same "coarse transition,
    /// not per-field" rule as `deployAnnouncement`.
    public static func experimentAnnouncement(from old: ExperimentActivity, to new: ExperimentActivity) -> String? {
        guard old != new else { return nil }
        switch new {
        case .running: return "Your test is live. I'll tell you when there's a clear answer."
        case .failed(let reason): return "Couldn't start your test. \(reason)"
        case .configuring, .starting, .inactive: return nil
        }
    }
}
