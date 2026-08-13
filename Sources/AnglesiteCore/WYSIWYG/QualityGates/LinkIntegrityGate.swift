import Foundation

/// Internal link-integrity checks — new (design doc §2/§7: no existing check in this repo does
/// this at all). Only internal (`/`-rooted) hrefs are checked against `GateContext.internalRoutes`;
/// external URLs need a network call and stay owned by the deploy-time backstop (design doc §2).
public enum LinkIntegrityGate {
    private struct LinkRef {
        let href: String
        let discriminator: String
    }

    /// Collects every href on `node`: rich-text link runs (recursing into `children`, since a link
    /// can wrap formatted text) plus a top-level `href` prop (an Astro link/button component).
    private static func links(in node: BlockNode) -> [LinkRef] {
        var refs: [LinkRef] = []
        func walk(_ runs: [RichTextRun], path: String) {
            for (index, run) in runs.enumerated() {
                let childPath = "\(path).\(index)"
                if run.kind == .link, let href = run.href {
                    refs.append(LinkRef(href: href, discriminator: "richText\(childPath)"))
                }
                if let children = run.children { walk(children, path: childPath) }
            }
        }
        if let richText = node.richText { walk(richText, path: ".run") }
        if case .string(let href)? = node.props["href"] {
            refs.append(LinkRef(href: href, discriminator: "hrefProp"))
        }
        return refs
    }

    public static func analyze(model: BlockModel, context: GateContext) throws -> [Finding] {
        var findings: [Finding] = []
        for node in model.orderedBlocks {
            for link in links(in: node) {
                guard link.href.hasPrefix("/") else { continue } // external — not this gate's job
                guard !context.internalRoutes.contains(link.href) else { continue }
                findings.append(Finding(
                    blockId: node.id, category: .linkIntegrity, discriminator: link.discriminator, severity: .warning,
                    message: "This link points to \"\(link.href)\", which doesn't match any page on the site — visitors who click it will hit a 404."))
            }
        }
        return findings
    }
}
