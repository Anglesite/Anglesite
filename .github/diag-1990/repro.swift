import Foundation

public enum Inbox {
    @Sendable public static func isTracked(_ projectRoot: URL, _ relPath: String) async -> Bool {
        return false
    }
}

public enum Committer {
    public static func commit(
        touchedPaths: [String], sourceDirectory: URL,
        isTracked: @Sendable (URL, String) async -> Bool = Inbox.isTracked  // VARIANT
    ) async -> Bool {
        var paths: [String] = []
        for path in touchedPaths.sorted() {
            let tracked = await isTracked(sourceDirectory, path)
            if tracked { paths.append(path) }
        }
        return paths.isEmpty
    }
}

@main struct Main {
    static func main() async {
        let url = URL(fileURLWithPath: "/tmp")
        let detached = await Task.detached { await Committer.commit(touchedPaths: ["a"], sourceDirectory: url) }.value
        print("detached ok", detached)
        let direct = await Committer.commit(touchedPaths: ["a"], sourceDirectory: url)
        print("direct ok", direct)
    }
}
