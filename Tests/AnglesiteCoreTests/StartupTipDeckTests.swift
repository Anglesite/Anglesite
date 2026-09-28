import Testing
import Foundation
@testable import AnglesiteCore
import AnglesiteTestSupport

struct StartupTipDeckTests {

    @Test("Starts at the persisted cursor")
    func startsAtCursor() {
        #expect(StartupTipDeck(count: 5, startingAt: 3).index == 3)
    }

    @Test("Out-of-range and negative cursors wrap into range")
    func wrapsCursor() {
        // A cursor saved by a build with more tips than this one must not index out of bounds.
        #expect(StartupTipDeck(count: 4, startingAt: 9).index == 1)
        #expect(StartupTipDeck(count: 4, startingAt: -1).index == 3)
    }

    @Test("Advancing wraps from the last tip back to the first")
    func advanceWraps() {
        var deck = StartupTipDeck(count: 3, startingAt: 1)
        deck.advance()
        #expect(deck.index == 2)
        deck.advance()
        #expect(deck.index == 0)
    }

    @Test("nextCursor points at the tip after the current one")
    func nextCursor() {
        #expect(StartupTipDeck(count: 3, startingAt: 0).nextCursor == 1)
        #expect(StartupTipDeck(count: 3, startingAt: 2).nextCursor == 0)
    }

    @Test("An empty deck is inert")
    func emptyDeck() {
        var deck = StartupTipDeck(count: 0, startingAt: 7)
        #expect(deck.isEmpty)
        #expect(deck.index == 0)
        deck.advance()
        #expect(deck.index == 0)
        #expect(deck.nextCursor == 0)
        #expect(StartupTipDeck(count: -2, startingAt: 0).isEmpty)
    }

    @Test("Successive startups walk every tip before repeating")
    func coversEveryTipAcrossStartups() {
        withTemporaryUserDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            var seen: [Int] = []
            for _ in 0..<4 {
                // One tip shown per startup: the card persists nextCursor as each tip appears.
                let deck = StartupTipDeck(count: 4, startingAt: settings.startupTipCursor)
                seen.append(deck.index)
                settings.startupTipCursor = deck.nextCursor
            }
            #expect(seen == [0, 1, 2, 3])
        }
    }
}
