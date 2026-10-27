/// Pure parser for the Cloudflare Pages `_headers` file format, as emitted by
/// `Resources/Template/scripts/csp.ts`'s `buildHeaders`: a path pattern line, followed by one or
/// more 2-space-indented `Name: value` lines, with blocks separated by a blank line. No I/O — the
/// caller reads the file's contents (from `dist/_headers`) itself.
public enum HeadersFileParser {
    /// One path block's header names mapped to values, in file order.
    public struct Block: Sendable, Equatable {
        public let path: String
        public let headers: [String: String]
    }

    /// Parses every block in `contents`, in file order. A header name repeated within a block
    /// (`Link:`, emitted once per discovery surface — see `csp.ts`'s doc comment) keeps only its
    /// last value: every header ``ServedHeadersAudit`` compares is single-valued in practice.
    public static func parse(_ contents: String) -> [Block] {
        var blocks: [Block] = []
        var currentPath: String?
        var currentHeaders: [String: String] = [:]

        func flush() {
            if let path = currentPath {
                blocks.append(Block(path: path, headers: currentHeaders))
            }
            currentPath = nil
            currentHeaders = [:]
        }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard currentPath != nil, let colonIndex = trimmedLine.firstIndex(of: ":") else { continue }
                let name = String(trimmedLine[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmedLine[trimmedLine.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                currentHeaders[name] = value
            } else {
                flush()
                currentPath = trimmedLine
            }
        }
        flush()
        return blocks
    }

    /// Convenience over ``parse(_:)``: the named path's header names/values, or `nil` if `contents`
    /// declares no block for that exact path.
    public static func headers(forPath path: String, in contents: String) -> [String: String]? {
        parse(contents).first { $0.path == path }?.headers
    }
}
