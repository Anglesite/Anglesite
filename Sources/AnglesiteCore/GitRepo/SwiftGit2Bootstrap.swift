#if canImport(Darwin)
import SwiftGit2

/// SwiftGit2 (in-process libgit2, #640) requires `SwiftGit2Init()` before any repository
/// operation — an uninitialized call fails with "library has not been initialized" rather than
/// doing the operation. `static let` initializers run exactly once, lazily, thread-safely, on
/// first access, so every git-touching call site references `ensureInitialized` first instead of
/// each reimplementing its own once-only guard. There's no matching `SwiftGit2Shutdown()` call:
/// the app process lives for the app's lifetime, so there's nothing to release it before.
enum SwiftGit2Bootstrap {
    static let ensureInitialized: Void = {
        _ = SwiftGit2Init()
    }()
}
#endif
