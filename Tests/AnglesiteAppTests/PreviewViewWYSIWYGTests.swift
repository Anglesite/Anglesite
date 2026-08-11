import Testing
import Foundation
@testable import AnglesiteAppCore

/// `PreviewView`'s DOM → AppKit coordinate conversion for the WYSIWYG right-click context menu
/// (#1225 final-review fix wave, Finding 3): the engine reports `clientX`/`clientY` (DOM, top-left
/// origin), but `WKWebView` is a non-flipped `NSView` (bottom-left origin), so popping the menu up
/// at the raw DOM point mirrors it vertically.
@Suite("PreviewView WYSIWYG context-menu coordinates (#1225)")
struct PreviewViewWYSIWYGTests {
    @Test("flips the Y axis against the view's height")
    func flipsYAxis() {
        let converted = PreviewView.convertContextMenuPoint(CGPoint(x: 40, y: 10), viewHeight: 600)
        #expect(converted == CGPoint(x: 40, y: 590))
    }

    @Test("a point near the DOM top lands near the AppKit top (high y)")
    func nearTopBecomesNearTop() {
        let converted = PreviewView.convertContextMenuPoint(CGPoint(x: 0, y: 5), viewHeight: 800)
        #expect(converted.y > 700) // AppKit's bottom-left origin puts high y near the visual top
    }

    @Test("x is unchanged")
    func xUnchanged() {
        let converted = PreviewView.convertContextMenuPoint(CGPoint(x: 123, y: 45), viewHeight: 400)
        #expect(converted.x == 123)
    }
}
