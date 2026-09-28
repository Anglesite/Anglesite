import SwiftUI
import AnglesiteCore

/// The "tips & tricks" shown on the startup screen while a site's preview boots. Order is the
/// rotation order; `StartupTipDeck` walks it across launches. Every tip must describe a shipped
/// command with its real menu path/shortcut (never a `PlannedItem`) and stay in owner terms —
/// the localization-catalog lint rejects git/npm/file-layout vocabulary here like anywhere else.
/// Design: docs/superpowers/specs/2026-09-28-startup-tips-design.md.
enum StartupTips {
    static let all: [String] = [
        String(localized: "Press ⌘N to add a new page to your site."),
        String(localized: "Found something worth sharing? Press ⇧⌘L to save it as a link post."),
        String(localized: "Press ⇧⌘P to publish. Anglesite checks your site for problems before every publish."),
        String(localized: "Press ⌃⌘K to show Chat and ask for help with your site."),
        String(localized: "Press ⌥⌘J to open the Website Inspector for site-wide details."),
        String(localized: "Press ⌘R to reload the preview, or ⌥⌘R to restart it if something seems stuck."),
        String(localized: "Use ⌘+ and ⌘− to zoom the preview. ⌘0 returns to actual size."),
        String(localized: "Choose Website ▸ Preview in ▸ Default Browser to see your site in your own browser."),
        String(localized: "Press ⇧⌘, to open Website Settings."),
        String(localized: "Your website belongs to you. It’s stored on your Mac, and you can take it anywhere."),
        String(localized: "Miss the sound of a 56K modem? Turn on “Play dial-up sound while loading” in Settings."),
        String(localized: "Press ⌘1 to jump back to the preview."),
        String(localized: "Use ⌃⌘← and ⌃⌘→ to go back and forward between pages in the preview."),
        String(localized: "Press ⌘F to find text on the page you’re editing."),
        String(localized: "Pasting from another app? ⌥⇧⌘V pastes the text without its formatting."),
        String(localized: "Drag a link from your browser onto the Sites window to start a link post."),
        String(localized: "Moving from WordPress? Choose File ▸ Import WordPress Export (WXR)… to bring your posts along."),
        String(localized: "Turn on “Auto-generate alt text for dropped images” in Settings, and Anglesite describes new images for people using screen readers."),
    ]
}

/// A single rotating tip beneath the startup progress bar. Auto-advances every
/// `StartupTipDeck.dwellSeconds`, pauses while the pointer rests on it (so a slow reader isn't
/// cut off — WCAG 2.2.2), and offers a Next Tip button for the impatient. Each shown tip moves
/// the persisted cursor on, so the next startup opens on a fresh one.
///
/// Known limitation: `AppSettings.startupTipCursor` is one app-wide value, read once per card.
/// Two site windows that start their previews at nearly the same moment can both open on the
/// same tip, and the cursor then advances once rather than twice. Accepted — it's cosmetic and
/// rare, and per-window cursors would cost more than the repeat does.
struct StartupTipCard: View {
    private let tips: [String]
    private let settings: AppSettings
    @State private var deck: StartupTipDeck
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tips: [String] = StartupTips.all, settings: AppSettings = .shared) {
        self.tips = tips
        self.settings = settings
        _deck = State(initialValue: StartupTipDeck(count: tips.count, startingAt: settings.startupTipCursor))
    }

    var body: some View {
        if !deck.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Tip", systemImage: "lightbulb")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Next Tip", action: advance)
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityHint("Shows another tip.")
                }
                Text(tips[deck.index])
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                    .id(deck.index)
                    .transition(reduceMotion ? .identity : .opacity)
                    .accessibilityLabel(Text("Tip: \(tips[deck.index])"))
            }
            .padding(12)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .onHover { isHovering = $0 }
            // Keyed on the index so a manual Next Tip restarts the dwell timer too.
            .task(id: deck.index) {
                settings.startupTipCursor = deck.nextCursor
                try? await Task.sleep(for: .seconds(StartupTipDeck.dwellSeconds))
                while isHovering, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                }
                guard !Task.isCancelled else { return }
                advance()
            }
        }
    }

    private func advance() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            deck.advance()
        }
    }
}
