import Testing
import Foundation
@testable import Lib

// Mirrors the Anglesite test bundle: a test module omitting the defaulted argument.
@Suite struct LibTests {
    func nest(_ depth: Int, _ body: @Sendable () async -> Bool) async -> Bool {
        if depth == 0 { return await body() }
        return await nest(depth - 1, body)
    }
    @Test func sendableRef() async {
        let url = URL(fileURLWithPath: "/tmp")
        for depth in 0..<40 { _ = await nest(depth) { await Committer.viaSendableRef(url) } }
    }
    @Test func plainRef() async {
        let url = URL(fileURLWithPath: "/tmp")
        for depth in 0..<40 { _ = await nest(depth) { await Committer.viaPlainRef(url) } }
    }
    @Test func literal() async {
        let url = URL(fileURLWithPath: "/tmp")
        for depth in 0..<40 { _ = await nest(depth) { await Committer.viaLiteral(url) } }
    }
}
