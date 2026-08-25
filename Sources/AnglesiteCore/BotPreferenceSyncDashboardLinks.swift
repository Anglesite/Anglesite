import Foundation

/// Cloudflare-dashboard deep link for a zone's Bot Preference Sync settings (#1628, design doc
/// `docs/superpowers/specs/2026-08-23-bot-preference-sync-design.md`). Uses the dashboard's `?to=`
/// deep-link resolver with its `:account`/`:zone` placeholders — the same mechanism as
/// `WorkerDashboardLinks` — so the app never needs to know the account or zone name, only that a
/// zone exists.
///
/// **Provisional path.** Cloudflare's Bot Preference Sync blog post doesn't name the exact
/// dashboard settings location — the feature isn't GA yet ("keep an eye on our changelog for
/// availability"). `security/settings` is a best guess. A wrong path degrades to the zone
/// overview (one more click), never a dead end — same resilience `WorkerDashboardLinks` documents
/// for its own paths. Fix here, in one place, once Cloudflare documents the real path — tracked
/// in #1627.
public enum BotPreferenceSyncDashboardLinks {
    /// `zoneID` isn't interpolated today (the `:zone` placeholder is filled in by the dashboard
    /// itself from account context), but is part of the signature so a future path that does need
    /// it — a per-zone deep link Cloudflare hasn't documented yet — doesn't require a call-site
    /// change.
    public static func settingsURL(zoneID: String) -> URL {
        URL(string: "https://dash.cloudflare.com/?to=/:account/:zone/security/settings")!
    }
}
