import Testing
@testable import AnglesiteCore

@Suite("PreDeployCheck.pageAddress(forPublishedFile:)")
struct PreDeployCheckPageAddressTests {
    @Test("Built pages map to the address a visitor types", arguments: [
        ("dist/index.html", "/"),
        ("dist/contact/index.html", "/contact/"),
        ("dist/blog/first-post/index.html", "/blog/first-post/"),
        ("dist/404.html", "/404"),
        ("./dist/about/index.html", "/about/"),
        ("dist\\about\\index.html", "/about/"),
        ("dist/Menu/INDEX.HTML", "/Menu/"),
    ])
    func builtPages(file: String, address: String) {
        #expect(PreDeployCheck.pageAddress(forPublishedFile: file) == address)
    }

    @Test("Anything that isn't a built page has no address", arguments: [
        "_headers",
        "dist/_headers",
        "dist/_astro/client.js",
        "dist/styles/site.css",
        ".env",
        "src/pages/contact.md",
        "dist/",
        "dist/../secret.html",
        "",
    ])
    func notPages(file: String) {
        #expect(PreDeployCheck.pageAddress(forPublishedFile: file) == nil)
    }
}
