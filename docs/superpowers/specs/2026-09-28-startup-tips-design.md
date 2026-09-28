# Startup screen tips & tricks — design

**Issue:** none tracked — small, additive UI feature (companion to the [dial-up sound effect](2026-07-28-dialup-modem-sound-effect-design.md)).
**Date:** 2026-09-28
**Status:** current

## Goal

While a site's preview boots, the retro "dialing in" startup screen
(`StartupProgressView`: phase strip, progress bar, optional modem sound) holds
the owner's full attention for several seconds and gives them nothing to do.
Use that time to teach Anglesite: show one short tip at a time about a real,
shipped feature, the way installers and game loading screens did in the dial-up
era.

## Decisions

| Decision | Choice |
|---|---|
| Placement | A card beneath the progress bar and status message, above **Show Logs**. Only on the preview startup screen; deploy/backup are out of scope. |
| Rotation | One tip at a time, auto-advancing every 9 s (`StartupTipDeck.dwellSeconds`). |
| Across launches | A persisted cursor (`AppSettings.startupTipCursor`) advances each time a tip is shown, so successive startups walk the whole list instead of repeating tip #1. Not user-facing. It is app-wide, so two windows starting in the same instant can open on the same tip — an accepted, cosmetic limitation. |
| Owner control | **Next Tip** link button skips ahead (and restarts the dwell timer). Hovering the card pauses auto-advance so a slow reader isn't cut off (WCAG 2.2.2). |
| Motion | Cross-fade between tips; none under Reduce Motion. |
| VoiceOver | The tip reads as "Tip: …"; tip changes are **not** announced — startup status already speaks, and chatter would bury it. |
| Content rules | Every tip names a shipped command by its real menu path or shortcut — never a `PlannedItem`. Owner vocabulary only (the localization-catalog lint enforces #1963's word list here too). One or two short sentences. |
| Opt-out | None for now — the card is quiet and replaces idle time. Revisit if feedback asks for a Settings toggle. |

## Structure

- **`AnglesiteCore/StartupTipDeck`** — pure wrapping cursor (count, index,
  `advance()`, `nextCursor`). Wraps any persisted cursor into range, so a
  cursor saved by a build with a different number of tips can't crash.
  Unit-tested in `StartupTipDeckTests`, including the cross-launch walk.
- **`AnglesiteApp/StartupTips`** — the ordered tip list as `String(localized:)`
  literals, so Xcode's extractor and `check-localization-catalog.sh` see them.
- **`AnglesiteApp/StartupTipCard`** — the view. Owns the deck in `@State`,
  drives rotation with `.task(id: deck.index)`, writes the cursor as each tip
  appears.

## Initial tips

1. ⌘N — new page.
2. ⇧⌘L — save a link post.
3. ⇧⌘P — publish, with the pre-publish safety check.
4. ⌃⌘K — Chat.
5. ⌥⌘J — Website Inspector.
6. ⌘R / ⌥⌘R — reload vs. restart the preview.
7. ⌘+ / ⌘− / ⌘0 — preview zoom.
8. Website ▸ Preview in ▸ Default Browser.
9. ⇧⌘, — Website Settings.
10. Ownership: the site lives on your Mac and goes wherever you take it.
11. The dial-up sound toggle in Settings.
12. ⌘1 — back to the preview.
13. ⌃⌘← / ⌃⌘→ — preview back/forward.
14. ⌘F — find on the page being edited.
15. ⌥⇧⌘V — Paste and Match Style.
16. Drag a browser link onto the Sites window — link post.
17. File ▸ Import WordPress Export (WXR)….
18. The auto-generated alt text toggle in Settings.

## Adding a tip

Append a `String(localized:)` line to `StartupTips.all`, add the key to
`Sources/AnglesiteApp/Localizable.xcstrings` (or sync it per CONTRIBUTING.md),
and double-check the shortcut against its `.keyboardShortcut` in the
`*Commands.swift` file that declares it. When a shortcut changes, update the
tip in the same PR.
