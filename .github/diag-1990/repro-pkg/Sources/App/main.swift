import Foundation
import Lib

// Cross-module callers omitting the defaulted argument, at varying async depths so the
// task allocator's slab layout differs between iterations.
func nest(_ depth: Int, _ body: @Sendable () async -> Bool) async -> Bool {
    if depth == 0 { return await body() }
    return await nest(depth - 1, body)
}

let url = URL(fileURLWithPath: "/tmp")
let variant = CommandLine.arguments.dropFirst().first ?? "sendable"
for depth in 0..<40 {
    let r = await Task.detached {
        await nest(depth) {
            switch variant {
            case "plain": return await Committer.viaPlainRef(url)
            case "literal": return await Committer.viaLiteral(url)
            default: return await Committer.viaSendableRef(url)
            }
        }
    }.value
    if r { print("unexpected true") }
}
print("\(variant): ok")
