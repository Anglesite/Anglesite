/// Owner-facing wording for dependency-sync outcomes, shared by the site-open notice
/// (`SiteOpenUpdateNotice`) and the Security Reports fix sheet. Framed around consequences to
/// the site — never around semver ranges or `package.json` mechanics: the owner came here to
/// publish a website, not to adjudicate a dependency graph (owner decision D1).
public enum DependencySyncCopy {
    /// Copy for one held-back bump (#1440): names the site's own packages that aren't ready for
    /// the newer version, and says the app is keeping the current one.
    public static func heldCopy(for held: DependencyHeldUpdate) -> String {
        let names = held.blockers.map(\.dependentName)
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + ", and \(names.last ?? "")"
        }
        let verb = names.count == 1 ? "isn't" : "aren't"
        return "This site also uses \(list), which \(verb) ready for the newer \(held.offer.name) yet. "
            + "Updating \(held.offer.name) now would stop parts of this site from working, so "
            + "Anglesite is keeping it as it is."
    }
}
